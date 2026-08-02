#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <limits.h>
#import <stdint.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
// 原生 Hot-In-Pocket (口袋过热) 保护：本插件启动时强制关闭，
// 通过 SCPreferences 写入 OSThermalStatus.plist 的 hipOverride/hipPersistentlyEnabled/simulateHip = NO
// 注: iOS SDK 将 SCPreferences* 标记为 unavailable，使用自定义声明头（移植自 Battman scprefs.h）
#include <CPUthermalSCPrefs.h>

// ============================================================================
// ObjC 类声明（thermalmonitord 内部类，class-dump 获取）
// ============================================================================
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setThermalState:(id)state;
@end

// ============================================================================
@interface ThermalManager : NSObject
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
- (void)evaluateDecisionTree;
- (id)findComponent:(id)component;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (float)getReleaseRateForComponent:(id)component;
- (int)getPotentialForcedThermalLevel:(id)component;
- (int)getPotentialForcedThermalPressureLevel;
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force;
- (void)updateThermalNotification:(id)notification;
- (BOOL)shouldEnforceLightThermalPressure;
- (void)setCPMSMitigationState:(int)state;
@end

@interface ThermalControl : NSObject
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2;
- (id)findCC:(id)component;
- (float)dieTempFilteredMaxAverage;
- (float)getHighestSkinTemp;
- (float)thermalSensorValuesMaxFromIndexSet:(id)indexSet;
- (void)copyDieTempSensorIndexSetForFourthChar:(char)c sensors:(id)sensors;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
- (void)updatePowerParameters:(id)params;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface MitigationController : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
- (void)setCPULowPowerTarget:(int)target;
- (void)setPackageLowPowerTarget;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
@end

@interface ThermalDecisionTable : NSObject
- (id)initDecisionTable:(id)table;
@end

@interface PIDController : NSObject
- (id)initPIDWith:(id)params;
@end

@interface HotspotController : NSObject
- (id)initWithParams:(id)params aggdController:(id)aggd;
@end

@interface CommonAggdController : NSObject
- (id)initWithParams:(id)params product:(id)product;
@end

// ============================================================================
// 配置
// ============================================================================
static BOOL g_enabled               = YES; // 总开关 — 强制开启（面板已无开关入口，避免用户误操作导致温控失效）
static BOOL g_cpuProtection         = YES; // CPU 温控保护 — 始终启用，无需用户开关

// 屏蔽网络射频温控节流：所有模式都拦截Wi‑Fi/基带热限流指令
static BOOL g_blockNetworkThermalThrottle = YES;

// Wi‑Fi Apple80211 射频限流关键字 iOS15~iOS16通用
static const char *networkThrottleKeys[] = {
    "txPowerLimit",
    "transmitPowerLimit",
    "maxThroughput",
    "rateLimiting",
    "thermalThrottleEnabled",
    "antennaThrottle",
    "thermalPowerCap",
    "radioPowerLimit",
    "modemThermalLimit",
    "basebandPowerLimit",
    NULL
};

// 判断是否为网络射频限流属性key
static BOOL isNetworkThrottleProperty(CFStringRef keyRef) {
    if (!keyRef || !g_enabled || !g_blockNetworkThermalThrottle) return NO;
    NSString *key = (__bridge NSString *)keyRef;
    NSString *lowerKey = [key lowercaseString];

    for (int i = 0; networkThrottleKeys[i]; i++) {
        NSString *k = [NSString stringWithUTF8String:networkThrottleKeys[i]];
        if ([lowerKey containsString:[k lowercaseString]]) {
            return YES;
        }
    }
    return NO;
}

typedef enum {
CPUthermalPowerModeFull = 0,
CPUthermalPowerModeLow  = 1
} CPUthermalPowerMode;

static CPUthermalPowerMode g_powerMode = CPUthermalPowerModeFull;

// 低功耗模式 CPU 频率锁定值（MHz）
static const int64_t kLowPowerMinFrequencyMHz = 1380;
static const int64_t kLowPowerMaxFrequencyMHz = 1428;

// 【完善.x 关键常量】低功耗目标
// 频点下发：setCPULowPowerTarget/setMaxCPUPowerTarget/setCPUPowerCeiling
// 直接下发 1428MHz（kLowPowerMaxFrequencyMHz）；百分比/功耗上限保留给
// setCPUPowerZoneTarget 与主动下发逻辑使用。
static const int kLowPowerPercentTarget = 40;
static const int kLowPowerPowerCeiling  = 35;

// 温度安全阀 — 超过此值不拦截任何保护
static const int64_t kSafetyTempThreshold = 100000;  // 100°C (毫摄氏度)

static CommonProduct *g_commonProduct = nil;
static NSMutableArray *g_mitigationControllers = nil;
static BOOL g_restoringFullPower = NO;
static BOOL g_applyingLowPower = NO;
static NSMutableDictionary *g_originalControllerValues = nil;
static CFAbsoluteTime g_processStartTime = 0;
static const double kFullPowerBootGuardDuration = 3.0;
static BOOL g_deferredRuntimeApplyScheduled = NO;
static BOOL g_fullPowerRecoveryPulseScheduled = NO;
static BOOL g_lowPowerApplyPulseScheduled = NO;
static BOOL g_wakeRuntimeApplyScheduled = NO;
static dispatch_source_t g_keepAliveTimer = NULL;  // 低功耗锁屏持久化 Keep-Alive 定时器

// 温度计警告 & 防暗屏（由设置面板控制）
static BOOL g_thermalBlockNotifPopup = YES;
static BOOL g_thermalPreventDimmingEnabled = YES;

