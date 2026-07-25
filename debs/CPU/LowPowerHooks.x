#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <IOKit/IOKitLib.h>
#include <substrate.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>

// ============================================================================
// 私有类声明
// ============================================================================
@interface MitigationController : NSObject
- (void)setCPULowPowerTarget:(int)target;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
- (void)updateCPU;
- (void)updatePackage;
- (void)updatePowerTarget;
- (void)calculateMitigation;
- (void)computePowerTarget;
- (BOOL)powerSaveActive;
@end

@interface ThermalControl : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (BOOL)powerSaveActive;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface CommonProduct : NSObject
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)tryTakeAction;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)handleMCSThermalPressure;
- (void)simulateLightThermalPressure;
@end

// ============================================================================
// 状态
// ============================================================================
static BOOL g_lp_lowPowerActive = NO;

typedef enum {
    LPFullPower = 0,
    LPLowPower  = 1
} LPPowerMode;

// 低功耗频率限制 — 1428~2016 MHz（约 A15 最大频率 3230 MHz 的 44%~62%）
static NSInteger g_lp_lowTargetMHz = 0;
static const int64_t kLP_MinCapMHz = 1428;
static const int64_t kLP_MaxCapMHz = 2016;

// 定时器 — 大幅缩短保活间隔，防止系统在间隙恢复频率
static dispatch_source_t g_lp_timer = NULL;
static const int64_t kLP_TimerIntervalMs = 300;

// 轮询定时器（回退：监控 plist 变化）
static dispatch_source_t g_lp_pollTimer = NULL;
static NSString *g_lp_lastPollMode = nil;

// 追踪已注册的功率控制器
static NSMutableArray *g_lp_controllers = nil;
static os_unfair_lock g_lp_lock = OS_UNFAIR_LOCK_INIT;

// 钩子状态
static int (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;
static int (*orig_IOConnectCallScalarMethod)(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *) = NULL;
static int (*orig_IOConnectCallStructMethod)(mach_port_t, uint32_t, const void *, size_t, void *, size_t *) = NULL;
static int (*orig_IORegistryEntrySetCFProperty)(io_registry_entry_t, CFStringRef, CFTypeRef) = NULL;

// 系统 sysctl 频率控制（已加锁，防止并发写入）
static os_unfair_lock g_lp_sysctl_lock = OS_UNFAIR_LOCK_INIT;

// CommonProduct 实例引用（由 Tweak.xm 设置）
extern CommonProduct *g_lp_commonProduct;

// notify.h 通知名（与 CPUthermalPrefs.m 同步）
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

// ============================================================================
// 前向声明
// ============================================================================
static void lp_loadPrefs(void);
static BOOL lp_isLowPower(void);
static void lp_applyState(void);
static void lp_startTimer(void);
static void lp_stopTimer(void);
static void lp_startPollTimer(void);
static void lp_handleModeChange(void);
static void lp_enforceSysctlFrequency(BOOL enable);
static void lp_installIOKitHooks(void);

// ============================================================================
// 辅助函数
// ============================================================================

static NSString *lp_prefsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *jbRoot = NSProcessInfo.processInfo.environment[@"JB_ROOT"];
        if (!jbRoot) jbRoot = @(getenv("JB_ROOT") ?: "");
        if (jbRoot.length > 0) {
            path = [jbRoot stringByAppendingPathComponent:@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist"];
        } else {
            path = @"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist";
        }
    });
    return path;
}

static NSDictionary *lp_readPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:lp_prefsPath()];
}

static NSInteger lp_nativeMaxMHz(void) {
    return CPUthermalNativeMaxPCoreFrequencyMHz();
}

static NSInteger lp_lowTargetMHz(void) {
    NSInteger nativeMax = lp_nativeMaxMHz();
    // 取 62% 或 kLP_MaxCapMHz 的较小值，但不低于 kLP_MinCapMHz
    NSInteger cap = nativeMax * 62 / 100;
    if (cap < kLP_MinCapMHz) cap = kLP_MinCapMHz;
    if (cap > kLP_MaxCapMHz) cap = kLP_MaxCapMHz;
    return cap;
}

