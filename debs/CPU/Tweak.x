#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <IOKit/IOKitLib.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>
#import "CPUthermalHelper.h"

// ============================================================================
// notify.h 通知名（与 CPUthermalPrefs.m 同步）
// ============================================================================
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

// ============================================================================
// 动态查找 CommonProduct 实例（当 weak/strong 引用丢失时备用）
// ============================================================================
__attribute__((visibility("default"))) CommonProduct *g_lp_commonProduct = nil;

// ============================================================================
// 私有类声明（无对应 header 的类）
// ============================================================================
@interface ThermalControl : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (BOOL)powerSaveActive;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (float)calculateControlEffort:(id)trigger;
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
- (void)updatePowerParameters:(id)params;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface ApplePPMGPU : NSObject
- (void)setGPULevel:(int)level;
- (void)updateGPU;
@end

@interface TableDrivenLowTempController : NSObject
- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra;
@end

@interface FormulaDrivenLowTempController : NSObject
- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra;
@end

@interface FormulaDrivenLowTempController_CPU : FormulaDrivenLowTempController
@end

@interface FormulaDrivenLowTempController_GPU : FormulaDrivenLowTempController
@end

// ============================================================================
// 低功耗状态
// ============================================================================

typedef enum {
    CPUthermalPowerModeFull = 0,
    CPUthermalPowerModeLow  = 1
} CPUthermalPowerMode;

static BOOL g_lp_enabled = NO;
static CPUthermalPowerMode g_powerMode = CPUthermalPowerModeFull;

// 低功耗模式 CPU 频率限制（MHz）
// 只限制上限，不强制抬高最低频
static const int64_t kLowPowerMinFrequencyMHz = 1380;
static const int64_t kLowPowerMaxFrequencyMHz = 2016;

static BOOL g_applyingLowPower = NO;
static NSMutableArray *g_lp_controllers = nil;
static os_unfair_lock g_lp_lock = OS_UNFAIR_LOCK_INIT;

// 原始值追踪 — 用于恢复 full power 状态
static NSMutableDictionary *g_originalControllerValues = nil;

// 定时器
static dispatch_source_t g_lp_timer = NULL;
static const int64_t kLPTimerIntervalMs = 2000;

// IOKit 钩子原始函数指针
static int (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;
static BOOL g_restoringPower = NO;

// ============================================================================
// 前向声明
// ============================================================================
static void lp_loadPrefs(void);
static BOOL lp_isLowPower(void);
static BOOL shouldApplyLowPowerLimit(void);
static void lp_applyState(void);
static void lp_applyLowPowerToCommonProduct(void);
static void lp_applyToAllControllers(void);
static void lp_startTimer(void);
static void lp_stopTimer(void);
static int64_t lp_clampFreq(int64_t value);

// Helper 前向声明
static CommonProduct *CPUthermalFindCommonProduct(void);
static void CPUthermalSyncCommonProduct(void);
static void CPUthermalApplyMode(void);

// ============================================================================
// 低功耗辅助函数
// ============================================================================

static NSString *lp_prefsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = rootlessPath(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist");
    });
    return path;
}

static NSDictionary *lp_readPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:lp_prefsPath()];
}

static int lp_lowTargetMHz(void) {
    return (int)kLowPowerMaxFrequencyMHz;
}

static int lp_lowPowerCeiling(void) {
    return 40;
}

// ============================================================================
// 频率工具函数（来自 CPU (1) 经验证的实现）
// ============================================================================

static int64_t lp_freqMHzFromValue(int64_t value) {
    if (value >= 1000000000LL) return value / 1000000LL;
    if (value >= 1000000LL) return value / 1000LL;
    return value;
}

static int64_t lp_freqValFromMHz(int64_t mhz, int64_t originalValue) {
    if (originalValue >= 1000000000LL) return mhz * 1000000LL;
    if (originalValue >= 1000000LL) return mhz * 1000LL;
    return mhz;
}

