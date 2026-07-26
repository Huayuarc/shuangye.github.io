#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <IOKit/IOKitLib.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>

// notify.h 通知名（与 CPUthermalPrefs.m 同步）
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

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
- (void)setPackageLowPowerTarget;
- (void)updateCPU;
- (void)updatePackage;
- (void)updatePowerTarget;
- (void)calculateMitigation;
- (void)computePowerTarget;
- (BOOL)powerSaveActive;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
@end

@interface ThermalControl : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (BOOL)powerSaveActive;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface CommonProduct : NSObject
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)tryTakeAction;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)handleMCSThermalPressure;
- (void)simulateLightThermalPressure;
@end

// CommonProduct 实例引用（由 Tweak.x 管理）
extern CommonProduct *g_lp_commonProduct;

// ============================================================================
// 状态 — 移植自一体化版 Tweak.xm 低功耗逻辑
// ============================================================================
static BOOL g_lp_enabled = YES;
static BOOL g_lp_cpuProtection = YES;

typedef enum {
    LPFullPower = 0,
    LPLowPower  = 1
} LPPowerMode;

static LPPowerMode g_lp_powerMode = LPFullPower;

// 低功耗 CPU 频率范围（MHz）— iPhone 13 Pro (A15)
static const int64_t kLP_MinFrequencyMHz = 1428;
static const int64_t kLP_MaxFrequencyMHz = 2016;

// 追踪已注册的功率控制器
static NSMutableArray *g_lp_controllers = nil;
static os_unfair_lock g_lp_lock = OS_UNFAIR_LOCK_INIT;

// IOServiceSetProperty 原始函数指针
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

// _getConfigurationFor 原始函数指针
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

// 保活定时器
static dispatch_source_t g_lp_timer = NULL;
static const int64_t kLP_TimerIntervalMs = 1000;

// 轮询定时器（回退：监控 plist 变化）
static dispatch_source_t g_lp_pollTimer = NULL;
static NSString *g_lp_lastPollMode = nil;

// ============================================================================
// Prefs 路径（与 CPUthermalPrefs.m 一致）
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

// ============================================================================
// 前向声明
// ============================================================================
static void lp_loadPrefs(void);
static BOOL lp_isLowPower(void);
static void lp_applyState(void);
static void lp_startTimer(void);
static void lp_stopTimer(void);

// ============================================================================
// 辅助函数 — 移植自一体化版
// ============================================================================

// 低功耗目标值
static int lp_lowPowerTarget(void) {
    return (int)kLP_MaxFrequencyMHz; // 2016
}

// 判断是否应该应用低功耗限制
static BOOL lp_shouldApplyLowPower(void) {
    return g_lp_enabled && g_lp_cpuProtection && lp_isLowPower();
}

// 频率单位转换
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

// 钳位频率值到低功耗范围
static int64_t lp_clampFreq(int64_t value) {
    int64_t mhz = lp_freqMHzFromValue(value);
    if (mhz < kLP_MinFrequencyMHz) mhz = kLP_MinFrequencyMHz;
    if (mhz > kLP_MaxFrequencyMHz) mhz = kLP_MaxFrequencyMHz;
    return lp_freqValFromMHz(mhz, value);
}

// 检查 key 是否匹配 CPU 频率限制相关
static BOOL lp_keyMatchesCPUFreq(NSString *key) {
    if (!key) return NO;
    NSString *lower = [key lowercaseString];
    BOOL isCPUKey = [lower containsString:@"cpu"] ||
                    [lower containsString:@"ppm"] ||
                    [lower containsString:@"processor"] ||
                    [lower containsString:@"clpc"] ||
                    [lower containsString:@"lowpower"] ||
                    [lower containsString:@"powerzone"] ||
                    [lower containsString:@"mitigat"];
    BOOL isFreqKey = [lower containsString:@"freq"] ||
                     [lower containsString:@"frequency"];
    BOOL isLimitKey = [lower containsString:@"min"] ||
                      [lower containsString:@"max"] ||
                      [lower containsString:@"limit"] ||
                      [lower containsString:@"floor"] ||
                      [lower containsString:@"ceiling"] ||
                      [lower containsString:@"target"];
    BOOL isPowerLimit = isCPUKey && [lower containsString:@"power"] && isLimitKey;
    return (isCPUKey && isFreqKey) || isPowerLimit;
}