static int64_t lp_freqMHzFromValue(int64_t value) {
    if (value >= 1000000000LL) return value / 1000000LL;
    if (value >= 1000000LL) return value / 1000LL;
    return value;
}

static int64_t lp_freqValFromMHz(int64_t mhz, int64_t orig) {
    if (orig >= 1000000000LL) return mhz * 1000000LL;
    if (orig >= 1000000LL) return mhz * 1000LL;
    return mhz;
}

static int64_t lp_clampFreq(int64_t value) {
    int64_t mhz = lp_freqMHzFromValue(value);
    if (mhz < kLP_MinCapMHz) mhz = kLP_MinCapMHz;
    if (mhz > kLP_MaxCapMHz) mhz = kLP_MaxCapMHz;
    return lp_freqValFromMHz(mhz, value);
}

static void lp_trackController(id controller) {
    if (!controller) return;
    os_unfair_lock_lock(&g_lp_lock);
    if (!g_lp_controllers) g_lp_controllers = [NSMutableArray array];
    if (![g_lp_controllers containsObject:controller]) {
        [g_lp_controllers addObject:controller];
    }
    os_unfair_lock_unlock(&g_lp_lock);
}

// ============================================================================
// 加载偏好设置
// ============================================================================
static void lp_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = lp_readPrefs() ?: @{};
        NSString *mode = d[@"thermalPowerMode"] ?: @"off";
        g_lp_lowPowerActive = [mode isEqualToString:@"lowPower"];
        g_lp_lowTargetMHz = lp_lowTargetMHz();
        NSLog(@"[LowPower] prefs: mode=%@ target=%ldMHz", mode, (long)g_lp_lowTargetMHz);
    }
}

static BOOL lp_isLowPower(void) {
    return g_lp_lowPowerActive;
}

// ============================================================================
// 低电量模拟（让系统以为电量 20%，触发系统级省电）
// ============================================================================
static void lp_applyBatterySim(BOOL simulate) {
    @autoreleasepool {
        // 构造含 powerMode 的 prefs dict 给 CPUthermalApplyThermalStatusOverridesFromPrefs
        NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
        if (simulate) {
            prefs[@"enabled"] = @YES;
            prefs[@"cpuProtection"] = @YES;
            prefs[@"powerMode"] = @"lowPower";
        } else {
            prefs[@"enabled"] = @NO;
            prefs[@"cpuProtection"] = @NO;
            prefs[@"powerMode"] = @"fullPower";
        }
        int result = CPUthermalApplyThermalStatusOverridesFromPrefs(prefs);
        if (result == kSCStatusOK) {
            NSLog(@"[LowPower] 低电量模拟: %@", simulate ? @"ON (20%)" : @"OFF");
        } else {
            NSLog(@"[LowPower] 低电量模拟写入失败: %d", result);
        }
    }
}

// ============================================================================
// CommonProduct 低功耗状态
// ============================================================================
static void lp_applyLowPowerToCommonProduct(void) {
    if (!g_lp_commonProduct) return;
    @try {
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 1);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setCPUPowerCeiling:fromDecisionSource:), kLP_MaxCapMHz, @"LowPower");
        }
        // 模拟中度热压力，触发系统主动降频
        if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct, @selector(putDeviceInThermalSimulationMode:), @"moderate");
        }
        // 强制 CommonProduct 重新评估
        if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
            ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
        }
        // 额外热压力处理
        if ([g_lp_commonProduct respondsToSelector:@selector(handleMCSThermalPressure)]) {
            ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(handleMCSThermalPressure));
        }
        NSLog(@"[LowPower] CommonProduct: CPULevel=1 Ceiling=%lld moderate sim tryTakeAction", kLP_MaxCapMHz);
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 失败: %@", e);
    }
}