static BOOL shouldApplyLowPowerLimit(void);
static int lowPowerTargetValue(void);
static int lowPowerPercentTargetValue(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(BOOL respectBootGuard);
static void scheduleDeferredRuntimeApply(double delay);
static void scheduleLowPowerApplyPulse(void);
static void runLowPowerApplyPulse(int remainingPulses);
static void scheduleFullPowerRecoveryPulse(void);
static void runFullPowerRecoveryPulse(int remainingPulses);
static void scheduleWakeRuntimeApply(void);
static void runWakeRuntimeApplyPulse(int remainingPulses);

static NSString *controllerKey(id controller, const char *name) {
return [NSString stringWithFormat:S("%p:%s"), controller, name];
}

static void rememberOriginalIntValue(id controller, const char *name, int value) {
if (!controller || g_restoringFullPower || g_applyingLowPower || !shouldApplyLowPowerLimit()) return;
if (value <= lowPowerTargetValue()) return;
if (!g_originalControllerValues) g_originalControllerValues = [NSMutableDictionary dictionary];
NSString *key = controllerKey(controller, name);
if (!key || [g_originalControllerValues objectForKey:key]) return;
[g_originalControllerValues setObject:[NSNumber numberWithInt:value] forKey:key];
}

static int rememberedOriginalIntValue(id controller, const char *name, int fallback) {
NSNumber *value = [g_originalControllerValues objectForKey:controllerKey(controller, name)];
return value ? [value intValue] : fallback;
}

static BOOL isLowPowerMode(void) {
return g_powerMode == CPUthermalPowerModeLow;
}

static BOOL isFullPowerMode(void) {
return g_powerMode == CPUthermalPowerModeFull;
}

static BOOL fullPowerBootGuardActive(void) {
if (!isFullPowerMode()) return NO;
if (g_processStartTime <= 0) return NO;
return (CFAbsoluteTimeGetCurrent() - g_processStartTime) < kFullPowerBootGuardDuration;
}

static BOOL shouldApplyFullCPUProtection(void) {
return g_enabled && g_cpuProtection && isFullPowerMode() && !fullPowerBootGuardActive();
}

static BOOL shouldApplyLowPowerLimit(void) {
return g_enabled && g_cpuProtection && isLowPowerMode();
}

static int lowPowerTargetValue(void) {
return (int)kLowPowerMaxFrequencyMHz;
}

// 低功耗下的百分比目标 (0 - 100) — 传给 MitigationController 等 ObjC 控制器的值应为
// 百分比/Level，而非 MHz 频点。40% 对应大约 1.4GHz - 2.0GHz 频率。
static int lowPowerPercentTargetValue(void) {
return kLowPowerPercentTarget; // 完善.x: 40
}

static int lowPowerPowerCeilingValue(void) {
return kLowPowerPowerCeiling; // 完善.x: 35
}

static int lowPowerPowerFloorValue(void) {
return 0;
}

static int fullPowerTargetValue(void) {
return 100;
}

static int fullPowerFrequencyValue(void) {
return INT_MAX;
}

static int fullPowerPercentValue(void) {
return 100;
}

static CFStringRef cpuMaxPowerPropertyName(void) {
static CFStringRef propertyName = NULL;
static dispatch_once_t once;
dispatch_once(&once, ^{
propertyName = CFStringCreateWithCString(kCFAllocatorDefault, "CPUMaxPower", kCFStringEncodingUTF8);
});
return propertyName;
}

static BOOL methodEncodingContains(id object, SEL selector, const char *needle) {
if (!object || !selector || !needle) return NO;
Method method = class_getInstanceMethod(object_getClass(object), selector);
if (!method) return NO;
const char *types = method_getTypeEncoding(method);
return types && strstr(types, needle) != NULL;
}

static BOOL methodArgumentTypeIsObject(id object, SEL selector, unsigned int index) {
if (!object || !selector) return NO;
Method method = class_getInstanceMethod(object_getClass(object), selector);
if (!method) return NO;
char type[32] = {0};
method_getArgumentType(method, index, type, sizeof(type));
return type[0] == '@';
}

static void sendSetPowerSaveToken(id controller, int token) {
if (!controller || ![controller respondsToSelector:@selector(setPowerSaveToken:)]) return;
if (methodArgumentTypeIsObject(controller, @selector(setPowerSaveToken:), 2)) {
id tokenObject = token ? [NSNumber numberWithInt:token] : nil;
((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setPowerSaveToken:), tokenObject);
return;
}
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), token);
}

static void trackPowerController(id controller) {
if (!controller) return;
if (!g_mitigationControllers) g_mitigationControllers = [NSMutableArray array];
if (![g_mitigationControllers containsObject:controller]) {
[g_mitigationControllers addObject:controller];
}
}

static BOOL setMaxCPUPowerTargetUsesCFString(id controller) {
return methodEncodingContains(controller, @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:), "^{__CFString=}");
}

static uintptr_t setMaxCPUPowerPropertyArgument(id controller) {
return setMaxCPUPowerTargetUsesCFString(controller)
? (uintptr_t)cpuMaxPowerPropertyName()
: (uintptr_t)YES;
}

static uintptr_t normalizedSetMaxCPUPowerPropertyArgument(id controller, uintptr_t property) {
if (setMaxCPUPowerTargetUsesCFString(controller) && property < 4096) {
return (uintptr_t)cpuMaxPowerPropertyName();
}
return property;
}

static void sendSetMaxCPUPowerTarget(id controller, int target, BOOL legacy) {
if (!controller || ![controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) return;
((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:),
target, legacy, setMaxCPUPowerPropertyArgument(controller));
}

static int intIvarValue(id object, const char *name, int fallback) {
if (!object || !name) return fallback;
Class cls = object_getClass(object);
while (cls) {
Ivar ivar = class_getInstanceVariable(cls, name);
if (ivar) {
ptrdiff_t offset = ivar_getOffset(ivar);
uint8_t *bytes = (uint8_t *)(__bridge void *)object;
return *(int *)(bytes + offset);
}
cls = class_getSuperclass(cls);
}
return fallback;
}

static int fullPowerTargetForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "MaxCPUPowerTarget", 0);
if (remembered > lowPowerTargetValue()) return remembered;

int maxPower = intIvarValue(controller, "_maxCPUPower", 0);
if (maxPower > lowPowerTargetValue()) return maxPower;

int realTarget = intIvarValue(controller, "_currentRealCPUPowerTarget", 0);
if (realTarget > lowPowerTargetValue()) return realTarget;

return fullPowerFrequencyValue();
}

static int fullPowerCeilingForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "CPUPowerCeiling", fullPowerTargetValue());
return remembered > lowPowerTargetValue() ? remembered : fullPowerTargetValue();
}

static int fullPowerFloorForController(id controller) {
return rememberedOriginalIntValue(controller, "CPUPowerFloor", 0);
}

