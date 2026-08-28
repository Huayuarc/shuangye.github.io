// ============================================================================
// CPUthermalMitigationHook.dylib
// 硬件写边界（IORegistryEntrySetCFProperty）绝杀拦截，注入 thermalmonitord + powerd。
//
// 与上层 Hook 的分工：
//  - Tweak.x（thermalmonitord）承担 MitigationController / CommonProduct 等
//    Objective-C 级功率目标拦截，本 dylib 不复刻，避免同进程双重 Hook；
//  - BatteryTempBypass.dylib（powerd）承担 IORegistryEntryCreateCFProperties
//    读边界温度夹紧与周期清抑制位，本 dylib 在更底层的“写边界”做兜底拦截；
//  - 本 dylib 新增“写边界”硬件拦截：拦截 thermalmonitord/powerd 写入 IOKit
//    的降亮度属性与充电限流/抑制属性，从物理层阻断热降亮度与电池热限流。
//
// 驱动信号：com.huayuarc.cputhermal/mitigationState（位打包）
//   bit0  = 低功耗模式(1)/解除温控(0)
//   bit8  = 拦截暗屏降亮度（thermalPreventDimmingEnabled）
//   bit9  = 强制满血快充（forceFastChargeIgnoreHeat）
// ============================================================================
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>
#import <CPUthermalPaths.h>

typedef mach_port_t io_registry_entry_t;
extern "C" kern_return_t IORegistryEntrySetCFProperty(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property);

static int gMitigationToken = -1;
static os_unfair_lock gEntryLock = OS_UNFAIR_LOCK_INIT;
static io_registry_entry_t gPStateEntry = MACH_PORT_NULL;
static io_registry_entry_t gCeilingEntry = MACH_PORT_NULL;
static io_registry_entry_t gFloorEntry = MACH_PORT_NULL;
static kern_return_t (*orig_IORegistryEntrySetCFProperty)(io_registry_entry_t, CFStringRef, CFTypeRef);

// ============================================================================
// 实时状态读取
// ============================================================================
static uint64_t RealTimeState(void) {
    if (gMitigationToken == -1) {
        notify_register_check(kCPUthermalMitigationStateNotifC, &gMitigationToken);
    }
    uint64_t state = 0;
    notify_get_state(gMitigationToken, &state);
    return state;
}

static NSInteger RealTimeMitigationMode(void) {
    // 明确区分两种有效模式：1=低功耗，2=解除温控。
    // 旧实现全功率返回 0，却在写边界判断 mode==2，导致低功耗写入的 p-state-cap 无恢复分支。
    return (RealTimeState() & MIT_CPU_MODE_LOW) ? 1 : 2;
}

static BOOL RealTimeBlockDimming(void) {
    return (RealTimeState() & MIT_BLOCK_DIMMING) != 0;
}

static BOOL RealTimeForceFastCharge(void) {
    return (RealTimeState() & MIT_FORCE_FAST_CHARGE) != 0;
}

static void RememberEntry(io_registry_entry_t entry, NSString *property) {
    if (entry == MACH_PORT_NULL || !property) return;
    os_unfair_lock_lock(&gEntryLock);
    io_registry_entry_t *slot = NULL;
    if ([property isEqualToString:S("p-state-cap")]) slot = &gPStateEntry;
    else if ([property isEqualToString:S("CPU_Ceiling")]) slot = &gCeilingEntry;
    else if ([property isEqualToString:S("CPU_Floor")]) slot = &gFloorEntry;
    if (slot && *slot != entry) {
        if (*slot != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), *slot);
        if (mach_port_mod_refs(mach_task_self(), entry, MACH_PORT_RIGHT_SEND, 1) == KERN_SUCCESS) *slot = entry;
    }
    os_unfair_lock_unlock(&gEntryLock);
}

static void WriteNumber(io_registry_entry_t entry, CFStringRef key, int value) {
    if (entry == MACH_PORT_NULL || !orig_IORegistryEntrySetCFProperty) return;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    if (number) { orig_IORegistryEntrySetCFProperty(entry, key, number); CFRelease(number); }
}

static void ApplyRememberedCPUState(void) {
    NSInteger mode = RealTimeMitigationMode();
    os_unfair_lock_lock(&gEntryLock);
    io_registry_entry_t p = gPStateEntry, c = gCeilingEntry, f = gFloorEntry;
    os_unfair_lock_unlock(&gEntryLock);
    if (mode == 1) {
        WriteNumber(p, CFSTR("p-state-cap"), 2);
        WriteNumber(c, CFSTR("CPU_Ceiling"), 2);
        WriteNumber(f, CFSTR("CPU_Floor"), 2);
    } else {
        WriteNumber(p, CFSTR("p-state-cap"), 15);
        WriteNumber(c, CFSTR("CPU_Ceiling"), 100);
        WriteNumber(f, CFSTR("CPU_Floor"), 0);
    }
}