static void lp_restoreCommonProduct(void) {
    if (!g_lp_commonProduct) return;
    @try {
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 0);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setCPUPowerCeiling:fromDecisionSource:), 0, @"LowPower");
        }
        // 恢复原生温控模式
        if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct, @selector(putDeviceInThermalSimulationMode:), @"nominal");
        }
        // 强制重新评估
        if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
            ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
        }
        NSLog(@"[LowPower] CommonProduct 恢复 (nominal)");
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 恢复失败: %@", e);
    }
}

// ============================================================================
// 对 MitigationController 施加低功耗限制
// ============================================================================
static void lp_applyToController(id controller) {
    if (!controller || !lp_isLowPower()) return;
    @try {
        if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
        }
        // setPowerSaveToken: 的参数类型可能是 int 或 id，动态判断
        BOOL tokenIsObject = NO;
        Method m = class_getInstanceMethod(object_getClass(controller), @selector(setPowerSaveToken:));
        if (m) {
            char type[4] = {0};
            method_getArgumentType(m, 2, type, sizeof(type));
            tokenIsObject = (type[0] == '@');
        }
        if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
            if (tokenIsObject) {
                ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setPowerSaveToken:), @1);
            } else {
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), 1);
            }
        }
        if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), (int)g_lp_lowTargetMHz);
        }
        if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
            ((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
                @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:),
                (int)g_lp_lowTargetMHz, NO, YES);
        }
        if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller,
                @selector(setCPUPowerFloor:fromDecisionSource:),
                (int)kLP_MinCapMHz, (uintptr_t)1);
        }
        if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller,
                @selector(setCPUPowerCeiling:fromDecisionSource:),
                (int)kLP_MaxCapMHz, (uintptr_t)1);
        }
        if ([controller respondsToSelector:@selector(updateCPU)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
        }
        if ([controller respondsToSelector:@selector(updatePackage)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
        }
        NSLog(@"[LowPower] 限制控制器: target=%ldMHz floor=%lld ceiling=%lld", (long)g_lp_lowTargetMHz, kLP_MinCapMHz, kLP_MaxCapMHz);
    } @catch (NSException *e) {
        NSLog(@"[LowPower] 控制器限制失败: %@", e);
    }
}

static void lp_applyToAllControllers(void) {
    os_unfair_lock_lock(&g_lp_lock);
    NSArray *controllers = [g_lp_controllers copy];
    os_unfair_lock_unlock(&g_lp_lock);
    for (id c in controllers) {
        lp_applyToController(c);
    }
}

static void lp_restoreControllers(void) {
    os_unfair_lock_lock(&g_lp_lock);
    NSArray *controllers = [g_lp_controllers copy];
    [g_lp_controllers removeAllObjects];
    os_unfair_lock_unlock(&g_lp_lock);

    for (id c in controllers) {
        @try {
            if ([c respondsToSelector:@selector(setPowerSaveActive:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(c, @selector(setPowerSaveActive:), NO);
            }
            if ([c respondsToSelector:@selector(updateCPU)]) {
                ((void (*)(id, SEL))objc_msgSend)(c, @selector(updateCPU));
            }
        } @catch (NSException *e) {
            NSLog(@"[LowPower] 恢复控制器失败: %@", e);
        }
    }
}

// ============================================================================
// 应用当前状态到所有层级
// ============================================================================
static void lp_applyState(void) {
    if (lp_isLowPower()) {
        lp_applyBatterySim(YES);
        lp_applyLowPowerToCommonProduct();
        lp_applyToAllControllers();
    } else {
        lp_applyBatterySim(NO);
        lp_restoreCommonProduct();
        lp_restoreControllers();
    }
}

// ============================================================================
// 定时器 — 保活低功耗状态（系统会不断尝试恢复，需要定期覆盖）
// ============================================================================
static void lp_startTimer(void) {
    if (g_lp_timer) return;
    if (!lp_isLowPower()) return;

    g_lp_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLP_TimerIntervalMs * NSEC_PER_MSEC)),
        (uint64_t)(kLP_TimerIntervalMs * NSEC_PER_MSEC),
        (uint64_t)(20 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_timer, ^{
        @autoreleasepool {
            if (!lp_isLowPower()) {
                lp_stopTimer();
                return;
            }
            lp_applyBatterySim(YES);
            lp_applyLowPowerToCommonProduct();
            lp_applyToAllControllers();
            lp_enforceSysctlFrequency(YES); // 定时器保活时持续执行 sysctl 强制
        }
    });
    dispatch_resume(g_lp_timer);
    NSLog(@"[LowPower] 保活定时器已启动 (%.1fs)", (double)kLP_TimerIntervalMs / 1000.0);
}