static int64_t lp_clampFreq(int64_t value) {
    int64_t mhz = lp_freqMHzFromValue(value);
    if (mhz < kLowPowerMinFrequencyMHz) mhz = kLowPowerMinFrequencyMHz;
    if (mhz > kLowPowerMaxFrequencyMHz) mhz = kLowPowerMaxFrequencyMHz;
    return lp_freqValFromMHz(mhz, value);
}

static BOOL lp_keyMatchesLowPowerLimit(NSString *key) {
    if (!key) return NO;
    NSString *lower = [key lowercaseString];
    BOOL isCPUKey = [lower containsString:S("cpu")] ||
                    [lower containsString:S("ppm")] ||
                    [lower containsString:S("processor")];
    BOOL isFrequencyKey = [lower containsString:S("freq")] ||
                          [lower containsString:S("frequency")];
    BOOL isLowPowerTargetKey = (isCPUKey || [lower containsString:S("package")]) &&
                                [lower containsString:S("lowpower")] &&
                                [lower containsString:S("target")];
    BOOL isMaxCPUPowerTargetKey = isCPUKey &&
                                   [lower containsString:S("max")] &&
                                   [lower containsString:S("power")] &&
                                   [lower containsString:S("target")];
    BOOL isPowerZoneTargetKey = isCPUKey &&
                                 [lower containsString:S("powerzone")] &&
                                 [lower containsString:S("target")];
    BOOL isPStateKey = [lower containsString:S("pstate")] || [lower containsString:S("cluster")];

    // ==========新增A15必须匹配的底层功耗键名==========
    BOOL extraPowerKeys = [lower containsString:@"performance"]
                        || [lower containsString:@"dvfs"]
                        || [lower containsString:@"domain"]
                        || [lower containsString:@"ratio"];

    return (isCPUKey && isFrequencyKey)
            || isLowPowerTargetKey
            || isMaxCPUPowerTargetKey
            || isPowerZoneTargetKey
            || isPStateKey
            || extraPowerKeys;
}

// ============================================================================
// 加载偏好设置
// ============================================================================
static void lp_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = lp_readPrefs() ?: @{};
        NSString *mode = d[S("thermalPowerMode")] ?: S("off");
        if ([mode isEqualToString:S("lowPower")]) {
            g_lp_enabled = YES;
            g_powerMode = CPUthermalPowerModeLow;
        } else {
            g_lp_enabled = NO;
            g_powerMode = CPUthermalPowerModeFull;
        }
        NSLog(@"[LowPower] prefs: mode=%@ active=%d target=%dMHz",
              mode, g_lp_enabled, lp_lowTargetMHz());
    }
}

static BOOL lp_isLowPower(void) {
    return g_lp_enabled && (g_powerMode == CPUthermalPowerModeLow);
}

static BOOL shouldApplyLowPowerLimit(void) {
    return lp_isLowPower();
}

// ============================================================================
// 控制器原始值追踪
// ============================================================================
static NSString *lp_controllerKey(id controller, const char *name) {
    return [NSString stringWithFormat:S("%p:%s"), controller, name];
}

static void lp_rememberOrigInt(id controller, const char *name, int value) {
    if (!controller || g_restoringPower || g_applyingLowPower) return;
    if (value <= lp_lowTargetMHz()) return;
    if (!g_originalControllerValues) g_originalControllerValues = [NSMutableDictionary dictionary];
    NSString *key = lp_controllerKey(controller, name);
    if (!key || [g_originalControllerValues objectForKey:key]) return;
    [g_originalControllerValues setObject:[NSNumber numberWithInt:value] forKey:key];
}