static int fullPowerZoneTargetForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "CPUPowerZoneTarget", 0);
if (remembered > lowPowerTargetValue()) return remembered;
return fullPowerTargetForController(controller);
}

static void applyLowPowerLimitToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
@try {
g_applyingLowPower = YES;
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 1);
}
if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
// 【关键修改】传入百分比 (40)，而非 MHz (1428)
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), lowPowerPercentTargetValue());
}
if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxCPUPowerTarget(controller, lowPowerPercentTargetValue(), NO);
}
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue(), 0);
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), lowPowerPercentTargetValue());
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
NSLog(@"[CPUthermal] 已主动下发低功耗 CPU 限制 (Target: %d%% PowerCeiling: %d) controller:%@", lowPowerPercentTargetValue(), lowPowerPowerCeilingValue(), controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 下发低功耗 CPU 限制失败: %@", exception);
} @finally {
g_applyingLowPower = NO;
}
}

static void applyLowPowerLimitsToTrackedControllers(void) {
if (!shouldApplyLowPowerLimit()) return;
@autoreleasepool {
NSArray *controllers = [g_mitigationControllers copy];
for (id controller in controllers) {
applyLowPowerLimitToController(controller);
}
}
}

static void restoreFullPowerToController(id controller) {
if (!controller || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
g_restoringFullPower = YES;
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 0);
}
if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), fullPowerPercentValue());
}
if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxCPUPowerTarget(controller, fullPowerTargetForController(controller), NO);
}
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), fullPowerCeilingForController(controller), 0);
}
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setCPUPowerFloor:fromDecisionSource:), fullPowerFloorForController(controller), 0);
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), fullPowerZoneTargetForController(controller));
}
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
NSLog(@"[CPUthermal] 已主动恢复解除温控 CPU 上限 controller:%@", controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 恢复解除温控 CPU 上限失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void restoreFullPowerToTrackedControllers(void) {
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@autoreleasepool {
NSArray *controllers = [g_mitigationControllers copy];
for (id controller in controllers) {
restoreFullPowerToController(controller);
}
[g_originalControllerValues removeAllObjects];
}
}

static void setCommonProductCeiling(SEL selector, int ceiling) {
if (!g_commonProduct || ![g_commonProduct respondsToSelector:selector]) return;
((void (*)(id, SEL, int, id))objc_msgSend)(g_commonProduct, selector, ceiling, S("CPUthermal"));
}

static void applyFullPowerToCommonProduct(void) {
if (!g_commonProduct || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
g_restoringFullPower = YES;
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), 0);
}
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), 0);
setCommonProductCeiling(@selector(setGPUPowerCeiling:fromDecisionSource:), 0);
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), 0);
if ([g_commonProduct respondsToSelector:@selector(setThermalState:)]) {
((void (*)(id, SEL, id))objc_msgSend)(g_commonProduct, @selector(setThermalState:), [NSNumber numberWithInt:0]);
}
// 强制系统热压力为 Nominal 并重置热通知级别
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 已主动套用解除温控 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用解除温控 CommonProduct 状态失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void applyLowPowerToCommonProduct(void) {
if (!g_commonProduct || !shouldApplyLowPowerLimit()) return;
@try {
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), YES);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), 1);
}
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue());
setCommonProductCeiling(@selector(setGPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue());
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue());
NSLog(@"[CPUthermal] 已主动套用低功耗 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用低功耗 CommonProduct 状态失败: %@", exception);
}
}

// --- 低功耗锁屏持久化 Keep-Alive 定时器 ---
// 锁屏时 GCD 的 dispatch_after 经常失效，改用带 DISPATCH_TIMER_STRICT 的后台循环定时器，
// 低功耗激活时每 2 秒硬性重新刷写一次低功耗配置，保证锁屏状态下温控策略不被系统重置。
static void startLowPowerKeepAliveTimer(void) {
    if (g_keepAliveTimer) return;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    g_keepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, queue);
    if (g_keepAliveTimer) {
        // 每 2 秒强制重新刷写一次低功耗配置，即使在锁屏低功耗状态下
        dispatch_source_set_timer(g_keepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 2.0 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_keepAliveTimer, ^{
            if (g_enabled && g_cpuProtection && isLowPowerMode()) {
                applyLowPowerToCommonProduct();
                applyLowPowerLimitsToTrackedControllers();
            }
        });
        dispatch_resume(g_keepAliveTimer);
        NSLog(@"[CPUthermal] 低功耗锁屏持久化 Keep-Alive 定时器已启动");
    }
}

static void stopLowPowerKeepAliveTimer(void) {
    if (g_keepAliveTimer) {
        dispatch_source_cancel(g_keepAliveTimer);
        g_keepAliveTimer = NULL;
        NSLog(@"[CPUthermal] Keep-Alive 定时器已停止");
    }
}

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime(YES);
}

static void applyPowerModeToRuntime(BOOL respectBootGuard) {
if (!g_enabled || !g_cpuProtection) return;
if (isLowPowerMode()) {
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
scheduleLowPowerApplyPulse();
startLowPowerKeepAliveTimer(); // 开启持续守护
return;
}
if (isFullPowerMode()) {
stopLowPowerKeepAliveTimer(); // 恢复性能模式时关闭守护
if (respectBootGuard && fullPowerBootGuardActive()) {
double elapsed = CFAbsoluteTimeGetCurrent() - g_processStartTime;
double remaining = kFullPowerBootGuardDuration - elapsed;
scheduleDeferredRuntimeApply(MAX(remaining, 0.1) + 0.1);
return;
}
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
scheduleFullPowerRecoveryPulse();
}
}

static void scheduleDeferredRuntimeApply(double delay) {
if (g_deferredRuntimeApplyScheduled) return;
g_deferredRuntimeApplyScheduled = YES;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
g_deferredRuntimeApplyScheduled = NO;
applyCurrentPowerModeToRuntime();
});
}

static void scheduleLowPowerApplyPulse(void) {
if (g_lowPowerApplyPulseScheduled || !g_enabled || !g_cpuProtection || !isLowPowerMode()) return;
g_lowPowerApplyPulseScheduled = YES;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runLowPowerApplyPulse(8);
});
}