static void lp_stopTimer(void) {
    if (g_lp_timer) {
        dispatch_source_cancel(g_lp_timer);
        g_lp_timer = NULL;
        NSLog(@"[LowPower] 保活定时器已停止");
    }
}

// ============================================================================
// 轮询定时器 — 检测 plist 变化（防 Darwin 通知丢失）
// 无论当前模式如何，每秒检查一次 prefs plist
// 当检测到模式变化时立即执行切换
// ============================================================================
static void lp_handleModeChange(void) {
    // 重新加载偏好
    lp_loadPrefs();

    // 检查最后已知模式是否改变
    NSString *currentMode = g_lp_lowPowerActive ? @"lowPower" : @"off";
    if (!g_lp_lastPollMode || ![g_lp_lastPollMode isEqualToString:currentMode]) {
        g_lp_lastPollMode = [currentMode copy];
        NSLog(@"[LowPower] 轮询检测到模式变化: %@", currentMode);

        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
        } else {
            lp_stopTimer();
            lp_applyState();
        }
    }
}

static void lp_startPollTimer(void) {
    if (g_lp_pollTimer) return;

    g_lp_lastPollMode = g_lp_lowPowerActive ? @"lowPower" : @"off";

    g_lp_pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_pollTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        (uint64_t)(1.0 * NSEC_PER_SEC),
        (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_pollTimer, ^{
        @autoreleasepool {
            lp_handleModeChange();
        }
    });
    dispatch_resume(g_lp_pollTimer);
    NSLog(@"[LowPower] 轮询定时器已启动 (1s)");
}

// ============================================================================
// IOKit IOServiceSetProperty Hook — 全面钳位 CPU/功率频率值
// 策略1: 关键字匹配（CPU、频率、功率等）
// 策略2: 数值阈值检测（任何在 800~5000 MHz 范围的值都视为频率）
// ============================================================================
static int lp_hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (!lp_isLowPower()) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    // 只处理数值类型
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    // 读取数值
    int64_t numVal = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &numVal)) {
        return orig_IOServiceSetProperty(service, key, value);
    }

    // 检测该数值是否为频率（MHz 转换）
    int64_t mhz = lp_freqMHzFromValue(numVal);
    BOOL shouldClamp = NO;

    // 策略1: 关键字匹配 — 覆盖所有已知的 CPU/功率控制键
    NSString *ks = (__bridge NSString *)key;
    NSString *lower = [ks lowercaseString];
    NSArray *keywords = @[
        @"cpu", @"clpc", @"ppm", @"perf", @"performance",
        @"freq", @"frequency", @"lowpower", @"low_power",
        @"target", @"powerzone", @"mitigat", @"mitigation",
        @"power", @"ceiling", @"floor", @"package",
        @"zone", @"volt", @"voltage", @"current",
        @"p-state", @"pstate", @"cstate", @"c-state",
        @"throttle", @"thermal", @"energy", @"efficien",
        @"sustained", @"peak", @"turbo", @"boost",
        @"corelimit", @"cluster", @"pcluster", @"ecluster",
        @"opp", @"dvfs", @"cpm", @"cpmd",
    ];
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) {
            shouldClamp = YES;
            break;
        }
    }

    // 策略2: 数值阈值检测 — 任何处于 CPU 频率范围的数值都钳位
    if (!shouldClamp) {
        // MHz 值范围: 800~5000
        // Hz 值范围:  800000000~5000000000
        if ((mhz >= 800 && mhz <= 5000) ||
            (numVal >= 800000000LL && numVal <= 5000000000LL)) {
            shouldClamp = YES;
        }
    }

    if (shouldClamp) {
        int64_t clamped = lp_clampFreq(numVal);
        if (clamped != numVal) {
            CFTypeRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &clamped);
            kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
            if (replacement) CFRelease(replacement);
            return ret;
        }
    }

    return orig_IOServiceSetProperty(service, key, value);
}