// ============================================================================
// CommonProduct 低功耗状态（来自 CPU (1) 验证有效的实现）
// ============================================================================
static void lp_applyLowPowerToCommonProduct(void) {
    if (!g_lp_commonProduct || !shouldApplyLowPowerLimit()) return;
    @try {
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 1);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                @selector(setCPUPowerCeiling:fromDecisionSource:), lp_lowPowerCeiling(), S("CPUthermal"));
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                @selector(setGPUPowerCeiling:fromDecisionSource:), lp_lowPowerCeiling(), S("CPUthermal"));
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setPackagePowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                @selector(setPackagePowerCeiling:fromDecisionSource:), lp_lowPowerCeiling(), S("CPUthermal"));
        }
        NSLog(@"[LowPower] CommonProduct: CPULevel=1 Ceiling=%d", lp_lowPowerCeiling());
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
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                @selector(setCPUPowerCeiling:fromDecisionSource:), 0, S("CPUthermal"));
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                @selector(setGPUPowerCeiling:fromDecisionSource:), 0, S("CPUthermal"));
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setPackagePowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                @selector(setPackagePowerCeiling:fromDecisionSource:), 0, S("CPUthermal"));
        }
        NSLog(@"[LowPower] CommonProduct 已恢复");
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 恢复失败: %@", e);
    }
}

// ============================================================================
// 控制器追踪
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
// 对单个控制器施加低功耗限制（来自 CPU (1) 验证有效的实现）
// ============================================================================
static void lp_applyToController(id controller) {
    if (!controller || !shouldApplyLowPowerLimit()) return;
    @try {
        g_applyingLowPower = YES;
        if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
        }
        if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
            // 检测 token 参数类型（int vs id）
            Method m = class_getInstanceMethod(object_getClass(controller), @selector(setPowerSaveToken:));
            if (m) {
                char type[4] = {0};
                method_getArgumentType(m, 2, type, sizeof(type));
                if (type[0] == '@') {
                    ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setPowerSaveToken:), [NSNumber numberWithInt:1]);
                } else {
                    ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), 1);
                }
            } else {
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), 1);
            }
        }
        if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), lp_lowTargetMHz());
        }
        if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
            ((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
                @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:),
                lp_lowTargetMHz(), NO, (uintptr_t)YES);
        }
        if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller,
                @selector(setCPUPowerCeiling:fromDecisionSource:), lp_lowPowerCeiling(), 0);
        }
        if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), lp_lowTargetMHz());
        }
        if ([controller respondsToSelector:@selector(updateCPU)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
        }
        if ([controller respondsToSelector:@selector(updatePackage)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
        }
        NSLog(@"[LowPower] 限制控制器: target=%dMHz ceiling=%d controller:%@",
              lp_lowTargetMHz(), lp_lowPowerCeiling(), controller);
    } @catch (NSException *e) {
        NSLog(@"[LowPower] 控制器限制失败: %@", e);
    } @finally {
        g_applyingLowPower = NO;
    }
}

// ============================================================================
// 强制参数覆盖 — 在 updateCPU 末尾调用，强制执行低功耗参数
// ============================================================================
static void lp_forcePushControllerParams(id controller) {
    if(!shouldApplyLowPowerLimit()) return;
    @try{
        if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), lp_lowTargetMHz());
        }
        if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller,
                @selector(setCPUPowerCeiling:fromDecisionSource:), lp_lowPowerCeiling(), 0);
        }
        if ([controller respondsToSelector:@selector(updateCPU)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
        }
    }@catch(NSException *e){}
}

static void lp_applyToAllControllers(void) {
    if (!shouldApplyLowPowerLimit()) return;
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
    [g_originalControllerValues removeAllObjects];
    NSLog(@"[LowPower] 控制器已恢复");
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
// 保活定时器 — 每 2 秒重新应用低功耗状态（系统会不断尝试恢复）
// ============================================================================
static void lp_startTimer(void) {
    if (g_lp_timer) return;
    if (!lp_isLowPower()) return;

    g_lp_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLPTimerIntervalMs * NSEC_PER_MSEC)),
        (uint64_t)(kLPTimerIntervalMs * NSEC_PER_MSEC),
        (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_timer, ^{
    @autoreleasepool {
        if (!lp_isLowPower()) {
            lp_stopTimer();
            return;
        }
        CPUthermalSyncCommonProduct();
        lp_applyLowPowerToCommonProduct();
        lp_applyToAllControllers();
        
        // ===新增主动强制锁频逻辑===
        Class ppmClass = objc_getClass("ApplePPMCPU");
        if(ppmClass){
            // 遍历PPM实例（简化方案：发送全局设置指令）
            id ppmObj = CPUthermalFindCommonProduct();
            if(ppmObj && [ppmObj respondsToSelector:@selector(setCPULevel:)]){
                ((void (*)(id, SEL, int))objc_msgSend)(ppmObj, @selector(setCPULevel:),1);
            }
        }
    }
});

}