static void runLowPowerApplyPulse(int remainingPulses) {
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection || !isLowPowerMode()) {
g_lowPowerApplyPulseScheduled = NO;
return;
}
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
if (remainingPulses <= 1) {
g_lowPowerApplyPulseScheduled = NO;
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runLowPowerApplyPulse(remainingPulses - 1);
});
}

static void scheduleFullPowerRecoveryPulse(void) {
if (g_fullPowerRecoveryPulseScheduled || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
g_fullPowerRecoveryPulseScheduled = YES;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runFullPowerRecoveryPulse(4);
});
}

static void runFullPowerRecoveryPulse(int remainingPulses) {
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection || !isFullPowerMode()) {
g_fullPowerRecoveryPulseScheduled = NO;
return;
}
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
if (remainingPulses <= 1) {
g_fullPowerRecoveryPulseScheduled = NO;
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runFullPowerRecoveryPulse(remainingPulses - 1);
});
}

static void scheduleWakeRuntimeApply(void) {
if (g_wakeRuntimeApplyScheduled || !g_enabled || !g_cpuProtection) return;
g_wakeRuntimeApplyScheduled = YES;
dispatch_async(dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(8);
});
}

static void runWakeRuntimeApplyPulse(int remainingPulses) {
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection) {
g_wakeRuntimeApplyScheduled = NO;
return;
}
loadPrefs();
applyPowerModeToRuntime(NO);
if (remainingPulses <= 1) {
g_wakeRuntimeApplyScheduled = NO;
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(remainingPulses - 1);
});
}

static BOOL keyMatchesLowPowerLimit(NSString *key) {
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
return (isCPUKey && isFrequencyKey) || isLowPowerTargetKey || isMaxCPUPowerTargetKey || isPowerZoneTargetKey;
}

static int64_t frequencyMHzFromValue(int64_t value) {
if (value >= 1000000000LL) return value / 1000000LL;
if (value >= 1000000LL) return value / 1000LL;
return value;
}

static int64_t frequencyValueFromMHz(int64_t mhz, int64_t originalValue) {
if (originalValue >= 1000000000LL) return mhz * 1000000LL;
if (originalValue >= 1000000LL) return mhz * 1000LL;
return mhz;
}

static int64_t clampLowPowerFrequencyValue(int64_t value) {
int64_t mhz = frequencyMHzFromValue(value);
if (mhz < kLowPowerMinFrequencyMHz) mhz = kLowPowerMinFrequencyMHz;
if (mhz > kLowPowerMaxFrequencyMHz) mhz = kLowPowerMaxFrequencyMHz;
return frequencyValueFromMHz(mhz, value);
}

static CFTypeRef copyLowPowerFrequencyValueForKey(NSString *key, CFTypeRef originalValue) {
if (!keyMatchesLowPowerLimit(key)) return NULL;
NSString *lower = [key lowercaseString];
BOOL isMinKey = [key localizedCaseInsensitiveContainsString:S("min")] ||
[key localizedCaseInsensitiveContainsString:S("floor")];
BOOL isFrequencyKey = [lower containsString:S("freq")] ||
[lower containsString:S("frequency")];

int64_t original = kLowPowerMaxFrequencyMHz;
if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
} else if (isMinKey && isFrequencyKey) {
original = kLowPowerMinFrequencyMHz;
}

int64_t replacement = isMinKey && isFrequencyKey
? frequencyValueFromMHz(kLowPowerMinFrequencyMHz, original)
: clampLowPowerFrequencyValue(original);
return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacement);
}

static NSNumber *lowPowerNumberForKey(NSString *key, NSNumber *originalNumber) {
if (!keyMatchesLowPowerLimit(key)) return nil;
NSString *lower = [key lowercaseString];
BOOL isMinKey = [key localizedCaseInsensitiveContainsString:S("min")] ||
[key localizedCaseInsensitiveContainsString:S("floor")];
BOOL isFrequencyKey = [lower containsString:S("freq")] ||
[lower containsString:S("frequency")];

int64_t original = originalNumber ? [originalNumber longLongValue] : kLowPowerMaxFrequencyMHz;
int64_t replacement = (isMinKey && isFrequencyKey)
? frequencyValueFromMHz(kLowPowerMinFrequencyMHz, original)
: clampLowPowerFrequencyValue(original);
return [NSNumber numberWithLongLong:replacement];
}

static id patchedLowPowerConfigObject(id object, NSString *keyHint) {
if ([object isKindOfClass:[NSNumber class]]) {
NSNumber *patched = lowPowerNumberForKey(keyHint, (NSNumber *)object);
return patched ?: object;
}

if ([object isKindOfClass:[NSArray class]]) {
NSArray *array = (NSArray *)object;
NSMutableArray *patchedArray = [NSMutableArray arrayWithCapacity:array.count];
for (id item in array) {
[patchedArray addObject:patchedLowPowerConfigObject(item, keyHint) ?: item];
}
return patchedArray;
}

if ([object isKindOfClass:[NSDictionary class]]) {
NSMutableDictionary *patchedDict = [(NSDictionary *)object mutableCopy];
[(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
NSString *childKey = [key isKindOfClass:[NSString class]] ? (NSString *)key : keyHint;
if (keyHint && childKey) {
childKey = [NSString stringWithFormat:S("%@.%@"), keyHint, childKey];
}
id patchedValue = patchedLowPowerConfigObject(value, childKey);
if (patchedValue) patchedDict[key] = patchedValue;
}];
return patchedDict;
}

return object;
}

static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

