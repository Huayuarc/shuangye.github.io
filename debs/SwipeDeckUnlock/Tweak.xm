// SwipeDeckUnlock —— SwipeDeck 免激活（运行时方案）
//
// 思路：不去改磁盘上的二进制，而是在目标镜像刚被 dyld 映射、其 constructor
// 还没执行的窗口里，把「是否已激活」判定函数的返回指令就地改成恒 1。
// 函数体照常跑（验签、写缓存、设全局变量都不跳过），只把出口固定。
//
// 为什么不动函数入口：SwipeDeck 的判定函数体内会初始化一批全局状态，
// 直接 ret 会让后续代码读到空数据 -> SpringBoard 崩溃 -> 无限注销。
//
// 编译：Theos（rootless）
//   export THEOS=~/theos
//   make package THEOS_PACKAGE_SCHEME=rootless

#ifdef CPUTHERMAL_STRIP_LOGS
#define NSLog(...) // empty
#endif

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <libkern/OSCacheControl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <substrate.h>

#pragma mark - 补丁点

// and w0, w22, #1   （函数返回点：把 w22 的布尔结果截到 w0）
#define SD_INSN_ORIG   ((uint32_t)0x120002C0)
// mov w0, #1        （恒返回「已激活」）
#define SD_INSN_PATCH  ((uint32_t)0x52800020)

typedef struct {
    const char *image;   // 镜像 basename
    uint32_t    arm64;   // arm64  切片里返回点的文件/VM 偏移（__TEXT vmaddr = 0）
    uint32_t    arm64e;  // arm64e 切片里同一处
} SD_SITE;

static const SD_SITE kSites[] = {
    // SwipeDeck.dylib  —— isActivated() 返回点，constructor 门禁与全部功能页都看它
    { "SwipeDeck.dylib", 0x962A0, 0x9DA1C },
    // SwipeDeckPrefs   —— 设置面板里同一份判定（决定抬头「已激活 / 未激活」）
    { "SwipeDeckPrefs",  0xAAD18, 0xB3BA8 },
};

static const char *kKillSwitch =
    "/var/mobile/Library/Preferences/com.zooah.swipedeck.unlock.disabled";

#pragma mark - 内存改写

static BOOL SDWriteInsn(uint32_t *slot, uint32_t value) {
    if (!slot) return NO;
    if (*slot == value) return YES;                       // 已经打过

    vm_address_t page = (vm_address_t)slot & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return NO;

    *slot = value;
    sys_icache_invalidate(slot, sizeof(uint32_t));         // 冲指令缓存
    __builtin___clear_cache((char *)slot, (char *)slot + sizeof(uint32_t));
    return YES;
}

static void SDPatchImage(const struct mach_header_64 *mh, const char *path) {
    if (!mh || !path) return;

    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;

    for (size_t i = 0; i < sizeof(kSites) / sizeof(kSites[0]); i++) {
        if (strcmp(base, kSites[i].image) != 0) continue;

        // arm64e 的 cpusubtype 低位是 2（高位是 ABI/capability 标志，要掩掉）
        BOOL isArm64e = ((mh->cpusubtype & 0x00FFFFFF) == 2);
        uint32_t off  = isArm64e ? kSites[i].arm64e : kSites[i].arm64;

        uint32_t *slot = (uint32_t *)((uintptr_t)mh + off);
        if (*slot != SD_INSN_ORIG && *slot != SD_INSN_PATCH) {
            NSLog(@"[SwipeDeckUnlock] %s 偏移 0x%X 不是预期指令 (0x%08X)，"
                  @"跳过以免打坏", base, off, *slot);
            return;
        }
        SDWriteInsn(slot, SD_INSN_PATCH);
        NSLog(@"[SwipeDeckUnlock] %s[%s] 0x%X %@",
              base, isArm64e ? "arm64e" : "arm64", off,
              @"patch attempted");
        return;
    }
}

#pragma mark - 设置面板兜底（ObjC 层）

// 面板里的状态读取与「未激活」提示，双保险：即使内存 patch 晚到，
// 设置页也不会再显示未激活、不会弹拦截框。

static long (*origActivationState)(id, SEL);
static long sdActivationState(id self, SEL _cmd) {
    return 1;
}

static BOOL (*origEntryVisible)(id, SEL);
static BOOL sdEntryVisible(id self, SEL _cmd) {
    return NO;
}

static void (*origPresentAlert)(id, SEL);
static void sdPresentAlert(id self, SEL _cmd) {
    // 拦截「未激活，功能暂不支持使用」弹窗
}

static void SDInstallPrefsHooks(void) {
    Class cls = objc_getClass("SDLicensingController");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, @selector(activationState));
    if (m) MSHookMessageEx(cls, @selector(activationState),
                           (IMP)&sdActivationState, (IMP *)&origActivationState);

    m = class_getInstanceMethod(cls, @selector(_sdz_activationEntryShouldBeVisible));
    if (m) MSHookMessageEx(cls, @selector(_sdz_activationEntryShouldBeVisible),
                           (IMP)&sdEntryVisible, (IMP *)&origEntryVisible);

    m = class_getInstanceMethod(cls, @selector(sd_presentNotActivatedAlert));
    if (m) MSHookMessageEx(cls, @selector(sd_presentNotActivatedAlert),
                           (IMP)&sdPresentAlert, (IMP *)&origPresentAlert);
}

#pragma mark - 加载时机

static void SDImageAdded(const struct mach_header *mh, intptr_t slide) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == mh) {
            SDPatchImage((const struct mach_header_64 *)mh, _dyld_get_image_name(i));
            return;
        }
    }
}

__attribute__((constructor))
static void SDUnlockInit(void) {
    if (access(kKillSwitch, F_OK) == 0) {      // 保命开关：文件存在就什么都不做
        NSLog(@"[SwipeDeckUnlock] 检测到禁用开关，跳过");
        return;
    }

    // dyld 在镜像映射之后、其 initializer 执行之前回调这里 ——
    // 这就是我们能在 SwipeDeck 的 constructor 门禁跑之前动手的原因。
    _dyld_register_func_for_add_image(SDImageAdded);

    // 注册时 dyld 会把已加载的镜像补调一遍，这里再兜一次底
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        SDPatchImage((const struct mach_header_64 *)_dyld_get_image_header(i),
                     _dyld_get_image_name(i));
    }

    // 设置面板：等 bundle 起来再 hook
    dispatch_async(dispatch_get_main_queue(), ^{
        SDInstallPrefsHooks();
    });
}