static void lp_stopTimer(void) {
    if (g_lp_timer) {
        dispatch_source_cancel(g_lp_timer);
        g_lp_timer = NULL;
    }
}

// ============================================================================
// IOKit IOServiceSetProperty Hook — 低功耗模式下钳位 CPU 频率值
// ============================================================================
static int lp_hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (lp_isLowPower()) {
        NSString *ks = (__bridge NSString *)key;
        if (lp_keyMatchesLowPowerLimit(ks) && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
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
// _getConfigurationFor C 函数 Hook — 低功耗配置修补
// ============================================================================
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

static NSDictionary* lp_new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor(key);
    if (!shouldApplyLowPowerLimit() || !config) return config;

    @autoreleasepool {
        NSMutableDictionary *modified = [config mutableCopy];
        if (!modified) return config;

        // 低功耗模式下：修改配置表中的电源参数
        NSMutableDictionary *powerSaveParams = [[modified objectForKey:S("powerSaveParams")] mutableCopy];
        if (powerSaveParams) {
            [powerSaveParams setObject:[NSNumber numberWithInt:lp_lowTargetMHz()]
                                forKey:S("PackageLowPowerTarget")];
            [powerSaveParams setObject:[NSNumber numberWithInt:lp_lowTargetMHz()]
                                forKey:S("CPULowPowerTarget")];
            [modified setObject:powerSaveParams forKey:S("powerSaveParams")];
        }

        // 钳位配置表中的频率值
        for (NSString *keyPath in [modified allKeys]) {
            id val = modified[keyPath];
            if ([val isKindOfClass:[NSNumber class]]) {
                NSNumber *num = (NSNumber *)val;
                if (lp_keyMatchesLowPowerLimit(keyPath)) {
                    int64_t clamped = lp_clampFreq([num longLongValue]);
                    modified[keyPath] = [NSNumber numberWithLongLong:clamped];
                }
            }
        }

        NSLog(@"[LowPower] 已修补热配置: %@ target:%dMHz", key, lp_lowTargetMHz());
        return [modified copy];
    }
}

// ============================================================================
// Darwin 通知回调 — 低功耗模式切换
// ============================================================================
static void lp_onModeChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    CPUthermalSyncCommonProduct();
    CPUthermalApplyMode();

    lp_loadPrefs();
    if (lp_isLowPower()) {
        lp_applyState();
        lp_startTimer();
    } else {
        lp_stopTimer();
        lp_applyState();
    }
    NSLog(@"[LowPower] 模式切换: %@ — 目标频率:%dMHz",
          lp_isLowPower() ? S("低功耗") : S("解除"),
          lp_lowTargetMHz());
}

static void lp_onWakeEvent(CFNotificationCenterRef center, void *observer,
                            CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CPUthermalSyncCommonProduct();
        lp_loadPrefs();
        if (lp_isLowPower()) {
            CPUthermalApplyMode();
            lp_applyState();
            lp_startTimer();
            NSLog(@"[LowPower] 唤醒后重新激活低功耗模式");
        }
    });
}

// ============================================================================
// %hook: MitigationController — CPU 功率目标控制（来自 CPU (1) 验证有效的实现）
// ============================================================================
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) lp_trackController(res);
    return res;
}