// ============================================================================
// IOConnectCallScalarMethod Hook — 拦截对 ApplePPM 内核扩展的直接标量调用
// ApplePPM/AppleARMIO 通过此函数向 kernel 发送 P-state 频率请求
// 策略：筛选参数中包含 CPU 频率值（800-5000 MHz）的调用并钳位
// ============================================================================
static kern_return_t lp_hooked_IOConnectCallScalarMethod(
    mach_port_t connection, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    uint64_t *output, uint32_t *outputCnt)
{
    if (!lp_isLowPower()) {
        return orig_IOConnectCallScalarMethod(connection, selector, input, inputCnt, output, outputCnt);
    }

    // 复制 input 数组并钳位其中的频率值
    uint64_t clampedInput[16];
    BOOL modified = NO;
    uint32_t cnt = (inputCnt > 16) ? 16 : inputCnt;
    memcpy(clampedInput, input, cnt * sizeof(uint64_t));

    for (uint32_t i = 0; i < cnt; i++) {
        uint64_t val = clampedInput[i];
        int64_t mhz = 0;
        if (val >= 1000000000LL)      mhz = val / 1000000LL;
        else if (val >= 1000000LL)     mhz = val / 1000LL;
        else                           mhz = val;

        // 钳位: 800~5000 MHz 范围的频率值
        if (mhz >= 800 && mhz <= 5000) {
            int64_t clamped = mhz;
            if (clamped > kLP_MaxCapMHz) clamped = kLP_MaxCapMHz;
            if (clamped < kLP_MinCapMHz) clamped = kLP_MinCapMHz;
            if (clamped != mhz) {
                uint64_t newVal;
                if (val >= 1000000000LL)      newVal = clamped * 1000000LL;
                else if (val >= 1000000LL)    newVal = clamped * 1000LL;
                else                          newVal = clamped;
                clampedInput[i] = newVal;
                modified = YES;
            }
        }
    }

    if (modified) {
        return orig_IOConnectCallScalarMethod(connection, selector, clampedInput, inputCnt, output, outputCnt);
    }
    return orig_IOConnectCallScalarMethod(connection, selector, input, inputCnt, output, outputCnt);
}

// ============================================================================
// IOConnectCallStructMethod Hook — 拦截结构体形式的 PPM 频率请求
// ============================================================================
static kern_return_t lp_hooked_IOConnectCallStructMethod(
    mach_port_t connection, uint32_t selector,
    const void *inputStruct, size_t inputStructCnt,
    void *outputStruct, size_t *outputStructCnt)
{
    if (!lp_isLowPower()) {
        return orig_IOConnectCallStructMethod(connection, selector, inputStruct, inputStructCnt, outputStruct, outputStructCnt);
    }

    // 复制 input 结构体并扫描其中的频率值
    size_t bufSize = (inputStructCnt > 256) ? 256 : inputStructCnt;
    uint8_t buf[256];
    memcpy(buf, inputStruct, bufSize);
    BOOL patched = NO;

    // 以 4 字节对齐扫描内存中的频率值
    for (size_t offset = 0; offset + 4 <= bufSize; offset += 4) {
        uint32_t val32 = 0;
        memcpy(&val32, buf + offset, 4);
        int64_t mhz = 0;
        if (val32 >= 1000000000)      mhz = val32 / 1000000;
        else if (val32 >= 1000000)    mhz = val32 / 1000;
        else                          mhz = val32;

        if (mhz >= 800 && mhz <= 5000 && mhz > kLP_MaxCapMHz) {
            uint32_t clamped = (uint32_t)(kLP_MaxCapMHz * 1000000ULL);
            memcpy(buf + offset, &clamped, 4);
            patched = YES;
        }
    }
    // 以 8 字节对齐扫描
    for (size_t offset = 0; offset + 8 <= bufSize; offset += 8) {
        uint64_t val64 = 0;
        memcpy(&val64, buf + offset, 8);
        int64_t mhz = 0;
        if (val64 >= 1000000000LL)      mhz = val64 / 1000000LL;
        else if (val64 >= 1000000LL)    mhz = val64 / 1000LL;
        else                           continue;

        if (mhz >= 800 && mhz <= 5000 && mhz > kLP_MaxCapMHz) {
            uint64_t clamped = (uint64_t)kLP_MaxCapMHz * 1000000ULL;
            memcpy(buf + offset, &clamped, 8);
            patched = YES;
        }
    }

    if (patched) {
        return orig_IOConnectCallStructMethod(connection, selector, buf, inputStructCnt, outputStruct, outputStructCnt);
    }
    return orig_IOConnectCallStructMethod(connection, selector, inputStruct, inputStructCnt, outputStruct, outputStructCnt);
}

