#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <IOKit/IOKitLib.h>
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
@end

// ============================================================================
// 状态
// ============================================================================
static BOOL g_lp_lowPowerActive = NO;

typedef enum {
    LPFullPower = 0,
    LPLowPower  = 1
} LPPowerMode;

// 低功耗频率限制 — iPhone 13 Pro (A15) 70% ≈ 2261 MHz
static NSInteger g_lp_lowTargetMHz = 0;
static const int64_t kLP_MinCapMHz = 1380;
static const int64_t kLP_MaxCapMHz = 1428;

// 定时器
static dispatch_source_t g_lp_timer = NULL;
static const int64_t kLP_TimerIntervalMs = 1500;

// 轮询定时器（回退：监控 plist 变化）
static dispatch_source_t g_lp_pollTimer = NULL;
static NSString *g_lp_lastPollMode = nil;

// 追踪已注册的功率控制器
static NSMutableArray *g_lp_controllers = nil;
static os_unfair_lock g_lp_lock = OS_UNFAIR_LOCK_INIT;

// 钩子状态
static int (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

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
    NSInteger cap = nativeMax * 0.7;
    if (cap < 2016) cap = 2016;
    if (cap > 2400) cap = 2400;
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
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 2);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setCPUPowerCeiling:fromDecisionSource:), 85, @"LowPower");
        }
        NSLog(@"[LowPower] CommonProduct: CPULevel=2 Ceiling=85");
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
        NSLog(@"[LowPower] CommonProduct 恢复");
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
        if ([controller respondsToSelector:@selector(updateCPU)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
        }
        if ([controller respondsToSelector:@selector(updatePackage)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
        }
        NSLog(@"[LowPower] 限制控制器: target=%ldMHz", (long)g_lp_lowTargetMHz);
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
// IOKit IOServiceSetProperty Hook — 钳位 CPU 频率值
// ============================================================================
static int lp_hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (lp_isLowPower()) {
        NSString *ks = (__bridge NSString *)key;
        NSString *lower = [ks lowercaseString];
        BOOL isCPUKey = [lower containsString:@"cpu"] ||
                        [lower containsString:@"clpc"] ||
                        [lower containsString:@"ppm"] ||
                        [lower containsString:@"freq"] ||
                        [lower containsString:@"frequency"] ||
                        [lower containsString:@"lowpower"] ||
                        [lower containsString:@"target"] ||
                        [lower containsString:@"powerzone"] ||
                        [lower containsString:@"mitigat"];

        if (isCPUKey && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            int64_t numVal = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &numVal)) {
                int64_t clamped = lp_clampFreq(numVal);
                if (clamped != numVal) {
                    CFTypeRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &clamped);
                    kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
                    if (replacement) CFRelease(replacement);
                    return ret;
                }
            }
        }
    }
    return orig_IOServiceSetProperty(service, key, value);
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
    } else {
        lp_stopTimer();
        lp_applyState();
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
    if (lp_isLowPower()) { %orig(85, source); return; }
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
        if (level < 0) level = 0;
        if (level > 2) level = 2;
        %orig(level);
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

        // 1. 安装 IOKit IOServiceSetProperty hook（始终安装，条件在 hook 函数内判断）
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            void *sspPtr = dlsym(iokit, "IOServiceSetProperty");
            if (sspPtr) {
                MSHookFunction(sspPtr, (void *)lp_hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
                NSLog(@"[LowPower] IOServiceSetProperty hook 已安装");
            }
        }

        // 2. 如果当前是低功耗模式，立即应用状态并启动定时器
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
            NSLog(@"[LowPower] 已激活 — 目标频率:%ldMHz 保活:%dms", (long)g_lp_lowTargetMHz, (int)kLP_TimerIntervalMs);
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
            } else {
                lp_stopTimer();
                lp_applyState();
            }
            NSLog(@"[LowPower] notify_post 触发模式切换: %@", lp_isLowPower() ? @"低功耗" : @"解除温控");
        });
    }
}
