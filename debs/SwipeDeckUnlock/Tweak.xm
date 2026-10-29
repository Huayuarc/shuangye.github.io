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