// ============================================================================
// IORegistryEntrySetCFProperty Hook — 截获通过 IORegistry 设置的频率属性
// 某些系统组件不走 IOServiceSetProperty 而走此函数
// ============================================================================
static kern_return_t lp_hooked_IORegistryEntrySetCFProperty(
    io_registry_entry_t entry, CFStringRef key, CFTypeRef value)
{
    if (!lp_isLowPower()) {
        return orig_IORegistryEntrySetCFProperty(entry, key, value);
    }
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return orig_IORegistryEntrySetCFProperty(entry, key, value);
    }
    int64_t numVal = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &numVal)) {
        return orig_IORegistryEntrySetCFProperty(entry, key, value);
    }
    int64_t mhz = 0;
    if (numVal >= 1000000000LL)      mhz = numVal / 1000000LL;
    else if (numVal >= 1000000LL)    mhz = numVal / 1000LL;
    else                             mhz = numVal;

    if (mhz >= 800 && mhz <= 5000 && mhz > kLP_MaxCapMHz) {
        int64_t clamped = kLP_MaxCapMHz;
        uint64_t clampedVal;
        if (numVal >= 1000000000LL)      clampedVal = clamped * 1000000LL;
        else if (numVal >= 1000000LL)    clampedVal = clamped * 1000LL;
        else                             clampedVal = clamped;
        CFTypeRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &clampedVal);
        kern_return_t ret = orig_IORegistryEntrySetCFProperty(entry, key, replacement);
        if (replacement) CFRelease(replacement);
        return ret;
    }
    return orig_IORegistryEntrySetCFProperty(entry, key, value);
}

// ============================================================================
// Sysctl CPU 频率强制 — 在 kernel 层直接设置频率上限
// 作为 IOKit hook 的补充加固层
// ============================================================================
static void lp_enforceSysctlFrequency(BOOL enable) {
    os_unfair_lock_lock(&g_lp_sysctl_lock);
    if (enable) {
        // 设置 CPU 最大 P-state 限制（不同 iOS 版本节点名不同，全部尝试）
        const char *sysctl_nodes[] = {
            "kern.cpuhog",
            "kern.max_cpu_freq",
            "kern.cpu_max_freq_mhz",
            "hw.cpufrequency_max",
            "hw.cpufrequency",
            "kern.max_cpu_percent",
            NULL
        };
        int64_t targetMHz = (int64_t)kLP_MaxCapMHz;
        for (int i = 0; sysctl_nodes[i] != NULL; i++) {
            int ret = sysctlbyname(sysctl_nodes[i], NULL, NULL, &targetMHz, sizeof(targetMHz));
            if (ret == 0) {
                NSLog(@"[LowPower] sysctl 设置 %s = %lld MHz", sysctl_nodes[i], targetMHz);
            }
        }
        // 备用：通过 posix_spawn 执行 sysctl 命令
        // 某些 sysctl 节点只能通过工具写入
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            pid_t pid = 0;
            const char *argv[] = {
                "/usr/sbin/sysctl", "-w",
                "kern.max_cpu_freq_mhz=2016",
                NULL
            };
            posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
            if (pid > 0) waitpid(pid, NULL, 0);
        });
    }
    os_unfair_lock_unlock(&g_lp_sysctl_lock);
}