// ============================================================================
// 强制关闭原生 Hot-In-Pocket (口袋过热) 保护
// 向 thermalmonitord 监听的 OSThermalStatus.plist 写入 hipOverride=NO /
// hipPersistentlyEnabled=NO / simulateHip=NO，彻底禁用系统原生口袋过热保护。
// ============================================================================
static void forceDisableNativeHIP(void) {
    SCPreferencesRef prefs = SCPreferencesCreate(kCFAllocatorDefault,
        (__bridge CFStringRef)S("OSThermalStatus"),
        (__bridge CFStringRef)S("OSThermalStatus.plist"));
    if (!prefs) {
        NSLog(@"[CPUthermal] HIP: 无法打开 OSThermalStatus.plist");
        return;
    }
    SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("hipOverride"), kCFBooleanFalse);
    SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("hipPersistentlyEnabled"), kCFBooleanFalse);
    SCPreferencesSetValue(prefs, (__bridge CFStringRef)S("simulateHip"), kCFBooleanFalse);
    Boolean ok = SCPreferencesCommitChanges(prefs);
    if (ok) {
        (void)SCPreferencesApplyChanges(prefs);
    } else {
        NSLog(@"[CPUthermal] HIP: SCPreferencesCommitChanges 失败: %s", SCErrorString(SCError()));
    }
    CFRelease(prefs);
    NSLog(@"[CPUthermal] 已强制关闭原生口袋过热保护 (HIP)");
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
if (!d) return;
// g_enabled 强制开启（硬编码），不读取面板偏好 — 面板已无总开关，避免用户误操作关闭温控
g_enabled = YES;
// g_cpuProtection 始终为 YES（硬编码），不依赖偏好设置
g_thermalBlockNotifPopup     = [d[S("thermalBlockNotifPopup")] ?: [NSNumber numberWithBool:YES] boolValue];
g_thermalPreventDimmingEnabled = [d[S("thermalPreventDimmingEnabled")] ?: [NSNumber numberWithBool:YES] boolValue];

NSString *mode = d[S("powerMode")] ?: S("fullPower");
g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
}
}

// ============================================================================
// 热管理 IOKit 服务名
// ============================================================================
static const char *g_hotServices[] = {
"AppleSPU", "AppleSPU.original",
"AppleARMPlatform",
"pmu", "ApplePMGR",
NULL
};

#define SELECTOR_IS_MITIGATION(s)  (((s) >= 0x40 && (s) <= 0x5F) || (s) == 0x30 || (s) == 0x31)
#define SELECTOR_IS_CRITICAL(s)    ((s) >= 0x60 && (s) <= 0x6F)  // 紧急保护 — 不拦截

// ============================================================================
// connection 追踪
// ============================================================================
#define MAX_CONN 64

typedef struct {
io_connect_t conn;
BOOL         isThermal;
} ConnEntry;

static ConnEntry g_conns[MAX_CONN];
static int g_connCount = 0;

static void trackConnection(io_connect_t conn, BOOL thermal) {
if (g_connCount >= MAX_CONN) return;
g_conns[g_connCount].conn     = conn;
g_conns[g_connCount].isThermal = thermal;
g_connCount++;
}

static BOOL isThermalConnection(io_connect_t conn) {
for (int i = 0; i < g_connCount; i++) {
if (g_conns[i].conn == conn) return g_conns[i].isThermal;
}
return NO;
}

static BOOL serviceIsThermal(io_service_t service) {
io_name_t name;
if (IORegistryEntryGetName(service, name) != KERN_SUCCESS) return NO;
for (int i = 0; g_hotServices[i]; i++) {
if (strcmp(name, g_hotServices[i]) == 0) return YES;
}
return NO;
}

// ============================================================================
// 温度安全阀检查
// ============================================================================
// thermalmonitord 内部判定"高温"的阈值通常在 45°C-65°C 之间
// 我们设置 100°C 作为硬性安全阀 — 超过此温度不拦截任何保护动作
// 这样即使插件出 bug 导致温度失控，硬件仍能获得保护
static BOOL isTemperatureAboveSafetyCeiling(void) {
// 通过 IOKit 读取实际温度 — 跳过拦截
// 如果读不到，保守返回 NO（不过度保护）
CFMutableDictionaryRef matching = IOServiceMatching("AppleARMPlatform");
if (!matching) return NO;

io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
if (!service) return NO;

CFTypeRef temp = IORegistryEntryCreateCFProperty(service, CFSTR("temperature"), kCFAllocatorDefault, 0);
IOObjectRelease(service);

if (!temp) return NO;

int64_t tempVal = 0;
if (CFNumberGetValue((CFNumberRef)temp, kCFNumberSInt64Type, &tempVal)) {
CFRelease(temp);
return tempVal >= kSafetyTempThreshold;
}

CFRelease(temp);
return NO;
}

// ============================================================================
// IOKit 层钩子
// ============================================================================

// --- IOServiceOpen — 追踪 thermal connection ---
%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_t task, uint32_t type, io_connect_t *connect) {
kern_return_t ret = %orig;
if (ret == KERN_SUCCESS) {
trackConnection(*connect, serviceIsThermal(service));
}
return ret;
}

// --- IOConnectCallMethod — 拦截温度读取 + 降频操作 ---
%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
if (!g_enabled || !isThermalConnection(connection)) {
return %orig;
}

if (g_restoringFullPower) {
return %orig;
}

// 紧急保护 — 任何情况都不拦截 (安全阀)
if (SELECTOR_IS_CRITICAL(selector)) {
return %orig;
}

// 超过 100°C 时放行所有保护（安全阀生效）
if (isTemperatureAboveSafetyCeiling()) {
return %orig;
}

if (shouldApplyFullCPUProtection() && SELECTOR_IS_MITIGATION(selector)) {
// 注意: 不拦截 0x60-0x6F 紧急保护
return KERN_SUCCESS;
}
return %orig;
}

// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

// ===================== 拦截Wi‑Fi/蜂窝基带射频温控限流 =====================
// 所有模式都拦截Wi‑Fi/基带热限流指令（移植自 温控pro）
if (isNetworkThrottleProperty(key)) {
NSLog(@"[CPUthermal] 已屏蔽网络射频热节流指令: %@", (__bridge NSString *)key);
return KERN_SUCCESS; // 直接丢弃指令，不写入驱动，取消限流
}
// ==========================================================================

// 安全阀: 超过阈值不拦截
if (isTemperatureAboveSafetyCeiling()) {
return orig_IOServiceSetProperty(service, key, value);
}

NSString *ks = (__bridge NSString *)key;
if (g_cpuProtection) {
if (g_restoringFullPower) {
return orig_IOServiceSetProperty(service, key, value);
}
static NSArray *cpuKeys;
static dispatch_once_t once;
dispatch_once(&once, ^{
// 用 C 字符串创建数组，避免 __cfstring
cpuKeys = @[S("cpu"), S("CPU"), S("freq"), S("Freq"), S("frequency"), S("performance"), S("throttle"), S("mitigation"), S("speed"), S("limit")];
});
for (NSString *k in cpuKeys) {
if ([ks containsString:k]) {
if (isFullPowerMode()) return KERN_SUCCESS;
if (shouldApplyLowPowerLimit()) {
CFTypeRef replacement = copyLowPowerFrequencyValueForKey(ks, value);
if (replacement) {
kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
CFRelease(replacement);
return ret;
}
}
break;
}
}
}
return orig_IOServiceSetProperty(service, key, value);
}