// 创建低功耗替换 CFTypeRef 值
static CFTypeRef lp_copyLowPowerFreqValue(NSString *key, CFTypeRef originalValue) {
    if (!lp_keyMatchesCPUFreq(key)) return NULL;
    NSString *lower = [key lowercaseString];
    BOOL isMinKey = [lower containsString:@"min"] ||
                    [lower containsString:@"floor"];
    BOOL isFreqKey = [lower containsString:@"freq"] ||
                     [lower containsString:@"frequency"];

    int64_t original = kLP_MaxFrequencyMHz;
    if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
    } else if (isMinKey && isFreqKey) {
        original = kLP_MinFrequencyMHz;
    }

    int64_t replacement = (isMinKey && isFreqKey)
        ? lp_freqValFromMHz(kLP_MinFrequencyMHz, original)
        : lp_clampFreq(original);
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacement);
}

// ============================================================================
// 追踪控制器
// ============================================================================
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
        g_lp_enabled = [d[@"enabled"] ?: @YES boolValue];
        g_lp_cpuProtection = [d[@"cpuProtection"] ?: @YES boolValue];
        NSString *mode = d[@"thermalPowerMode"] ?: @"off";
        g_lp_powerMode = [mode isEqualToString:@"lowPower"] ? LPLowPower : LPFullPower;
        NSLog(@"[LowPower] prefs: enabled=%d cpuProt=%d mode=%@",
              g_lp_enabled, g_lp_cpuProtection, mode);
    }
}

static BOOL lp_isLowPower(void) {
    return g_lp_enabled && g_lp_cpuProtection && (g_lp_powerMode == LPLowPower);
}

// ============================================================================
// 对 CommonProduct 施加低功耗
// ============================================================================
static void lp_applyLowPowerToCommonProduct(void) {
    if (!g_lp_commonProduct) return;
    @try {
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(g_lp_commonProduct, @selector(setCPMSMitigationsEnabled:), YES);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 1);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setCPUPowerCeiling:fromDecisionSource:), 40, @"LowPower");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setGPUPowerCeiling:fromDecisionSource:), 40, @"LowPower");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setPackagePowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setPackagePowerCeiling:fromDecisionSource:), 40, @"LowPower");
        }
        NSLog(@"[LowPower] CommonProduct: CPULevel=1 Ceiling=40 CPMS=enabled");
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 低功耗失败: %@", e);
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
        if ([g_lp_commonProduct respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setGPUPowerCeiling:fromDecisionSource:), 0, @"LowPower");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setPackagePowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setPackagePowerCeiling:fromDecisionSource:), 0, @"LowPower");
        }
        NSLog(@"[LowPower] CommonProduct 恢复");
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 恢复失败: %@", e);
    }
}

// ============================================================================
// 对单个 MitigationController 施加低功耗限制 — 移植自一体化版
// ============================================================================
static void lp_applyToController(id controller) {
    if (!controller || !lp_shouldApplyLowPower()) return;
    @try {
        if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
        }
        if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
            // 运行时判断参数类型
            BOOL tokenIsObject = NO;
            Method m = class_getInstanceMethod(object_getClass(controller), @selector(setPowerSaveToken:));
            if (m) {
                char type[4] = {0};
                method_getArgumentType(m, 2, type, sizeof(type));
                tokenIsObject = (type[0] == '@');
            }
            if (tokenIsObject) {
                ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setPowerSaveToken:), @1);
            } else {
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), 1);
            }
        }
        if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), lp_lowPowerTarget());
        }
        if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
            ((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
                @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:),
                lp_lowPowerTarget(), NO, (uintptr_t)YES);
        }
        if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller,
                @selector(setCPUPowerCeiling:fromDecisionSource:), lp_lowPowerTarget(), 0);
        }
        if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), lp_lowPowerTarget());
        }
        if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
        }
        if ([controller respondsToSelector:@selector(updateCPU)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
        }
        if ([controller respondsToSelector:@selector(updatePackage)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
        }
        NSLog(@"[LowPower] 限制控制器: target=%dMHz", lp_lowPowerTarget());
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
            if ([c respondsToSelector:@selector(setPowerSaveToken:)]) {
                ((void (*)(id, SEL, int))objc_msgSend)(c, @selector(setPowerSaveToken:), 0);
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
        lp_applyLowPowerToCommonProduct();
        lp_applyToAllControllers();
    } else {
        lp_restoreCommonProduct();
        lp_restoreControllers();
    }
}

// ============================================================================
// 保活定时器 — 定期重新施加低功耗限制
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
// 模式切换处理
// ============================================================================
static void lp_handleModeChange(void) {
    lp_loadPrefs();
    NSString *currentMode = lp_isLowPower() ? @"lowPower" : @"off";
    if (!g_lp_lastPollMode || ![g_lp_lastPollMode isEqualToString:currentMode]) {
        g_lp_lastPollMode = [currentMode copy];
        NSLog(@"[LowPower] 模式变化: %@", currentMode);

        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
        } else {
            lp_stopTimer();
            lp_applyState();
        }
    }
}