// ============================================================================
// 安装所有 IOKit 用户态客户端钩子
// ============================================================================
static void lp_installIOKitHooks(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!iokit) {
        NSLog(@"[LowPower] 无法加载 IOKit.framework");
        return;
    }

    // 1. IOServiceSetProperty (已有)
    void *sym = dlsym(iokit, "IOServiceSetProperty");
    if (sym) {
        MSHookFunction(sym, (void *)lp_hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
        NSLog(@"[LowPower] IOServiceSetProperty hook 已安装");
    }

    // 2. IOConnectCallScalarMethod
    sym = dlsym(iokit, "IOConnectCallScalarMethod");
    if (sym) {
        MSHookFunction(sym, (void *)lp_hooked_IOConnectCallScalarMethod, (void **)&orig_IOConnectCallScalarMethod);
        NSLog(@"[LowPower] IOConnectCallScalarMethod hook 已安装");
    }

    // 3. IOConnectCallStructMethod
    sym = dlsym(iokit, "IOConnectCallStructMethod");
    if (sym) {
        MSHookFunction(sym, (void *)lp_hooked_IOConnectCallStructMethod, (void **)&orig_IOConnectCallStructMethod);
        NSLog(@"[LowPower] IOConnectCallStructMethod hook 已安装");
    }

    // 4. IORegistryEntrySetCFProperty
    sym = dlsym(iokit, "IORegistryEntrySetCFProperty");
    if (sym) {
        MSHookFunction(sym, (void *)lp_hooked_IORegistryEntrySetCFProperty, (void **)&orig_IORegistryEntrySetCFProperty);
        NSLog(@"[LowPower] IORegistryEntrySetCFProperty hook 已安装");
    }

    dlclose(iokit);
}

// ============================================================================
// Darwin 通知回调
// ============================================================================
static void lp_onModeChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    lp_loadPrefs();
    // 同步轮询定时器的最后已知模式，防止重复执行
    g_lp_lastPollMode = g_lp_lowPowerActive ? @"lowPower" : @"off";
    if (lp_isLowPower()) {
        lp_applyState();
        lp_startTimer();
        lp_enforceSysctlFrequency(YES);
    } else {
        lp_stopTimer();
        lp_applyState();
        lp_enforceSysctlFrequency(NO);
    }
    NSLog(@"[LowPower] 模式切换: %@", lp_isLowPower() ? @"低功耗" : @"解除温控");
}

static void lp_onWakeEvent(CFNotificationCenterRef center, void *observer,
                            CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    if (lp_isLowPower()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            lp_loadPrefs();
            lp_applyState();
            lp_startTimer();
            lp_enforceSysctlFrequency(YES);
        });
    }
}

// ============================================================================
// %hook: MitigationController — CPU 功率目标控制
// ============================================================================
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) lp_trackController(res);
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (lp_isLowPower()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(int)token {
    if (lp_isLowPower()) { %orig(1); return; }
    %orig;
}

- (BOOL)powerSaveActive {
    if (lp_isLowPower()) return YES;
    return %orig;
}

- (void)setCPULowPowerTarget:(int)target {
    if (lp_isLowPower()) { %orig((int)g_lp_lowTargetMHz); return; }
    %orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    if (lp_isLowPower()) { %orig((int)lp_clampFreq(target), legacy, property); return; }
    %orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (lp_isLowPower()) { %orig((int)kLP_MaxCapMHz, source); return; }
    %orig;
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
    if (lp_isLowPower()) { %orig((int)kLP_MinCapMHz, source); return; }
    %orig;
}

- (void)setCPUPowerZoneTarget:(int)target {
    if (lp_isLowPower()) { %orig((int)lp_clampFreq(target)); return; }
    %orig;
}

%end

// ============================================================================
// %hook: ThermalControl — 省电状态
// ============================================================================
%hook ThermalControl

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) lp_trackController(res);
    return res;
}