- (BOOL)powerSaveActive {
    if (g_restoringPower) return %orig;
    if (shouldApplyLowPowerLimit()) return YES;
    return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (g_restoringPower) { %orig(active); return; }
    if (shouldApplyLowPowerLimit()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(int)token {
    if (g_restoringPower) { %orig(token); return; }
    if (shouldApplyLowPowerLimit()) { %orig(1); return; }
    %orig;
}

- (void)setCPULowPowerTarget:(int)target {
    if (g_restoringPower) { %orig(target); return; }
    if (shouldApplyLowPowerLimit()) { %orig(lp_lowTargetMHz()); return; }
    %orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    if (g_restoringPower) { %orig(target, legacy, property); return; }
    if (shouldApplyLowPowerLimit()) {
        lp_rememberOrigInt(self, "MaxCPUPowerTarget", target);
        %orig((int)lp_clampFreq(target), legacy, property);
        return;
    }
    %orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (g_restoringPower) { %orig(ceiling, source); return; }
    if (shouldApplyLowPowerLimit()) {
        lp_rememberOrigInt(self, "CPUPowerCeiling", ceiling);
        %orig(lp_lowPowerCeiling(), source);
        return;
    }
    %orig;
}

- (void)setCPUPowerZoneTarget:(int)target {
    if (g_restoringPower) { %orig(target); return; }
    if (shouldApplyLowPowerLimit()) {
        lp_rememberOrigInt(self, "CPUPowerZoneTarget", target);
        %orig((int)lp_clampFreq(target));
        return;
    }
    %orig;
}

- (void)updateCPU {
    %orig;
    lp_forcePushControllerParams(self);
}

- (void)updateGPU {
    %orig;
}

- (void)updatePackage {
    %orig;
}

- (void)setPackageLowPowerTarget {
    if (g_restoringPower) { %orig; return; }
    %orig;
}

- (void)calculateMitigation {
    if (g_restoringPower) { %orig; return; }
    if (shouldApplyLowPowerLimit()) { return; }
    %orig;
}

- (void)computePowerTarget {
    if (g_restoringPower) { %orig; return; }
    if (shouldApplyLowPowerLimit()) { return; }
    %orig;
}

- (void)updatePowerTarget {
    if (g_restoringPower) { %orig; return; }
    if (shouldApplyLowPowerLimit()) { return; }
    %orig;
}

- (void)setCPMSMitigationState:(int)state {
    if (g_restoringPower) { %orig(state); return; }
    if (shouldApplyLowPowerLimit()) { %orig(0); return; }
    %orig;
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (g_restoringPower) { %orig(enabled); return; }
    if (shouldApplyLowPowerLimit()) { %orig(NO); return; }
    %orig;
}

- (BOOL)shouldSuppressMitigations {
    if (shouldApplyLowPowerLimit()) return YES;
    return %orig;
}

%end

// ============================================================================
// %hook: ThermalControl — 省电状态（来自 CPU (1) 验证有效的实现）
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

- (BOOL)powerSaveActive {
    if (g_restoringPower) return %orig;
    if (shouldApplyLowPowerLimit()) return YES;
    return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (g_restoringPower) { %orig(active); return; }
    if (shouldApplyLowPowerLimit()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(id)token {
    if (g_restoringPower) { %orig(token); return; }
    if (shouldApplyLowPowerLimit()) { %orig([NSNumber numberWithInt:1]); return; }
    %orig;
}

- (float)calculateControlEffort:(id)trigger {
    if (g_restoringPower) return %orig(trigger);
    if (shouldApplyLowPowerLimit()) {
        NSLog(@"[LowPower] 阻止 PID 控制力度");
        return 0.0f;
    }
    return %orig(trigger);
}

- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
    if (g_restoringPower) return %orig(trigger, arg2);
    if (shouldApplyLowPowerLimit()) {
        NSLog(@"[LowPower] 阻止 PID 控制力度 (双参数)");
        return 0.0f;
    }
    return %orig(trigger, arg2);
}

- (void)updatePowerParameters:(id)params {
    if (g_restoringPower) { %orig; return; }
    if (shouldApplyLowPowerLimit()) { return; }
    %orig;
}

- (void)actionComponentControl {
    if (g_restoringPower) { %orig; return; }
    if (shouldApplyLowPowerLimit()) { return; }
    %orig;
}

- (void)readReleaseRateForAllComponents {
    if (g_restoringPower) { %orig; return; }
    if (shouldApplyLowPowerLimit()) { return; }
    %orig;
}

%end

// ============================================================================
// %hook: ApplePPMCPU — CPU P-state 限制（来自 CPU (1) 验证有效的实现）
// ============================================================================
%hook ApplePPMCPU
- (void)setCPULevel:(int)level {
    if(shouldApplyLowPowerLimit()){
        level = 1; // 强制固定Level=1，无论系统传入任何数值
    }
    %orig(level);
}

// 新增：拦截读取当前level，防止内部逻辑判断反弹
- (int)currentCPULevel {
    int raw = %orig;
    if(shouldApplyLowPowerLimit()){
        return 1;
    }
    return raw;
}

- (void)updateCPU {
    %orig;
    // update内部会重新协商频率，执行结束再次强制下压
    if(shouldApplyLowPowerLimit()){
        ((void (*)(id, SEL, int))objc_msgSend)(self, @selector(setCPULevel:), 1);
    }
}
%end

// ============================================================================
// %hook: ApplePPMGPU — GPU P-state
// ============================================================================
%hook ApplePPMGPU

- (void)updateGPU {
    %orig;
}

%end

// ============================================================================
// %hook: 低温控制器 — 限制低温降频输出
// ============================================================================
%hook TableDrivenLowTempController

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
    int original = %orig(temperature, soc, ra);
    if (shouldApplyLowPowerLimit()) {
        return MIN(original, lp_lowTargetMHz());
    }
    return original;
}

%end

%hook FormulaDrivenLowTempController

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
    int original = %orig(temperature, soc, ra);
    if (shouldApplyLowPowerLimit()) {
        return MIN(original, lp_lowTargetMHz());
    }
    return original;
}

%end

%hook FormulaDrivenLowTempController_CPU

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
    int original = %orig(temperature, soc, ra);
    if (shouldApplyLowPowerLimit()) {
        return MIN(original, lp_lowTargetMHz());
    }
    return original;
}