// ============================================================================
// IOKit IOServiceSetProperty Hook — 低功耗时钳位 CPU 频率值
// ============================================================================
static kern_return_t lp_hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (!g_lp_enabled) {
        return orig_IOServiceSetProperty(service, key, value);
    }
    if (lp_isLowPower()) {
        NSString *ks = (__bridge NSString *)key;
        if (g_lp_cpuProtection && lp_keyMatchesCPUFreq(ks)) {
            CFTypeRef replacement = lp_copyLowPowerFreqValue(ks, value);
            if (replacement) {
                kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
                CFRelease(replacement);
                return ret;
            }
        }
    }
    return orig_IOServiceSetProperty(service, key, value);
}

// ============================================================================
// _getConfigurationFor Hook — 修补热配置表（低功耗模式）
// 移植自一体化版 Tweak.xm
// ============================================================================
static NSDictionary* lp_new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor(key);
    if (!g_lp_enabled || !g_lp_cpuProtection || !config) return config;
    if (!lp_isLowPower()) return config;

    @autoreleasepool {
        NSMutableDictionary *modified = [config mutableCopy];
        if (!modified) return config;

        // 低功耗：修补 powerSaveParams
        NSMutableDictionary *powerSaveParams = [[modified objectForKey:@"powerSaveParams"] mutableCopy];
        if (powerSaveParams) {
            [powerSaveParams setObject:@(lp_lowPowerTarget()) forKey:@"PackageLowPowerTarget"];
            [powerSaveParams setObject:@(lp_lowPowerTarget()) forKey:@"CPULowPowerTarget"];
            [modified setObject:powerSaveParams forKey:@"powerSaveParams"];
        }

        // 钳位所有热阈值
        NSArray *thresholdKeys = @[
            @"thermalThresholds",
            @"dieTemperatureThresholds",
            @"skinTemperatureThresholds",
            @"componentTemperatureThresholds",
            @"hotTemperatureThresholds"
        ];
        for (NSString *tk in thresholdKeys) {
            id thresholds = modified[tk];
            if ([thresholds isKindOfClass:[NSArray class]]) {
                NSMutableArray *newThresholds = [NSMutableArray array];
                for (NSNumber *val in (NSArray *)thresholds) {
                    int64_t raised = [val longLongValue] + 5000;
                    [newThresholds addObject:@(raised)];
                }
                modified[tk] = newThresholds;
            } else if ([thresholds isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *newDict = [NSMutableDictionary dictionary];
                [(NSDictionary *)thresholds enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                    if ([v isKindOfClass:[NSNumber class]]) {
                        newDict[k] = @([v longLongValue] + 5000);
                    } else {
                        newDict[k] = v;
                    }
                }];
                modified[tk] = newDict;
            }
        }

        NSLog(@"[LowPower] 已修补热配置表: %@ target=%dMHz", key, lp_lowPowerTarget());
        return [modified copy];
    }
}