// ============================================================================
// 写边界 IOKit 拦截：物理层阻断热降亮度 / 热限充电 / CPU 节流属性
// 采用 CF 级显式内存管理，避免在热路径引入 ARC 崩溃。
// ============================================================================
static kern_return_t hook_IORegistryEntrySetCFProperty(io_registry_entry_t entry, CFStringRef propertyName, CFTypeRef property) {
    if (!propertyName) return orig_IORegistryEntrySetCFProperty(entry, propertyName, property);

    NSInteger mode = RealTimeMitigationMode();
    BOOL blockDimming = RealTimeBlockDimming();
    BOOL forceFastCharge = RealTimeForceFastCharge();
    NSString *propStr = (__bridge NSString *)propertyName;
    RememberEntry(entry, propStr);

    // [绝杀] 物理层阻断热降亮度：写入任何背光限制属性一律吞掉。
    if (blockDimming) {
        if ([propStr containsString:S("max-brightness")] ||
            [propStr containsString:S("brightness-limit")] ||
            [propStr containsString:S("IOMFB_brightness_limit")] ||
            [propStr containsString:S("ThermalMitigation")] ||
            [propStr containsString:S("ThermalLimit")]) {
            return KERN_SUCCESS;
        }
    }

    // [绝杀] 终极满血快充：突破 80% 优化充电与高温降流限制。
    if (forceFastCharge) {
        // 强势注入最高物理阈值；CFNumberCreate 保证底层不泄漏。
        if ([propStr containsString:S("ChargeCurrent")] ||
            [propStr containsString:S("ChargeLimit")] ||
            [propStr containsString:S("MaxChargeCurrent")] ||
            [propStr containsString:S("ChargeRate")]) {
            int val = 5000;
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
        // 粉碎“优化电池充电 (OBC)”休眠断流机制。
        if ([propStr containsString:S("ChargeInhibit")] ||
            [propStr containsString:S("SmartCharge")] ||
            [propStr containsString:S("EnforceDisableOBC")]) {
            return orig_IORegistryEntrySetCFProperty(entry, propertyName, kCFBooleanFalse);
        }
    }

    // 按模式钳制 CPU 节流属性（百分比语义）。
    if (mode == 1) { // 低功耗
        if ([propStr isEqualToString:S("p-state-cap")] ||
            [propStr isEqualToString:S("CPU_Ceiling")] ||
            [propStr isEqualToString:S("CPU_Floor")]) {
            int val = 2;
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
    } else if (mode == 2) { // 解除温控满血
        // p-state-cap 是 PMGR 档位索引（0~15），CPU_Ceiling/Floor 是百分比（0~100）。
        // 两者不可统一写 15，否则 CPU_Ceiling 会被锁在 15%，表现为切回后仍约 1.4GHz。
        int val = 0;
        BOOL matched = YES;
        if ([propStr isEqualToString:S("p-state-cap")]) val = 15;
        else if ([propStr isEqualToString:S("CPU_Ceiling")]) val = 100;
        else if ([propStr isEqualToString:S("CPU_Floor")]) val = 0;
        else matched = NO;
        if (matched) {
            CFNumberRef numRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
            kern_return_t res = orig_IORegistryEntrySetCFProperty(entry, propertyName, numRef);
            CFRelease(numRef);
            return res;
        }
    }

    return orig_IORegistryEntrySetCFProperty(entry, propertyName, property);
}

// 周期复施功率目标仅在 thermalmonitord 通过 MitigationController 进行（powerd 无该控制器）。
// 本 dylib 不做类 Hook —— Tweak.x 已完整接管 MitigationController 的 ObjC 级功率目标拦截。

static void RefreshMitigationState(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL lowMode = NO;
    CPUthermalReadPostedPowerMode(&lowMode);
    CPUthermalPostMitigationState(lowMode,
                                  [prefs[S("thermalPreventDimmingEnabled")] ?: @NO boolValue],
                                  [prefs[S("forceFastChargeIgnoreHeat")] ?: @NO boolValue]);
    ApplyRememberedCPUState();
}

%ctor { @autoreleasepool {
    NSString *processName = [NSProcessInfo processInfo].processName;
    BOOL isThermalOrPower = [processName isEqualToString:S("thermalmonitord")] ||
                            [processName isEqualToString:S("powerd")];
    if (!isThermalOrPower) return;

    // 写边界：IORegistryEntrySetCFProperty（硬件属性写入）兜底拦截。
    void *ioKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (ioKitHandle) {
        void *funcPtr = dlsym(ioKitHandle, "IORegistryEntrySetCFProperty");
        if (funcPtr) {
            MSHookFunction(funcPtr, (void *)hook_IORegistryEntrySetCFProperty, (void **)&orig_IORegistryEntrySetCFProperty);
        }
    }

    int settingsToken = 0;
    dispatch_queue_t prefQueue = dispatch_queue_create("com.huayuarc.cputhermal.mitigation.prefs", DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &settingsToken, prefQueue, ^(int token){
        (void)token;
        RefreshMitigationState();
    });
    int modeToken = 0;
    notify_register_dispatch(kCPUthermalPowerModeChangedNotifC, &modeToken, prefQueue, ^(int token){
        (void)token;
        RefreshMitigationState();
    });
    dispatch_async(prefQueue, ^{ RefreshMitigationState(); });

    // 周期复施：抵消 powerd/thermalmonitord 的高频热决策写回。
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                              1.0 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        // 仅在 thermalmonitord 通过 MitigationController 复施功率目标（powerd 无该控制器）。
        if (![processName isEqualToString:S("thermalmonitord")]) return;
        ApplyRememberedCPUState();
        id cls = (id)objc_getClass("MitigationController");
        SEL sharedSel = sel_registerName("sharedInstance");
        SEL updateSel = sel_registerName("updateCPU");
        if (cls && [cls respondsToSelector:sharedSel]) {
            id controller = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
            if (controller && [controller respondsToSelector:updateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(controller, updateSel);
            }
        }
    });
    dispatch_resume(timer);
} }