%end

%hook FormulaDrivenLowTempController_GPU

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
    int original = %orig(temperature, soc, ra);
    if (shouldApplyLowPowerLimit()) {
        return MIN(original, lp_lowTargetMHz());
    }
    return original;
}

%end

// ============================================================================
// Helper: CommonProduct 查找与同步
// ============================================================================
static CommonProduct *CPUthermalFindCommonProduct(void) {
    Class cpClass = objc_getClass("CommonProduct");
    if (!cpClass) return nil;

    SEL sharedSel = @selector(sharedInstance);
    if ([cpClass respondsToSelector:sharedSel]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
        if (instance) return instance;
    }
    sharedSel = @selector(sharedProduct);
    if ([cpClass respondsToSelector:sharedSel]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
        if (instance) return instance;
    }
    return nil;
}

static void CPUthermalSyncCommonProduct(void) {
    if (g_lp_commonProduct) return;
    CommonProduct *cp = CPUthermalFindCommonProduct();
    if (cp) {
        CPUthermalHelper.shared.commonProductObject = cp;
        g_lp_commonProduct = cp;
        NSLog(@"[CPUthermal] 动态获取 CommonProduct: %@", cp);
    }
}

// ============================================================================
// Helper: 应用当前模式
// ============================================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;
    [helper reloadPrefs];

    CPUthermalSyncCommonProduct();

    if (!helper.commonProductObject) {
        NSLog(@"[CPUthermal] commonProductObject 为空，LowPower 状态机将接管降频");
        return;
    }

    if ([helper.thermalPowerMode isEqualToString:S("lowPower")]) {
        // 不使用系统moderate模拟，完全依靠插件自身锁频
        NSLog(@"[CPUthermal] 模式: 低功耗（插件独立锁频，关闭系统热模拟）");
    } else {
        [helper.commonProductObject putDeviceInThermalSimulationMode:S("nominal")];
        NSLog(@"[CPUthermal] 模式: 解除温控 (nominal)");
    }

    if ([helper.commonProductObject respondsToSelector:@selector(tryTakeAction)]) {
        [helper.commonProductObject tryTakeAction];
    }
    if ([helper.commonProductObject respondsToSelector:@selector(handleMCSThermalPressure)]) {
        [helper.commonProductObject handleMCSThermalPressure];
    }
}