// --- IOPMSetAggressiveness — 防止低功耗/锁屏切换时系统重置 CPU 频率策略 ---
// 注: 1.x 方案文档引用的 kIOPMAggressivenessCPU/kIOPMAggressivenessPerformance 在 SDK 中不存在，
//     实际对应的是 IOPM.h 中的 kPMSetProcessorSpeed(处理器频率) / kPMPowerSource(电源来源) 类型。
static kern_return_t (*orig_IOPMSetAggressiveness)(io_connect_t, unsigned long, unsigned long) = NULL;

static kern_return_t hooked_IOPMSetAggressiveness(io_connect_t fb, unsigned long type, unsigned long newLevel) {
    if (g_enabled && g_cpuProtection && isLowPowerMode()) {
        // 低功耗模式下锁定 CPU/电源相关策略为低功耗 Level，
        // 阻止 thermalmonitord 或 PowerD 在锁屏/低功耗切换时重置 CPU 频率策略
        if (type == kPMSetProcessorSpeed || type == kPMPowerSource) {
            return orig_IOPMSetAggressiveness(fb, type, 1);
        }
    }
    return orig_IOPMSetAggressiveness(fb, type, newLevel);
}

// --- IORegistryEntryCreateCFProperty — 不再篡改值 ---
%hookf(CFTypeRef, IORegistryEntryCreateCFProperty, io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
return %orig;
}

// --- notify_post — 拦截高温广播 (保留 hook 作日志/调试用途) ---
%hookf(uint32_t, notify_post, const char *name) {
return %orig;
}

// ============================================================================
// ObjC 类钩子（第1层: CommonProduct / HidSensors — 已有）
// ============================================================================

// --- CommonProduct: thermalmonitord 核心热管理对象 ---
%hook CommonProduct

- (id)initProduct:(id)arg1 {
id res = %orig;
if (g_enabled) {
g_commonProduct = self;
[self putDeviceInThermalSimulationMode:S("nominal")];
applyCurrentPowerModeToRuntime();
NSLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal, 功率模式:%@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
return res;
}

- (void)tryTakeAction {
if (shouldApplyFullCPUProtection()) {
// 阻止所有热缓解动作
return;
}
%orig;
}

- (void)simulateLightThermalPressure {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)updatePowerzoneTelemetry {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层 — 新增自 1.dylib 分析）
//
// 冲突避免说明:
//   - 传感器读数 getHighestSkinTemp/dieTempFilteredMaxAverage/thermalSensorValuesMaxFromIndexSet
//     不在此处 hook (IOKit 层已拦截)
//   - putDeviceInThermalSimulationMode: 不 hook (CPUthermal 自已调用会递归)
//   - setCPMSMitigationState: 不 hook (IOKit 层已拦截 selector 0x40-0x5F)
//   - setHiPFeatureEnabled/setPackageLowPowerTarget: 不 hook (IOKit 层已拦截)
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
if (shouldApplyFullCPUProtection()) {
// 安全阀: 超过 100°C 不阻断
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
return;
}
}
%orig;
}

// 热压力升级通知 — 不再主动阻断
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
%orig;
}

// 热通知 — 受 thermalBlockNotifPopup 开关控制
- (void)updateThermalNotification:(id)notification {
	@autoreleasepool {
		if (g_thermalBlockNotifPopup) {
			NSLog(@"[CPUthermal] 屏蔽高温温度计警告: %@", notification);
			return;
		}
	}
%orig;
}

// 是否应执行轻度热压力 — 不拦截
- (BOOL)shouldEnforceLightThermalPressure {
return %orig;
}

// 获取组件释放速率 — 可以降低不放 0
- (float)getReleaseRateForComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
if (!isTemperatureAboveSafetyCeiling()) {
float rate = %orig(component);
// 软化: 降低 50% 但保留基础释放能力
if (rate > 0.5) {
rate = rate * 0.5;
}
NSLog(@"[CPUthermal] 软化释放速率: %@ -> %.2f", component, rate);
return rate;
}
}
return %orig(component);
}

// 获取强制热级别 — 不篡改
- (int)getPotentialForcedThermalLevel:(id)component {
return %orig(component);
}

// 获取强制热压力级别 — 不篡改
- (int)getPotentialForcedThermalPressureLevel {
return %orig;
}

// 散热/电池服务建议 — 不拦截
- (id)getBatteryServiceSuggestion:(id)suggestion {
return %orig(suggestion);
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
applyCurrentPowerModeToRuntime();
}
return res;
}

- (id)initWithParams:(id)params {
id res = %orig(params);
if (res) {
trackPowerController(res);
applyCurrentPowerModeToRuntime();
}
return res;
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) {
return %orig;
}
if (shouldApplyLowPowerLimit()) {
return YES;
}
if (shouldApplyFullCPUProtection()) {
return NO;
}
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
if (g_restoringFullPower) {
%orig(active);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(YES);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return;
}
%orig;
}

- (void)setPowerSaveToken:(id)token {
if (g_restoringFullPower) {
%orig(token);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig([NSNumber numberWithInt:1]);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(nil);
return;
}
%orig;
}

// 计算控制力度 — 这是 throttle 量的核心
// soften 模式下减半但不归零，保留基础调节能力
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
if (shouldApplyFullCPUProtection()) {
if (!isTemperatureAboveSafetyCeiling()) {
float effort = %orig(trigger, arg2);
float newEffort = effort * 0.5;  // 减半，不归零
if (newEffort < 0 && effort > 0) newEffort = 0;  // 保护负值
NSLog(@"[CPUthermal] 软化控制力度: %.2f -> %.2f", effort, newEffort);
return newEffort;
}
}
return %orig(trigger, arg2);
}