- (id)initWithParams:(id)params {
    id res = %orig(params);
    if (res) lp_trackController(res);
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (lp_isLowPower()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(id)token {
    if (lp_isLowPower()) { %orig([NSNumber numberWithInt:1]); return; }
    %orig;
}

- (BOOL)powerSaveActive {
    if (lp_isLowPower()) return YES;
    return %orig;
}

%end

// ============================================================================
// %hook: ApplePPMCPU — CPU P-state 限制
// ============================================================================
%hook ApplePPMCPU

- (void)setCPULevel:(int)level {
    if (lp_isLowPower()) {
        // 始终强制到 level 1（平衡模式），阻止系统恢复到 level 0（最高性能）
        // level 0 = 最高性能(全部核+最高频)、level 1 = 平衡、level 2 = 最低功耗
        %orig(1);
        return;
    }
    %orig;
}

%end

// ============================================================================
// %ctor — 构造函数（始终安装钩子，条件执行）
// ============================================================================
%ctor {
    @autoreleasepool {
        lp_loadPrefs();

        // 1. 安装所有 IOKit 钩子（始终安装，条件在 hook 函数内判断）
        lp_installIOKitHooks();

        // 1.5 尝试获取已有的 CommonProduct 实例（防止 hook 安装前已初始化）
        if (!g_lp_commonProduct) {
            Class cpClass = objc_getClass("CommonProduct");
            if (cpClass) {
                SEL sharedSel = @selector(sharedProduct);
                if ([cpClass respondsToSelector:sharedSel]) {
                    id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
                    if (instance) {
                        g_lp_commonProduct = instance;
                        // 同步到 CPUthermalHelper via runtime（避免直接 import 导致 @interface 冲突）
                        Class helperClass = objc_getClass("CPUthermalHelper");
                        if (helperClass) {
                            SEL sharedHelperSel = @selector(shared);
                            id helper = ((id (*)(id, SEL))objc_msgSend)(helperClass, sharedHelperSel);
                            if (helper) {
                                SEL setCPSel = @selector(setCommonProductObject:);
                                ((void (*)(id, SEL, id))objc_msgSend)(helper, setCPSel, instance);
                            }
                        }
                        NSLog(@"[LowPower] 获取到已有 CommonProduct: %@", instance);
                    }
                }
            }
        }

        // 2. 如果当前是低功耗模式，立即应用状态并启动定时器
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
            lp_enforceSysctlFrequency(YES); // sysctl 频率强制
            NSLog(@"[LowPower] 已激活 — 目标频率:%ldMHz 保活:%dms 已执行 sysctl 强制", (long)g_lp_lowTargetMHz, (int)kLP_TimerIntervalMs);
        } else {
            NSLog(@"[LowPower] 待命中（可在运行时切换激活）");
        }

        // 3. 启动轮询定时器（无论当前模式是什么，每秒检测变化）
        //    作为 Darwin 通知丢失的回退方案
        lp_startPollTimer();

        // 4. 注册通知监听 — 始终注册，支持运行时切换
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, lp_onModeChanged,
                CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c, NULL, lp_onWakeEvent,
                CFSTR("com.apple.springboard.hasFinishedUnblankingScreen"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(c, NULL, lp_onWakeEvent,
                CFSTR("com.apple.springboard.lockstate"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // 5. 注册 notify.h 通知监听（与 CFNotificationCenter 互补）
        int token;
        notify_register_dispatch(kCPUthermalReloadNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            lp_loadPrefs();
            g_lp_lastPollMode = g_lp_lowPowerActive ? @"lowPower" : @"off";
            if (lp_isLowPower()) {
                lp_applyState();
                lp_startTimer();
                lp_enforceSysctlFrequency(YES);
            } else {
                lp_stopTimer();
                lp_applyState();
                lp_enforceSysctlFrequency(NO);
            }
            NSLog(@"[LowPower] notify_post 触发模式切换: %@", lp_isLowPower() ? @"低功耗" : @"解除温控");
        });
    }
}