// ============================================================================
// Darwin 通知回调 — puppet event
// ============================================================================
static void puppetEventCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [CPUthermalHelper.shared executePuppetEvent];
}

// ============================================================================
// %hook: CommonProduct — 初始化时注入 Helper 并应用模式
// ============================================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    CPUthermalApplyMode();
    return res;
}

%end

// ============================================================================
// %hook: NSDictionary — 修补温控配置文件（防温控暗屏）
// ============================================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig(path);
    if ([path containsString:S("/System/Library/ThermalMonitor/")]) {
        if ([res isKindOfClass:[NSDictionary class]]) {
            CFDictionaryRef patched = [CPUthermalHelper.shared patchThermalPlist:(__bridge CFDictionaryRef)res];
            return (__bridge id)patched;
        }
    }
    return res;
}

%end

// ============================================================================
// %ctor — 构造函数
// ============================================================================
%ctor {
    @autoreleasepool {

        // ── 第1步：加载低功耗偏好 ──
        lp_loadPrefs();

        // ── 第2步：安装 IOKit IOServiceSetProperty hook ──
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            void *sspPtr = dlsym(iokit, "IOServiceSetProperty");
            if (sspPtr) {
                MSHookFunction(sspPtr, (void *)lp_hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
                NSLog(@"[LowPower] IOServiceSetProperty hook 已安装");
            }
        }

        // ── 第3步：安装 _getConfigurationFor hook（低功耗配置修补） ──
        void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
        if (monitor) {
            void *getConfig = dlsym(monitor, "_getConfigurationFor");
            if (getConfig) {
                MSHookFunction(getConfig, (void *)lp_new_getConfigurationFor, (void **)&orig_getConfigurationFor);
                NSLog(@"[LowPower] _getConfigurationFor hook 已安装");
            }
        }

        // ── 第4步：尝试获取已有的 CommonProduct 实例 ──
        if (!g_lp_commonProduct) {
            Class cpClass = objc_getClass("CommonProduct");
            if (cpClass) {
                SEL sharedSel = @selector(sharedProduct);
                if ([cpClass respondsToSelector:sharedSel]) {
                    id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
                    if (instance) {
                        g_lp_commonProduct = instance;
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

        // ── 第5步：如果当前是低功耗模式，立即应用状态并启动定时器 ──
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
            NSLog(@"[LowPower] 已激活 — 目标频率:%dMHz 保活:%.1fs",
                  lp_lowTargetMHz(), (double)kLPTimerIntervalMs / 1000.0);
        } else {
            NSLog(@"[LowPower] 待命中（可在运行时切换激活）");
        }

        // ── 第6步：注册 Darwin 通知 ──
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

        // 低功耗模式切换
        CFNotificationCenterAddObserver(nc, NULL, lp_onModeChanged,
            CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // Puppet event
        CFNotificationCenterAddObserver(nc, NULL, puppetEventCallback,
            CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 屏幕唤醒事件
        CFNotificationCenterAddObserver(nc, NULL, lp_onWakeEvent,
            CFSTR("com.apple.springboard.hasFinishedUnblankingScreen"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(nc, NULL, lp_onWakeEvent,
            CFSTR("com.apple.springboard.lockstate"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // ── 第7步：注册 notify.h 通知（CFNotification 的互补通道） ──
        int token;
        notify_register_dispatch(kCPUthermalReloadNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            lp_onModeChanged(NULL, NULL, NULL, NULL, NULL);
        });

    } // @autoreleasepool
}