// actionComponentControl — 组件控制动作
- (void)actionComponentControl {
if (shouldApplyFullCPUProtection()) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止 actionComponentControl");
return;
}
}
%orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection()) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止 readReleaseRateForAllComponents");
return;
}
}
%orig;
}


%end

// --- ApplePPMCPU: 低功耗时限制 CPU P-state 档位 ---
%hook ApplePPMCPU

- (void)setCPULevel:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
// 完善.x: 低功耗模式下强行限制在低性能/低 P-State 档位，锁频最有效手法
%orig(2);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0); // 解除温控：锁定最高性能档位 0
return;
}
%orig;
}

- (void)updateCPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

%end

// --- MitigationController: 功率目标控制 ---
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
applyCurrentPowerModeToRuntime();
}
return res;
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) {
return %orig;
}
if (shouldApplyLowPowerLimit()) {
return YES;
}
if (shouldApplyFullCPUProtection()) {
return NO;
}
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
if (g_restoringFullPower) {
%orig(active);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(YES);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return;
}
%orig;
}

- (void)setPowerSaveToken:(int)token {
if (g_restoringFullPower) {
%orig(token);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(1);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig;
}

- (void)updateCPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)updateGPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)updatePackage {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)setCPULowPowerTarget:(int)target {
    // 完善.x: 低功耗模式同步下发具体频点上限 (1428MHz)
    if (isLowPowerMode()) {
        %orig((int)kLowPowerMaxFrequencyMHz); // 1428MHz
        return;
    }
    %orig;
}

- (void)setPackageLowPowerTarget {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    // 完善.x: 低功耗模式同步下发具体频点上限 (1428MHz)；保留 property 归一化避免 CFString 崩溃
    uintptr_t propertyArg = normalizedSetMaxCPUPowerPropertyArgument(self, property);
    if (isLowPowerMode()) {
        %orig((int)kLowPowerMaxFrequencyMHz, legacy, propertyArg);
        return;
    }
    %orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyLowPowerLimit()) {
rememberOriginalIntValue(self, "CPUPowerCeiling", ceiling);
// 完善.x: 低功耗模式下强制设置绝对 Power Ceiling 频点 (1428MHz)
%orig((int)kLowPowerMaxFrequencyMHz, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerCeilingForController(self), source);
return;
}
%orig;
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(floor, source);
return;
}
if (shouldApplyLowPowerLimit()) {
rememberOriginalIntValue(self, "CPUPowerFloor", floor);
%orig(lowPowerPowerFloorValue(), source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerFloorForController(self), source);
return;
}
%orig;
}

- (void)setCPUPowerZoneTarget:(int)target {
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyLowPowerLimit()) {
rememberOriginalIntValue(self, "CPUPowerZoneTarget", target);
%orig(lowPowerPercentTargetValue()); // 修改为百分比
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerZoneTargetForController(self));
return;
}
%orig;
}

%end

// ============================================================================
// 防温控暗屏 — 修补热配置 plist 中的背光参数
// 由 thermalPreventDimmingEnabled 开关控制
// ============================================================================

// 补丁热配置字典：阻止系统因温控调暗屏幕
static NSDictionary *patchThermalPlist(NSDictionary *dict) {
	if (!g_thermalPreventDimmingEnabled) return dict;

	NSMutableDictionary *mutableDict = [dict mutableCopy];

	// Patch backlight component control
	NSDictionary *backlight = mutableDict[S("backlightComponentControl")];
	if ([backlight isKindOfClass:[NSDictionary class]]) {
		NSMutableDictionary *mutableBacklight = [backlight mutableCopy];

		// Fix BacklightBrightness — 所有条目设为第一个值
		NSArray *brightnessArr = mutableBacklight[S("BacklightBrightness")];
		if ([brightnessArr isKindOfClass:[NSArray class]] && brightnessArr.count > 1) {
			NSMutableArray *newBrightness = [brightnessArr mutableCopy];
			id firstVal = newBrightness[0];
			for (NSUInteger i = 1; i < newBrightness.count; i++) {
				newBrightness[i] = firstVal;
			}
			mutableBacklight[S("BacklightBrightness")] = newBrightness;
		}

		// Fix BacklightPower — 所有条目设为第一个值
		NSArray *powerArr = mutableBacklight[S("BacklightPower")];
		if ([powerArr isKindOfClass:[NSArray class]] && powerArr.count > 1) {
			NSMutableArray *newPower = [powerArr mutableCopy];
			id firstVal = newPower[0];
			for (NSUInteger i = 1; i < newPower.count; i++) {
				newPower[i] = firstVal;
			}
			mutableBacklight[S("BacklightPower")] = newPower;
		}

		mutableBacklight[S("expectsCPMSSupport")] = @(0);
		mutableBacklight[S("maxThermalPower")] = @(0);
		mutableBacklight[S("minThermalPower")] = @(0);

		mutableDict[S("backlightComponentControl")] = mutableBacklight;

		NSLog(@"[CPUthermal] 已修补热配置: 防温控暗屏已启用");
	}

	return mutableDict;
}

// ============================================================================
// %hook: NSDictionary — 拦截热配置 plist 加载，应用防暗屏补丁
// ============================================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
	id res = %orig(path);
	if (g_thermalPreventDimmingEnabled && [path containsString:S("/System/Library/ThermalMonitor/")]) {
		if ([res isKindOfClass:[NSDictionary class]]) {
			NSDictionary *patched = patchThermalPlist(res);
			return patched;
		}
	}
	return res;
}

%end

// ============================================================================
// C 函数钩子: _getConfigurationFor → ___New_getConfigurationFor___
//
// 在 thermalmonitord 初始化时，会调用 _getConfigurationFor(NSString*)
// 来获取热配置字典。通过返回修改后的配置，可以影响所有热管理参数。
// ============================================================================

// 原函数类型: NSDictionary* _getConfigurationFor(NSString *key)
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