// ============================================================================
// Darwin 通知回调
// ============================================================================
static void lp_onModeChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    g_lp_lastPollMode = nil; // 强制轮询检测变化
    lp_handleModeChange();
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
// %hook: MitigationController — CPU 功率目标控制（低功耗分支）
// 移植自一体化版 Tweak.xm
// ============================================================================
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) {
        lp_trackController(res);
        if (lp_shouldApplyLowPower()) {
            lp_applyToController(res);
        }
    }
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (lp_shouldApplyLowPower()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(int)token {
    if (lp_shouldApplyLowPower()) { %orig(1); return; }
    %orig;
}

- (BOOL)powerSaveActive {
    if (lp_shouldApplyLowPower()) return YES;
    return %orig;
}

- (void)setCPULowPowerTarget:(int)target {
    if (lp_shouldApplyLowPower()) { %orig(lp_lowPowerTarget()); return; }
    %orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    if (lp_shouldApplyLowPower()) { %orig(lp_lowPowerTarget(), legacy, property); return; }
    %orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (lp_shouldApplyLowPower()) { %orig(lp_lowPowerTarget(), source); return; }
    %orig;
}

- (void)setCPUPowerZoneTarget:(int)target {
    if (lp_shouldApplyLowPower()) { %orig(lp_lowPowerTarget()); return; }
    %orig;
}

- (void)setPackageLowPowerTarget {
    if (lp_shouldApplyLowPower()) { %orig; return; }
    %orig;
}

%end

// ============================================================================
// %hook: ThermalControl — 省电状态
// ============================================================================
%hook ThermalControl

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) {
        lp_trackController(res);
        if (lp_shouldApplyLowPower()) {
            lp_applyToController(res);
        }
    }
    return res;
}

- (id)initWithParams:(id)params {
    id res = %orig(params);
    if (res) {
        lp_trackController(res);
        if (lp_shouldApplyLowPower()) {
            lp_applyToController(res);
        }
    }
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (lp_shouldApplyLowPower()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(id)token {
    if (lp_shouldApplyLowPower()) { %orig([NSNumber numberWithInt:1]); return; }
    %orig;
}

- (BOOL)powerSaveActive {
    if (lp_shouldApplyLowPower()) return YES;
    return %orig;
}

%end

// ============================================================================
// %hook: ApplePPMCPU — CPU P-state 限制
// ============================================================================
%hook ApplePPMCPU

- (void)setCPULevel:(int)level {
    if (lp_shouldApplyLowPower()) {
        if (level < 0) level = 0;
        if (level > 2) level = 2;
        %orig(level);
        return;
    }
    %orig;
}

%end

// ============================================================================
// %ctor — 构造函数
// ============================================================================
%ctor {
    @autoreleasepool {
        lp_loadPrefs();

        // 1. 安装 IOKit IOServiceSetProperty hook
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            void *sspPtr = dlsym(iokit, "IOServiceSetProperty");
            if (sspPtr) {
                MSHookFunction(sspPtr, (void *)lp_hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
                NSLog(@"[LowPower] IOServiceSetProperty hook 已安装");
            }
        }

        // 2. 安装 _getConfigurationFor hook — 热配置修补
        void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
        if (monitor) {
            void *getConfig = dlsym(monitor, "_getConfigurationFor");
            if (getConfig) {
                MSHookFunction(getConfig, (void *)lp_new_getConfigurationFor, (void **)&orig_getConfigurationFor);
                NSLog(@"[LowPower] _getConfigurationFor hook 已安装");
            } else {
                NSLog(@"[LowPower] 未找到 _getConfigurationFor (非致命)");
            }
        } else {
            NSLog(@"[LowPower] 未找到 DeviceMonitor.framework (非致命)");
        }

        // 3. 尝试获取已有的 CommonProduct 实例
        if (!g_lp_commonProduct) {
            Class cpClass = objc_getClass("CommonProduct");
            if (cpClass) {
                SEL sharedSel = @selector(sharedProduct);
                if ([cpClass respondsToSelector:sharedSel]) {
                    id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
                    if (instance) {
                        g_lp_commonProduct = instance;
                        NSLog(@"[LowPower] 获取到已有 CommonProduct: %@", instance);
                    }
                }
            }
        }

        // 4. 如果当前是低功耗模式，立即应用状态并启动定时器
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
            NSLog(@"[LowPower] 已激活 — 目标:%dMHz 保活:%dms",
                  lp_lowPowerTarget(), (int)kLP_TimerIntervalMs);
        } else {
            NSLog(@"[LowPower] 待命中");
        }

        // 5. 启动轮询定时器
        g_lp_lastPollMode = lp_isLowPower() ? @"lowPower" : @"off";
        g_lp_pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        if (g_lp_pollTimer) {
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

        // 6. 注册通知监听
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

        // 7. 注册 notify.h 通知
        int token;
        notify_register_dispatch(kCPUthermalReloadNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            g_lp_lastPollMode = nil;
            lp_handleModeChange();
        });
    }
}