static NSDictionary* new_getConfigurationFor(NSString *key) {
NSDictionary *config = orig_getConfigurationFor(key);
if (!g_enabled || !g_cpuProtection || !config) return config;

// 安全阀
if (isTemperatureAboveSafetyCeiling()) return config;

@autoreleasepool {
NSMutableDictionary *modified = [config mutableCopy];
if (!modified) return config;

if (isLowPowerMode()) {
NSDictionary *patched = patchedLowPowerConfigObject(modified, key);
NSMutableDictionary *lowPowerConfig = [patched mutableCopy];
NSMutableDictionary *powerSaveParams = [[lowPowerConfig objectForKey:S("powerSaveParams")] mutableCopy];
if (powerSaveParams) {
[powerSaveParams setObject:[NSNumber numberWithInt:lowPowerTargetValue()] forKey:S("PackageLowPowerTarget")];
[powerSaveParams setObject:[NSNumber numberWithInt:lowPowerTargetValue()] forKey:S("CPULowPowerTarget")];
[lowPowerConfig setObject:powerSaveParams forKey:S("powerSaveParams")];
}
NSLog(@"[CPUthermal] 已应用低功耗配置: %@ target:%d (%lld-%lldMHz)", key, lowPowerTargetValue(), kLowPowerMinFrequencyMHz, kLowPowerMaxFrequencyMHz);
return [lowPowerConfig copy];
}

// 修改系统热配置
// 增大所有热等级的触发阈值（延迟触发）
static NSArray *tempThresholdKeys;
static dispatch_once_t once;
dispatch_once(&once, ^{
// 用 C 字符串创建数组，避免 __cfstring
tempThresholdKeys = @[
S("thermalThresholds"),
S("dieTemperatureThresholds"),
S("skinTemperatureThresholds"),
S("componentTemperatureThresholds"),
S("hotTemperatureThresholds")
];
});

for (NSString *tk in tempThresholdKeys) {
id thresholds = modified[tk];
if ([thresholds isKindOfClass:[NSArray class]]) {
NSMutableArray *newThresholds = [NSMutableArray array];
for (NSNumber *val in (NSArray *)thresholds) {
// 将每个阈值提高 5°C (5000 毫摄氏度)
int64_t raised = [val longLongValue] + 5000;
[newThresholds addObject:@(raised)];
}
modified[tk] = newThresholds;
} else if ([thresholds isKindOfClass:[NSDictionary class]]) {
NSMutableDictionary *newDict = [NSMutableDictionary dictionary];
[(NSDictionary *)thresholds enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
if ([v isKindOfClass:[NSNumber class]]) {
int64_t raised = [v longLongValue] + 5000;
newDict[k] = @(raised);
} else {
newDict[k] = v;
}
}];
modified[tk] = newDict;
}
}

NSLog(@"[CPUthermal] 已修改热配置表: %@", key);
return [modified copy];
}
}


// ============================================================================
// Puppet 事件（由 Preferences 面板触发 — 模拟热级别切换）
// ============================================================================
static void executePuppetEvent(void) {
if (!g_commonProduct) return;
@autoreleasepool {
NSDictionary *prefs = readPrefsDictionary();
NSString *level = prefs[S("thermalPuppetValue")] ?: S("nominal");
[g_commonProduct putDeviceInThermalSimulationMode:level];
NSLog(@"[CPUthermal] Puppet 事件: 热模式设为 %@", level);
}
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
executePuppetEvent();
}

static void onPowerModeChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
applyPowerModeToRuntime(NO);
NSLog(@"[CPUthermal] 功率模式已切换: %@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
applyPowerModeToRuntime(NO);
}
NSLog(@"[CPUthermal] 设置已重载 enabled:%d CPU:%d 弹窗:%d 防暗屏:%d",
g_enabled, g_cpuProtection, g_thermalBlockNotifPopup, g_thermalPreventDimmingEnabled);
}

static void onWakeRuntimeEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
scheduleWakeRuntimeApply();
}
NSLog(S("[CPUthermal] 收到唤醒/亮屏事件，准备恢复当前功率模式"));
}

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
g_processStartTime = CFAbsoluteTimeGetCurrent();
loadPrefs();
// 强制关闭系统原生口袋过热保护 (HIP)
forceDisableNativeHIP();

// 确保 IOKit 已加载
void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
if (iokit) {
kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) = (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))dlsym(iokit, "IOServiceSetProperty");
if (ptr) {
MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
NSLog(@"[CPUthermal] IOServiceSetProperty hook 已安装");
} else {
NSLog(@"[CPUthermal] 警告: 未找到 IOServiceSetProperty");
}

// IOPMSetAggressiveness hook — 防止低功耗/锁屏切换时重置 CPU 频率策略
void *iopmPtr = dlsym(iokit, "IOPMSetAggressiveness");
if (iopmPtr) {
MSHookFunction(iopmPtr, (void *)hooked_IOPMSetAggressiveness, (void **)&orig_IOPMSetAggressiveness);
NSLog(@"[CPUthermal] IOPMSetAggressiveness hook 已安装");
} else {
NSLog(@"[CPUthermal] 警告: 未找到 IOPMSetAggressiveness (非致命)");
}
}

// _getConfigurationFor — C 函数钩子
void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
if (monitor) {
void *getConfig = dlsym(monitor, "_getConfigurationFor");
if (getConfig) {
MSHookFunction(getConfig, (void *)new_getConfigurationFor, (void **)&orig_getConfigurationFor);
NSLog(@"[CPUthermal] _getConfigurationFor hook 已安装");
} else {
NSLog(@"[CPUthermal] 未找到 _getConfigurationFor (非致命)");
}
} else {
NSLog(@"[CPUthermal] 未找到 DeviceMonitor.framework (非致命)");
}

// 强制系统热压力为 Nominal 并重置热通知级别
CPUthermalForceNominalCombined();

NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU性能:%d",
(int)(kSafetyTempThreshold / 1000),
g_cpuProtection);

// 注意: 配置仅在进程启动时加载一次
// 修改设置后需重启 thermalmonitord 才生效

// 模拟热级别监听（独立功能，不影响配置重载）
CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
if (c) {
	CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
	(__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
	(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onPowerModeChanged,
	(__bridge CFStringRef)S(kCPUthermalPowerModeChangedNotifC),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.springboard.hasFinishedUnblankingScreen"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.springboard.lockstate"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.iokit.hid.displayStatus"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.system.awake"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	// 补充锁屏/睡眠深度监听（1.x 方案第 3 项）
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.powermanagement.thermal"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.springboard.clocksystem.sleep"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
	(__bridge CFStringRef)S("com.apple.springboard.hasBlankedScreen"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
}
