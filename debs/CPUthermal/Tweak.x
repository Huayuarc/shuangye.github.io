#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <stdint.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <signal.h>
#include <unistd.h>
#include <CPUthermalPaths.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <os/lock.h>
#import <mach/host_info.h>
#import <mach/task_info.h>

#ifdef CPUTHERMAL_STRIP_LOGS
#define NSLog(...) do {} while (0)
#endif


// ============================================================================
// ObjC 类声明（thermalmonitord 内部类，class-dump 获取）
// ============================================================================
@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2;
@end

@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(id)source;
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
- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(int)contributor;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (int)CPULevel;
- (void)setCPULevel:(int)level;
- (void)setCPUMitigationLevel:(int)level;
- (void)setDVD1Level:(int)level;
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
static BOOL g_enabled               = YES; // 总开关，可由设置动态关闭
static BOOL g_cpuProtection         = YES; // 仅用于低功耗模式控制

// 解除温控模式拦截网络射频热限流；低功耗与禁用状态下保持系统原生行为。
static BOOL g_blockNetworkThermalThrottle = YES;
static BOOL networkThrottleBlockingEnabled(void);

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
if (!keyRef || !networkThrottleBlockingEnabled()) return NO;
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
static CPUthermalPowerMode g_userSelectedPowerMode = CPUthermalPowerModeFull;

// setCPULowPowerTarget:/setMaxCPUPowerTarget: 使用 mW；65000 是 thermalmonitord 的无限制哨兵值。
// setCPULevel:/setCPUPowerCeiling:/setCPUPowerFloor:/setCPUPowerZoneTarget: 使用 0~100 百分比。
static const int kUnrestrictedPowerLimitMW = 65000;
static const int kUnrestrictedPerformancePercent = 100;
static const int kLowPowerCPULevel = 2;
static const int kFullPowerCPULevel = 0;
static const int kCPUDecisionSourceCount = 6;
static const int kCPUDVD1ContributorCount = 4;

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;      // 配置与 CommonProduct
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_runtimeLock = OS_UNFAIR_LOCK_INIT;    // 有限模式应用任务
static __thread BOOL g_restoringFullPower = NO;
static BOOL g_fullPowerRecoveryPulseScheduled = NO;
static BOOL g_lowPowerApplyPulseScheduled = NO;
static dispatch_source_t g_lowPowerRescheduleTimer = NULL;
static BOOL g_thermalReloadScheduled = NO;
static BOOL g_forceThermalConfigReload = NO;
static int g_lockStateToken = -1;
static int g_blankedScreenToken = -1;
static os_unfair_lock g_nominalLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime g_lastNominalCorrection = 0;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护g_powerMode
static NSHashTable *g_applePPMInstances = nil;           // 追踪 ApplePPMCPU 实例（弱引用，防止僵尸实例泄漏）
// 高温告警默认屏蔽；防暗屏仍由用户设置决定。
static BOOL g_thermalBlockNotifPopup = NO;
static BOOL g_thermalPreventDimmingEnabled = NO;
static BOOL g_highPerformanceModeEnabled = NO;
static NSNumber *g_maxBacklightBrightnessValue = nil;
static BOOL isFullPowerMode(void);
static BOOL shouldApplyLowPowerLimit(void);
static int targetCPUPerformanceLevel(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(BOOL respectBootGuard);
static void scheduleFullPowerRecoveryPulse(void);
static void runFullPowerRecoveryPulse(int remainingPulses);
static void scheduleLowPowerApplyPulse(void);
static void stopLowPowerRescheduleTimer(void);
static void startLowPowerRescheduleTimer(void);
static void runLowPowerApplyPulse(int remainingPulses);
static void applyCurrentModeToApplePPMCPU(void);
static void forceCPUPerformanceLevelOnController(id controller);
static void applyFullPowerBudgetsOnController(id controller);
static void applyLowPowerToCommonProduct(void);
static void applyLowPowerPerformancePreferenceToController(id controller);
static void restoreNativeRuntimeAfterDisable(void);
static void correctNominalStateIfNeeded(void);
static void scheduleThermalMonitorReload(void);
static void scheduleThermalConfigurationReload(void);
static void switchToLowPowerForSleep(const char *source);
static void restoreUserModeAfterWake(const char *source);
static void registerScreenWakeObservers(void);

static void runtimeConfigSnapshot(BOOL *enabled, BOOL *cpuProtection, BOOL *blockNetwork, BOOL *blockPopup, BOOL *preventDimming) {
os_unfair_lock_lock(&g_stateLock);
if (enabled) *enabled = g_enabled;
if (cpuProtection) *cpuProtection = g_cpuProtection;
if (blockNetwork) *blockNetwork = g_blockNetworkThermalThrottle;
if (blockPopup) *blockPopup = g_thermalBlockNotifPopup;
if (preventDimming) *preventDimming = g_thermalPreventDimmingEnabled;
os_unfair_lock_unlock(&g_stateLock);
}

static BOOL runtimeEnabled(void) {
BOOL enabled = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL, NULL);
return enabled;
}

static BOOL runtimeProtectionEnabled(void) {
BOOL enabled = NO;
BOOL cpuProtection = NO;
runtimeConfigSnapshot(&enabled, &cpuProtection, NULL, NULL, NULL);
return enabled && cpuProtection;
}

static BOOL networkThrottleBlockingEnabled(void) {
BOOL enabled = NO;
BOOL blockNetwork = NO;
runtimeConfigSnapshot(&enabled, NULL, &blockNetwork, NULL, NULL);
return enabled && blockNetwork && isFullPowerMode() && g_highPerformanceModeEnabled;
}

static BOOL thermalPopupBlockingEnabled(void) {
BOOL enabled = NO;
BOOL blockPopup = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, &blockPopup, NULL);
return enabled && blockPopup;
}

static BOOL thermalDimmingPreventionEnabled(void) {
BOOL enabled = NO;
BOOL preventDimming = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL, &preventDimming);
return enabled && preventDimming;
}

static CommonProduct *commonProductSnapshot(void) {
os_unfair_lock_lock(&g_stateLock);
CommonProduct *product = g_commonProduct;
os_unfair_lock_unlock(&g_stateLock);
return product;
}

static void setCommonProduct(CommonProduct *product) {
CommonProduct *previousProduct = nil;
os_unfair_lock_lock(&g_stateLock);
previousProduct = g_commonProduct;
g_commonProduct = product;
os_unfair_lock_unlock(&g_stateLock);
(void)previousProduct;
}

static BOOL CPUthermalScreenIsBlanked(void) {
int token = 0;
uint64_t state = 0;
if (notify_register_check("com.apple.springboard.hasBlankedScreen", &token) != NOTIFY_STATUS_OK) return NO;
int result = notify_get_state(token, &state);
notify_cancel(token);
return result == NOTIFY_STATUS_OK && state != 0;
}

static BOOL isLowPowerMode(void) {
os_unfair_lock_lock(&g_modeLock);
BOOL res = (g_powerMode == CPUthermalPowerModeLow);
os_unfair_lock_unlock(&g_modeLock);
return res;
}

static BOOL isFullPowerMode(void) {
os_unfair_lock_lock(&g_modeLock);
BOOL res = (g_powerMode == CPUthermalPowerModeFull);
os_unfair_lock_unlock(&g_modeLock);
return res;
}

static BOOL shouldApplyFullCPUProtection(void) {
return runtimeProtectionEnabled() && isFullPowerMode();
}

static BOOL shouldApplyHighPerformanceMode(void) {
return shouldApplyFullCPUProtection() && g_highPerformanceModeEnabled;
}

static BOOL shouldRestoreNativePerformance(void) {
return shouldApplyFullCPUProtection();
}

static BOOL shouldApplyLowPowerLimit(void) {
return runtimeProtectionEnabled() && isLowPowerMode();
}

static void correctNominalStateIfNeeded(void) {
if (!shouldApplyFullCPUProtection()) return;
CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
os_unfair_lock_lock(&g_nominalLock);
BOOL shouldCorrect = (now - g_lastNominalCorrection) >= 1.0;
if (shouldCorrect) g_lastNominalCorrection = now;
os_unfair_lock_unlock(&g_nominalLock);
if (shouldCorrect) CPUthermalForceNominalCombined();
}

static void scheduleThermalMonitorReload(void) {
os_unfair_lock_lock(&g_runtimeLock);
if (g_thermalReloadScheduled) {
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
g_thermalReloadScheduled = YES;
os_unfair_lock_unlock(&g_runtimeLock);

// 给偏好写盘、Darwin 通知和当前事务留出完成时间，再仅重建 thermalmonitord。
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
os_unfair_lock_lock(&g_runtimeLock);
BOOL forceReload = g_forceThermalConfigReload;
g_forceThermalConfigReload = NO;
g_thermalReloadScheduled = NO;
os_unfair_lock_unlock(&g_runtimeLock);
if (!forceReload && !shouldApplyFullCPUProtection()) return;
NSLog(@"[CPUthermal] 重载 thermalmonitord：%@", forceReload ? S("重新加载 ThermalMonitor 配置") : S("清除 CPMS/ApplePPM 缓存"));
kill(getpid(), SIGTERM);
});
}

static void scheduleThermalConfigurationReload(void) {
os_unfair_lock_lock(&g_runtimeLock);
g_forceThermalConfigReload = YES;
os_unfair_lock_unlock(&g_runtimeLock);
scheduleThermalMonitorReload();
}

static void switchToLowPowerForSleep(const char *source) {
BOOL changed = NO;
os_unfair_lock_lock(&g_modeLock);
if (g_powerMode != CPUthermalPowerModeLow) {
g_powerMode = CPUthermalPowerModeLow;
changed = YES;
}
os_unfair_lock_unlock(&g_modeLock);
if (changed) applyPowerModeToRuntime(NO);
NSLog(@"[CPUthermal] %s 状态临时进入低功耗，保留用户模式:%@", source ?: "sleep",
      g_userSelectedPowerMode == CPUthermalPowerModeLow ? S("低功耗") : S("解除温控"));
}

static void restoreUserModeAfterWake(const char *source) {
CPUthermalPowerMode previous;
CPUthermalPowerMode target;
os_unfair_lock_lock(&g_modeLock);
previous = g_powerMode;
target = g_userSelectedPowerMode;
g_powerMode = target;
os_unfair_lock_unlock(&g_modeLock);
// 唤醒时无论枚举是否变化都重新应用：长时间锁屏后 PMGR/ApplePPM
// 可能已经重建，界面模式不变不代表硬件 Level/Floor 仍然有效。
applyPowerModeToRuntime(NO);
if (previous == CPUthermalPowerModeLow && target == CPUthermalPowerModeFull) {
    scheduleThermalMonitorReload();
} else if (target == CPUthermalPowerModeLow && source && strcmp(source, "unlock") == 0) {
    // 只在真实解锁时重建；通知临时亮屏不重启 thermalmonitord。
    // 长时间锁屏后 PMGR/ApplePPM 可能重建，旧对象 setter 已失效。
    scheduleThermalConfigurationReload();
}
NSLog(@"[CPUthermal] %s 状态恢复用户模式:%@", source ?: "wake",
      target == CPUthermalPowerModeLow ? S("低功耗") : S("解除温控"));
}

static void handleLockStateToken(int token) {
uint64_t state = UINT64_MAX;
if (token <= 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return;
if (state == 0) restoreUserModeAfterWake("unlock");
}

static void handleBlankedScreenToken(int token) {
uint64_t state = UINT64_MAX;
if (token <= 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return;
if (state == 0) restoreUserModeAfterWake("screen-on");
else switchToLowPowerForSleep("screen-off");
}

static void registerScreenWakeObservers(void) {
if (g_lockStateToken < 0) {
notify_register_dispatch("com.apple.springboard.lockstate", &g_lockStateToken, dispatch_get_main_queue(), ^(int token) {
handleLockStateToken(token);
});
}
if (g_blankedScreenToken < 0) {
notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &g_blankedScreenToken, dispatch_get_main_queue(), ^(int token) {
handleBlankedScreenToken(token);
});
}
// 初始屏幕状态已由 loadPrefs() 的 CPUthermalScreenIsBlanked() 同步；
// 这里不把进程初次启动误判为真实唤醒，避免低功耗重载循环。
}

static int targetCPUPerformanceLevel(void) {
return isLowPowerMode() ? kLowPowerCPULevel : kFullPowerCPULevel;
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

static char methodArgumentTypeCode(id object, SEL selector, unsigned int index) {
if (!object || !selector) return '\0';
Method method = class_getInstanceMethod(object_getClass(object), selector);
if (!method || index >= method_getNumberOfArguments(method)) return '\0';
char type[32] = {0};
method_getArgumentType(method, index, type, sizeof(type));
const char *cursor = type;
while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
return *cursor;
}

static BOOL argumentTypeIs32BitInteger(char type) {
return type == 'c' || type == 'C' || type == 's' || type == 'S' ||
type == 'i' || type == 'I' || type == 'B';
}

static BOOL argumentTypeIs64BitInteger(char type) {
return type == 'q' || type == 'Q' || type == 'l' || type == 'L' || type == '^';
}

static void sendTwoIntegerArguments(id object, SEL selector, intptr_t firstValue, uintptr_t secondValue) {
if (!object || !selector || ![object respondsToSelector:selector]) return;
char firstType = methodArgumentTypeCode(object, selector, 2);
char secondType = methodArgumentTypeCode(object, selector, 3);
if (argumentTypeIs32BitInteger(firstType) && argumentTypeIs32BitInteger(secondType)) {
((void (*)(id, SEL, int, int))objc_msgSend)(object, selector, (int)firstValue, (int)secondValue);
return;
}
if (argumentTypeIs32BitInteger(firstType) && argumentTypeIs64BitInteger(secondType)) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(object, selector, (int)firstValue, secondValue);
return;
}
if (argumentTypeIs64BitInteger(firstType) && argumentTypeIs32BitInteger(secondType)) {
((void (*)(id, SEL, intptr_t, int))objc_msgSend)(object, selector, firstValue, (int)secondValue);
return;
}
if (argumentTypeIs64BitInteger(firstType) && argumentTypeIs64BitInteger(secondType)) {
((void (*)(id, SEL, intptr_t, uintptr_t))objc_msgSend)(object, selector, firstValue, secondValue);
}
}

static void sendSetPowerSaveToken(id controller, int token) {
if (!controller || ![controller respondsToSelector:@selector(setPowerSaveToken:)]) return;
char argumentType = methodArgumentTypeCode(controller, @selector(setPowerSaveToken:), 2);
if (argumentType == '@') {
id tokenObject = token ? [NSNumber numberWithInt:token] : nil;
((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setPowerSaveToken:), tokenObject);
return;
}
if (argumentTypeIs64BitInteger(argumentType)) {
((void (*)(id, SEL, intptr_t))objc_msgSend)(controller, @selector(setPowerSaveToken:), (intptr_t)token);
return;
}
if (argumentTypeIs32BitInteger(argumentType)) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), token);
}

}

static void trackPowerController(id controller) {
if (!controller) return;
os_unfair_lock_lock(&g_controllerLock);
if (!g_mitigationControllers) g_mitigationControllers = [NSHashTable weakObjectsHashTable];
[g_mitigationControllers addObject:controller];
os_unfair_lock_unlock(&g_controllerLock);
}

static NSArray *trackedPowerControllersSnapshot(void) {
os_unfair_lock_lock(&g_controllerLock);
NSArray *controllers = g_mitigationControllers ? [g_mitigationControllers allObjects] : [NSArray array];
os_unfair_lock_unlock(&g_controllerLock);
return controllers;
}

static void trackApplePPMInstance(id instance) {
if (!instance) return;
os_unfair_lock_lock(&g_controllerLock);
if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
[g_applePPMInstances addObject:instance];
os_unfair_lock_unlock(&g_controllerLock);
}

static NSArray *trackedApplePPMInstancesSnapshot(void) {
os_unfair_lock_lock(&g_controllerLock);
NSArray *instances = g_applePPMInstances ? [g_applePPMInstances allObjects] : [NSArray array];
os_unfair_lock_unlock(&g_controllerLock);
return instances;
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

static void reassertLowPowerStateWithoutUpdate(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
trackPowerController(controller);
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
for (int source = 0; source < kCPUDecisionSourceCount; source++)
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)])
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, (uintptr_t)source);
forceCPUPerformanceLevelOnController(controller);
}

// 低功耗实现移植自 ../lock-low-frequency-extract.m。
static void applyLowPowerPerformancePreferenceToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
trackPowerController(controller);
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
}
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
}
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, (uintptr_t)source);
}
}
for (int source = 0; source < kCPUDecisionSourceCount; source++)
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)])
if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
}
forceCPUPerformanceLevelOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
}
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
}
forceCPUPerformanceLevelOnController(controller);
}

// 解除温控模式统一恢复 CPU level 与 DVD1 level。
static void forceCPUPerformanceLevelOnController(id controller) {
if (!controller || !runtimeProtectionEnabled()) return;
int targetLevel = targetCPUPerformanceLevel();

if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), targetLevel);
}
if ([controller respondsToSelector:@selector(setDVD1Level:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setDVD1Level:), targetLevel);
}
}

// 解除温控模式恢复全部 CPU 功率预算。
static void applyFullPowerBudgetsOnController(id controller) {
if (!controller || !runtimeProtectionEnabled()) return;
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 0);
}
if ([controller respondsToSelector:@selector(setCPUMitigationLevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUMitigationLevel:), 0);
}
if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), kUnrestrictedPowerLimitMW);
}
if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxCPUPowerTarget(controller, kUnrestrictedPowerLimitMW, NO);
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), kUnrestrictedPerformancePercent);
}
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
sendTwoIntegerArguments(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent, (uintptr_t)source);
}
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), shouldApplyHighPerformanceMode() ? kUnrestrictedPerformancePercent : 0, (uintptr_t)source);
}
}
for (int contributor = 0; contributor < kCPUDVD1ContributorCount; contributor++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)]) {
sendTwoIntegerArguments(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), kUnrestrictedPerformancePercent, (uintptr_t)contributor);
}
}
forceCPUPerformanceLevelOnController(controller);
}

static void applyLowPowerLimitsToTrackedControllers(void) {
if (!shouldApplyLowPowerLimit()) return;
@autoreleasepool {
NSArray *controllers = trackedPowerControllersSnapshot();
for (id controller in controllers) {
applyLowPowerPerformancePreferenceToController(controller);
}
}
}

static void restoreFullPowerToController(id controller) {
if (!controller || !shouldApplyFullCPUProtection()) return;
@try {
g_restoringFullPower = YES;
applyFullPowerBudgetsOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updateGPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateGPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
// 原生 update 可能按残留低功耗缓存回写 Level 2；刷新后再次覆盖最终状态。
applyFullPowerBudgetsOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
applyFullPowerBudgetsOnController(controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 恢复解除温控 CPU 上限失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void restoreFullPowerToTrackedControllers(void) {
if (!shouldApplyFullCPUProtection()) return;
@autoreleasepool {
NSArray *controllers = trackedPowerControllersSnapshot();
for (id controller in controllers) {
restoreFullPowerToController(controller);
}
}
}

static void restoreNativeRuntimeAfterDisable(void) {
@autoreleasepool {
@try {
g_restoringFullPower = YES;
for (id controller in trackedPowerControllersSnapshot()) {
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
}
sendSetPowerSaveToken(controller, 0);
if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kFullPowerCPULevel);
}
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
}
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 禁用时恢复原生状态失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}
}

static void setCommonProductCeiling(CommonProduct *product, SEL selector, int ceiling) {
if (!product || !selector || ![product respondsToSelector:selector]) return;
((void (*)(id, SEL, int, id))objc_msgSend)(product, selector, ceiling, S("CPUthermal"));
}

static void applyLowPowerToCommonProduct(void) {
if (!shouldApplyLowPowerLimit()) return;
CommonProduct *product = commonProductSnapshot();
if (!product) return;
@try {
if ([product respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(product, @selector(setCPMSMitigationsEnabled:), YES);
}
if ([product respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(product, @selector(setCPULevel:), kLowPowerCPULevel);
}
setCommonProductCeiling(product, @selector(setCPUPowerFloor:fromDecisionSource:), 0);
if ([product respondsToSelector:@selector(tryTakeAction)]) {
((void (*)(id, SEL))objc_msgSend)(product, @selector(tryTakeAction));
}
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 即时套用低功耗 CommonProduct 状态失败: %@", exception);
}
}

static void applyFullPowerToCommonProduct(void) {
if (!shouldApplyFullCPUProtection()) return;
CommonProduct *product = commonProductSnapshot();
if (!product) return;
BOOL previousRestoring = g_restoringFullPower;
@try {
g_restoringFullPower = YES;
if ([product respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(product, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([product respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(product, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
setCommonProductCeiling(product, @selector(setCPUPowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent);
setCommonProductCeiling(product, @selector(setCPUPowerFloor:fromDecisionSource:), shouldApplyHighPerformanceMode() ? kUnrestrictedPerformancePercent : 0);
if (shouldApplyHighPerformanceMode()) {
setCommonProductCeiling(product, @selector(setGPUPowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent);
setCommonProductCeiling(product, @selector(setPackagePowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent);
}
if ([product respondsToSelector:@selector(setThermalState:)]) {
((void (*)(id, SEL, id))objc_msgSend)(product, @selector(setThermalState:), [NSNumber numberWithInt:0]);
}
CPUthermalForceNominalCombined();
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用解除温控 CommonProduct 状态失败: %@", exception);
} @finally {
g_restoringFullPower = previousRestoring;
}
}

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime(YES);
}

static void applyPowerModeToRuntime(BOOL respectBootGuard) {
if (!runtimeProtectionEnabled()) return;
(void)respectBootGuard;
if (isLowPowerMode()) {
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleLowPowerApplyPulse();
startLowPowerRescheduleTimer();
return;
}
if (isFullPowerMode()) {
// 切换时有限恢复并伪造 Nominal；持续热决策由 hook 就地拦截，无需周期保活。
CPUthermalForceNominalCombined();
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleFullPowerRecoveryPulse();
stopLowPowerRescheduleTimer();
}
}

static void scheduleFullPowerRecoveryPulse(void) {
if (!shouldRestoreNativePerformance()) return;
os_unfair_lock_lock(&g_runtimeLock);
if (g_fullPowerRecoveryPulseScheduled) {
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
g_fullPowerRecoveryPulseScheduled = YES;
os_unfair_lock_unlock(&g_runtimeLock);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runFullPowerRecoveryPulse(6);
});
}

static void runFullPowerRecoveryPulse(int remainingPulses) {
if (remainingPulses <= 0 || !shouldRestoreNativePerformance()) {
os_unfair_lock_lock(&g_runtimeLock);
g_fullPowerRecoveryPulseScheduled = NO;
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
if (remainingPulses <= 1) {
os_unfair_lock_lock(&g_runtimeLock);
g_fullPowerRecoveryPulseScheduled = NO;
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runFullPowerRecoveryPulse(remainingPulses - 1);
});
}

static void scheduleLowPowerApplyPulse(void) {
if (!shouldApplyLowPowerLimit()) return;
os_unfair_lock_lock(&g_runtimeLock);
if (g_lowPowerApplyPulseScheduled) {
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
g_lowPowerApplyPulseScheduled = YES;
os_unfair_lock_unlock(&g_runtimeLock);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runLowPowerApplyPulse(12);
});
}

static void runLowPowerApplyPulse(int remainingPulses) {
if (remainingPulses <= 0 || !shouldApplyLowPowerLimit()) {
os_unfair_lock_lock(&g_runtimeLock);
g_lowPowerApplyPulseScheduled = NO;
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
if (remainingPulses <= 1) {
os_unfair_lock_lock(&g_runtimeLock);
g_lowPowerApplyPulseScheduled = NO;
os_unfair_lock_unlock(&g_runtimeLock);
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runLowPowerApplyPulse(remainingPulses - 1);
});
}


static void stopLowPowerRescheduleTimer(void) {
os_unfair_lock_lock(&g_runtimeLock);
dispatch_source_t timer = g_lowPowerRescheduleTimer;
g_lowPowerRescheduleTimer = NULL;
if (timer) {
dispatch_source_cancel(timer);
#if !OS_OBJECT_USE_OBJC
dispatch_release(timer);
#endif
}
os_unfair_lock_unlock(&g_runtimeLock);
}

static void startLowPowerRescheduleTimer(void) {
if (!shouldApplyLowPowerLimit()) { stopLowPowerRescheduleTimer(); return; }
os_unfair_lock_lock(&g_runtimeLock);
if (g_lowPowerRescheduleTimer) { os_unfair_lock_unlock(&g_runtimeLock); return; }
dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
if (!timer) { os_unfair_lock_unlock(&g_runtimeLock); return; }
g_lowPowerRescheduleTimer = timer;
dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC),
                          5ull * NSEC_PER_SEC, 500ull * NSEC_PER_MSEC);
dispatch_source_set_event_handler(timer, ^{
if (!shouldApplyLowPowerLimit()) { stopLowPowerRescheduleTimer(); return; }
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
});
dispatch_resume(timer);
os_unfair_lock_unlock(&g_runtimeLock);
}


static void applyCurrentModeToApplePPMCPU(void) {
if (!runtimeProtectionEnabled()) return;
NSArray *instances = trackedApplePPMInstancesSnapshot();
BOOL restoring = isFullPowerMode();
BOOL previousRestoring = g_restoringFullPower;
@try {
if (restoring) g_restoringFullPower = YES;
for (id ppm in instances) {
if (!ppm) continue;
if ([ppm respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
if ([ppm respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(ppm, @selector(updateCPU));
}
// updateCPU 可能重新应用旧 Level；确保最终状态仍为当前模式。
if ([ppm respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
}
} @finally {
if (restoring) g_restoringFullPower = previousRestoring;
}
}

// 解除温控使用事件驱动 hook，不创建周期保活定时器。

static BOOL keyIsBacklightThermalLimit(NSString *key) {
if (!key || key.length == 0) return NO;
NSString *lower = [key lowercaseString];
if ([lower containsString:S("idle")] || [lower containsString:S("autolock")] ||
    [lower containsString:S("sleep")] || [lower containsString:S("blank")] ||
    [lower containsString:S("screenoff")] || [lower containsString:S("screen-off")] ||
    [lower containsString:S("powerstate")] || [lower containsString:S("wake")]) return NO;
BOOL displayContext = [lower containsString:S("backlight")] || [lower containsString:S("display")];
if (!displayContext) return NO;
return [lower containsString:S("brightness")] || [lower containsString:S("luminance")] ||
       [lower containsString:S("nits")];
}

static id maximumBacklightReplacementForKey(NSString *key) {
return g_maxBacklightBrightnessValue;
}

static id backlightReplacementMatchingValue(NSString *key, id originalValue) {
id maximum = maximumBacklightReplacementForKey(key);
if (!maximum) return nil;
if ([originalValue isKindOfClass:[NSString class]]) {
if ([(NSString *)originalValue doubleValue] <= 0.0) return nil;
return [(NSNumber *)maximum stringValue];
}
if ([originalValue isKindOfClass:[NSNumber class]]) {
if ([(NSNumber *)originalValue doubleValue] <= 0.0) return nil;
return maximum;
}
return nil;
}

// 判断是否为 thermalmonitord 发出的约束属性。
// 这里只丢弃用户态温控上限写入，不向内核写固定频点，因此不会锁死原生 DVFS。
static BOOL keyIsThermalThrottleProperty(NSString *key) {
if (!key || key.length == 0) return NO;
NSString *lower = [key lowercaseString];

// 充电与电池热保护必须交由系统处理；高性能模式不拦截充电限流/停充属性。
if ([lower containsString:S("battery")] || [lower containsString:S("charger")] ||
    [lower containsString:S("charging")] || [lower containsString:S("chargecurrent")]) return NO;
if ([lower containsString:S("temperature")] || [lower containsString:S("temp")] ||
    [lower containsString:S("sensor")]) return NO;
BOOL displayLifecycle = [lower containsString:S("display")] || [lower containsString:S("backlight")] || [lower containsString:S("screen")];
if (displayLifecycle && ([lower containsString:S("power")] || [lower containsString:S("state")] ||
    [lower containsString:S("idle")] || [lower containsString:S("lock")] ||
    [lower containsString:S("sleep")] || [lower containsString:S("blank")] ||
    [lower containsString:S("wake")])) return NO;

// Floor/Minimum 属于性能下限而非热降频上限，不能拦截。
if ([lower containsString:S("floor")]) return NO;

// 明确的温控缓解关键词 — 无条件拦截
if ([lower containsString:S("throttle")]) return YES;
if ([lower containsString:S("mitigation")]) return YES;

BOOL mentionsCPU = [lower containsString:S("cpu")] ||
[lower containsString:S("core")] ||
[lower containsString:S("ppm")] ||
[lower containsString:S("processor")];
BOOL mentionsGPU = [lower containsString:S("gpu")];
BOOL mentionsPackage = [lower containsString:S("package")] ||
[lower containsString:S("component")];
BOOL mentionsThermal = [lower containsString:S("thermal")];
BOOL mentionsSoC = [lower containsString:S("soc")] ||
[lower containsString:S("cluster")] ||
[lower containsString:S("pmgr")] ||
[lower containsString:S("clpc")] ||
[lower containsString:S("dvfs")] ||
[lower containsString:S("systempower")] ||
[lower containsString:S("diepower")];
BOOL mentionsFreq = [lower containsString:S("freq")] ||
[lower containsString:S("frequency")];
BOOL mentionsLimit = [lower containsString:S("limit")] ||
[lower containsString:S("cap")] ||
[lower containsString:S("ceiling")] ||
[lower containsString:S("floor")] ||
[lower containsString:S("target")] ||
[lower containsString:S("maximum")] ||
[lower containsString:S("minimum")];
BOOL mentionsSpeed = [lower containsString:S("speed")];
BOOL mentionsPower = [lower containsString:S("power")];
BOOL mentionsState = [lower containsString:S("level")] ||
[lower containsString:S("state")];

BOOL protectedComponent = mentionsCPU || mentionsThermal;
if (shouldApplyHighPerformanceMode()) protectedComponent = protectedComponent || mentionsGPU || mentionsPackage || mentionsSoC;
if (protectedComponent) {
// 普通解除温控保护 CPU；高性能模式额外保护 GPU 与 Package 功率墙。
if (mentionsLimit || mentionsFreq || mentionsSpeed || mentionsPower || mentionsState) {
return YES;
}
}
return NO;
}

static CFDictionaryRef copyPropertiesByRemovingThermalLimits(CFTypeRef properties) {
if (!properties || CFGetTypeID(properties) != CFDictionaryGetTypeID()) return NULL;
NSDictionary *source = (__bridge NSDictionary *)properties;
NSMutableDictionary *filtered = [source mutableCopy];
if (!filtered) return NULL;
BOOL changed = NO;

for (id rawKey in source) {
if (![rawKey isKindOfClass:[NSString class]]) continue;
NSString *key = (NSString *)rawKey;
if (thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(key)) {
id replacement = backlightReplacementMatchingValue(key, [source objectForKey:key]);
if (replacement) [filtered setObject:replacement forKey:key];
changed = YES;
continue;
}
BOOL shouldDrop = isNetworkThrottleProperty((__bridge CFStringRef)key);
if (shouldApplyFullCPUProtection() && keyIsThermalThrottleProperty(key)) {
shouldDrop = YES;
}
if (!shouldDrop) continue;
[filtered removeObjectForKey:key];
changed = YES;
}

return changed ? CFBridgingRetain(filtered) : NULL;
}

// iOS 15~17 热管理私有类存在命名差异；以下别名 Hook 按方法签名动态安装。
static void (*origTDT_Evaluate)(id, SEL) = NULL;
static void (*origTDT_Action)(id, SEL) = NULL;
static void (*origTDT_ReadRelease)(id, SEL) = NULL;
static float (*origTDT_GetRelease)(id, SEL, id) = NULL;
static void (*origComponent_CPMS)(id, SEL, int) = NULL;
static void (*origNotification_Thermal)(id, SEL, id) = NULL;

static void aliasTDT_Evaluate(id self, SEL cmd) {
if (shouldApplyFullCPUProtection()) { correctNominalStateIfNeeded(); return; }
if (origTDT_Evaluate) origTDT_Evaluate(self, cmd);
}
static void aliasTDT_Action(id self, SEL cmd) {
if (shouldApplyFullCPUProtection()) return;
if (origTDT_Action) origTDT_Action(self, cmd);
}
static void aliasTDT_ReadRelease(id self, SEL cmd) {
if (shouldApplyFullCPUProtection()) return;
if (origTDT_ReadRelease) origTDT_ReadRelease(self, cmd);
}
static float aliasTDT_GetRelease(id self, SEL cmd, id component) {
if (shouldApplyFullCPUProtection()) return 0.0f;
return origTDT_GetRelease ? origTDT_GetRelease(self, cmd, component) : 0.0f;
}
static void aliasComponent_CPMS(id self, SEL cmd, int state) {
if (shouldApplyFullCPUProtection()) { if (origComponent_CPMS) origComponent_CPMS(self, cmd, 0); return; }
if (origComponent_CPMS) origComponent_CPMS(self, cmd, state);
}
static void aliasNotification_Thermal(id self, SEL cmd, id notification) {
if (thermalPopupBlockingEnabled()) return;
if (origNotification_Thermal) origNotification_Thermal(self, cmd, notification);
}

static BOOL CPUthermalMethodMatches(Class cls, SEL sel, unsigned int arguments, char returnType) {
Method method = class_getInstanceMethod(cls, sel);
if (!method || method_getNumberOfArguments(method) != arguments) return NO;
char type[16] = {0}; method_getReturnType(method, type, sizeof(type));
const char *cursor = type; while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
return *cursor == returnType;
}

static BOOL CPUthermalMethodArgumentMatches(Class cls, SEL sel, unsigned int index, const char *allowed) {
Method method = class_getInstanceMethod(cls, sel); if (!method || index >= method_getNumberOfArguments(method)) return NO;
char type[16]={0}; method_getArgumentType(method,index,type,sizeof(type)); const char *cursor=type;
while(*cursor&&strchr("rnNoORV",*cursor))cursor++; return *cursor && strchr(allowed,*cursor)!=NULL;
}

static void installCrossVersionThermalAliases(void) {
Class tree = objc_getClass("TableDrivenDecisionTree");
if (tree) {
SEL eval = sel_registerName("evaluateDecisionTree");
SEL action = sel_registerName("actionComponentControl");
SEL read = sel_registerName("readReleaseRateForAllComponents");
SEL release = sel_registerName("getReleaseRateForComponent:");
if (!origTDT_Evaluate && CPUthermalMethodMatches(tree, eval, 2, 'v')) MSHookMessageEx(tree, eval, (IMP)aliasTDT_Evaluate, (IMP *)&origTDT_Evaluate);
if (!origTDT_Action && CPUthermalMethodMatches(tree, action, 2, 'v')) MSHookMessageEx(tree, action, (IMP)aliasTDT_Action, (IMP *)&origTDT_Action);
if (!origTDT_ReadRelease && CPUthermalMethodMatches(tree, read, 2, 'v')) MSHookMessageEx(tree, read, (IMP)aliasTDT_ReadRelease, (IMP *)&origTDT_ReadRelease);
if (!origTDT_GetRelease && CPUthermalMethodMatches(tree, release, 3, 'f') && CPUthermalMethodArgumentMatches(tree, release, 2, "@")) MSHookMessageEx(tree, release, (IMP)aliasTDT_GetRelease, (IMP *)&origTDT_GetRelease);
}
Class component = objc_getClass("ComponentControl");
SEL cpms = sel_registerName("setCPMSMitigationState:");
if (component && !origComponent_CPMS && CPUthermalMethodMatches(component, cpms, 3, 'v') && CPUthermalMethodArgumentMatches(component, cpms, 2, "cCsSiIlLqQB")) MSHookMessageEx(component, cpms, (IMP)aliasComponent_CPMS, (IMP *)&origComponent_CPMS);
Class notification = objc_getClass("NotificationManager");
SEL update = sel_registerName("updateThermalNotification:");
if (notification && !origNotification_Thermal && CPUthermalMethodMatches(notification, update, 3, 'v') && CPUthermalMethodArgumentMatches(notification, update, 2, "@")) MSHookMessageEx(notification, update, (IMP)aliasNotification_Thermal, (IMP *)&origNotification_Thermal);
}

static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
// 关键修复：读取失败时立即返回，保留当前内存中正确的 g_powerMode，防止回退到解除温控
if (!d || d.count == 0) return;

BOOL enabled = YES;
BOOL blockPopup = [d[S("thermalBlockNotifPopup")] ?: @NO boolValue];
BOOL preventDimming = [d[S("thermalPreventDimmingEnabled")] ?: @NO boolValue];
BOOL highPerformanceMode = [d[S("highPerformanceModeEnabled")] ?: @NO boolValue];
g_highPerformanceModeEnabled = highPerformanceMode;
os_unfair_lock_lock(&g_stateLock);
g_enabled = enabled;
g_thermalBlockNotifPopup = blockPopup;
g_thermalPreventDimmingEnabled = preventDimming;
os_unfair_lock_unlock(&g_stateLock);

NSString *mode = d[S("powerMode")];
if (mode && [mode isKindOfClass:[NSString class]]) {
CPUthermalPowerMode selected = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
BOOL blanked = CPUthermalScreenIsBlanked();
os_unfair_lock_lock(&g_modeLock);
g_userSelectedPowerMode = selected;
g_powerMode = blanked ? CPUthermalPowerModeLow : selected;
os_unfair_lock_unlock(&g_modeLock);
}
}
}

// ============================================================================
// 热管理 IOKit 服务名
// ============================================================================
static const char *g_hotServices[] = {
"AppleSPU", "AppleSPU.original",
"AppleARMPlatform",
"pmu", "ApplePMGR",
"AppleGPU", "AGXDriver",
"ANECompilerService", "AppleANE",
"AppleM2ScalerCSC", "IOSurface",
NULL
};

#define SELECTOR_IS_MITIGATION(s)  ((s) >= 0x20 && (s) <= 0x5F)  // 拦截 0x20-0x5F（扩展低频管理+温控）
#define SELECTOR_IS_CRITICAL(s)    ((s) >= 0x60)                  // 紧急保护 — 不拦截

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
static os_unfair_lock g_connLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护 g_conns/g_connCount

static void trackConnection(io_connect_t conn, BOOL thermal) {
if (conn == MACH_PORT_NULL) return;
os_unfair_lock_lock(&g_connLock);
if (g_connCount < MAX_CONN) {
g_conns[g_connCount].conn     = conn;
g_conns[g_connCount].isThermal = thermal;
g_connCount++;
}
os_unfair_lock_unlock(&g_connLock);
}

static BOOL serviceIsThermal(io_service_t service) {
if (service == MACH_PORT_NULL) return NO;
io_name_t name = {0};
if (IORegistryEntryGetName(service, name) != KERN_SUCCESS) return NO;
for (int i = 0; g_hotServices[i]; i++) {
if (strcmp(name, g_hotServices[i]) == 0) return YES;
}
return NO;
}

// ============================================================================
// IOKit 层钩子
// ============================================================================

// --- IOServiceOpen — 追踪 thermal connection ---
%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_t task, uint32_t type, io_connect_t *connect) {
kern_return_t ret = %orig;
if (ret == KERN_SUCCESS && connect && *connect != MACH_PORT_NULL) {
trackConnection(*connect, serviceIsThermal(service));
}
return ret;
}

// --- IOServiceClose — 清理已断开的 thermal connection（防止 g_conns 数组溢出后拦截失效）---
%hookf(kern_return_t, IOServiceClose, io_connect_t connect) {
if (connect == MACH_PORT_NULL) return %orig(connect);
os_unfair_lock_lock(&g_connLock);
for (int i = 0; i < g_connCount; i++) {
if (g_conns[i].conn == connect) {
for (int j = i; j < g_connCount - 1; j++) {
g_conns[j] = g_conns[j + 1];
}
g_connCount--;
break;
}
}
os_unfair_lock_unlock(&g_connLock);
return %orig(connect);
}

// --- IOConnectCallMethod — 保留连接追踪，不再按 selector 范围盲拦截 ---
%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
if (connection == MACH_PORT_NULL) return %orig;
return %orig;
}

// 异步与结构体调用必须放行，否则 ObjC 层强制后的目标也无法真正写入 ApplePPM。
%hookf(kern_return_t, IOConnectCallAsyncMethod, mach_port_t connection, uint32_t selector, mach_port_t wakePort, mach_port_t *asyncRef, uint32_t asyncRefCnt, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
if (connection == MACH_PORT_NULL) return %orig;
return %orig;
}

%hookf(kern_return_t, IOConnectCallStructMethod, mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
if (connection == MACH_PORT_NULL) return %orig;
return %orig;
}

// --- IOServiceSetProperty — 丢弃 thermalmonitord 的频率/功耗约束属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!orig_IOServiceSetProperty) return KERN_FAILURE;
if (service == MACH_PORT_NULL || !key || !value) return orig_IOServiceSetProperty(service, key, value);
if (!runtimeEnabled() || g_restoringFullPower) {
return orig_IOServiceSetProperty(service, key, value);
}

NSString *keyString = (__bridge NSString *)key;
if (thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(keyString)) {
id replacement = backlightReplacementMatchingValue(keyString, (__bridge id)value);
return replacement ? orig_IOServiceSetProperty(service, key, (__bridge CFTypeRef)replacement) : orig_IOServiceSetProperty(service, key, value);
}
if (isNetworkThrottleProperty(key)) return KERN_SUCCESS;


if (shouldApplyFullCPUProtection() && keyIsThermalThrottleProperty(keyString)) {
return KERN_SUCCESS;
}
return orig_IOServiceSetProperty(service, key, value);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
if (entry == MACH_PORT_NULL || !key || !value) return %orig(entry, key, value);
if (!runtimeEnabled() || g_restoringFullPower) return %orig(entry, key, value);
NSString *keyString = (__bridge NSString *)key;
if (thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(keyString)) {
id replacement = backlightReplacementMatchingValue(keyString, (__bridge id)value);
return replacement ? %orig(entry, key, (__bridge CFTypeRef)replacement) : %orig(entry, key, value);
}
if (isNetworkThrottleProperty(key)) return KERN_SUCCESS;
if (shouldApplyFullCPUProtection() && keyIsThermalThrottleProperty(keyString)) {
return KERN_SUCCESS;
}
return %orig(entry, key, value);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperties, io_registry_entry_t entry, CFTypeRef properties) {
if (entry == MACH_PORT_NULL || !properties) return %orig(entry, properties);
if (!runtimeEnabled() || g_restoringFullPower) return %orig(entry, properties);
CFDictionaryRef replacement = copyPropertiesByRemovingThermalLimits(properties);
if (!replacement) return %orig(entry, properties);
if (CFDictionaryGetCount(replacement) == 0) {
CFRelease(replacement);
return KERN_SUCCESS;
}
kern_return_t result = %orig(entry, replacement);
CFRelease(replacement);
return result;
}

// ============================================================================
// ObjC 类钩子（第1层: CommonProduct / HidSensors — 已有）
// ============================================================================

// --- CommonProduct: thermalmonitord 核心热管理对象 ---
%hook CommonProduct

- (id)initProduct:(id)arg1 {
id res = %orig;
if (res && runtimeEnabled()) {
installCrossVersionThermalAliases();
setCommonProduct((CommonProduct *)res);
if (shouldApplyFullCPUProtection()) {
[(CommonProduct *)res putDeviceInThermalSimulationMode:S("nominal")];
}
applyCurrentPowerModeToRuntime();
NSLog(@"[CPUthermal] CommonProduct init, 功率模式:%@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
return res;
}

- (void)tryTakeAction {
if (shouldApplyFullCPUProtection()) {
// 强制热压力为 Nominal（最多每秒校正一次，避免快循环广播）
correctNominalStateIfNeeded();
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

// 解除温控模式关闭 CPMS；低功耗模式强制重新启用 CPMS。
- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
if (g_restoringFullPower) {
%orig(enabled);
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
%orig(enabled);
}

// 解除温控模式: 直接阻断 CPU 节流等级写入，拒绝执行降频指令。
- (void)setCPULevel:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(kLowPowerCPULevel);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kFullPowerCPULevel);
return;
}
%orig(level);
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPerformancePercent, source);
return;
}
%orig(ceiling, source);
}

- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyHighPerformanceMode()) {
%orig(kUnrestrictedPerformancePercent, source);
return;
}
%orig(ceiling, source);
}

- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyHighPerformanceMode()) {
%orig(kUnrestrictedPerformancePercent, source);
return;
}
%orig(ceiling, source);
}

%end

// --- HidSensors: HID 温度事件处理（与「屏蔽高温温度计警告」共用开关）---
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
if (thermalPopupBlockingEnabled()) {
CPUthermalForceNominalCombined();
return;
}
%orig(arg1, arg2);
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层）
//
// 冲突避免说明:
//   - 传感器读数 getHighestSkinTemp/dieTempFilteredMaxAverage/thermalSensorValuesMaxFromIndexSet
//     不在此处 hook (IOKit 层已拦截)
//   - putDeviceInThermalSimulationMode: 不 hook (CPUthermal 自已调用会递归)
//   - setCPMSMitigationState: 直接在决策层拦截，避免进入 CPMS 写路径
//   - setHiPFeatureEnabled: 不 hook
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
// 全功率模式: 阻止决策树运行，避免温控降频
if (shouldApplyFullCPUProtection()) {
correctNominalStateIfNeeded();
return;
}
%orig;
}

- (void)setCPMSMitigationState:(int)state {
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig(state);
}

// 热压力升级通知 — 不再主动阻断
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
if (thermalPopupBlockingEnabled()) {
CPUthermalForceNominalCombined();
return;
}
%orig(notification, force);
}

// 热通知 — 受 thermalBlockNotifPopup 开关控制
- (void)updateThermalNotification:(id)notification {
@autoreleasepool {
if (thermalPopupBlockingEnabled()) {
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
return 0.0;  // 彻底归零
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
if (shouldApplyLowPowerLimit()) return YES;
if (shouldApplyFullCPUProtection()) return NO;
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
trackPowerController(self);  // 唤醒后重建实例自注册
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
%orig(active);
}

- (void)setPowerSaveToken:(id)token {
trackPowerController(self);  // 唤醒后重建实例自注册
if (g_restoringFullPower) {
%orig(token);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(nil);
return;
}
%orig(token);
}

// 计算控制力度 — 这是 throttle 量的核心
// soften 模式下减半但不归零，保留基础调节能力
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
if (shouldApplyFullCPUProtection()) {
return 0.0;  // 彻底归零，不降频
}
return %orig(trigger, arg2);
}

// actionComponentControl — 组件控制动作
- (void)actionComponentControl {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}


%end

// --- ApplePPMCPU: 兼容部分系统版本；当前主路径由 MitigationController 执行 ---
%hook ApplePPMCPU

// 修复：追踪实例，确保 keep-alive 能强制重应用（弱引用防止僵尸实例泄漏）
- (id)init {
id res = %orig;
if (res) {
trackApplePPMInstance(res);
}
return res;
}

- (void)setCPULevel:(int)level {
// 修复：每次调用都自注册实例，确保唤醒后重建的实例不被漏追踪
trackApplePPMInstance(self);
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(kLowPowerCPULevel);
return;
}
if (shouldApplyFullCPUProtection()) {
// 解除温控模式: 直接阻断节流等级，ApplePPM 保持内核原生 DVFS 自由调频
return;
}
%orig;
}

- (void)updateCPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyLowPowerLimit()) {
if (self && [self respondsToSelector:@selector(setCPULevel:)]) {
[self setCPULevel:kLowPowerCPULevel];
}
%orig;
return;
}
// 解除温控只在模式切换时清除 Level 2；后续放行原生 DVFS 更新。
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

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
if (g_restoringFullPower) {
%orig(enabled);
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
%orig(enabled);
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) {
return %orig;
}
if (shouldApplyLowPowerLimit()) return YES;
if (shouldApplyFullCPUProtection()) return NO;
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
trackPowerController(self);
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
%orig(active);
}

- (void)setPowerSaveToken:(int)token {
if (g_restoringFullPower) {
%orig(token);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig(token);
}

// 解除温控模式: 直接阻断 CPU 节流等级写入（MitigationController 使用 0~100 百分比）。
- (void)setCPULevel:(int)level {
trackPowerController(self);
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(kLowPowerCPULevel);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kFullPowerCPULevel);
return;
}
%orig(level);
}

// 解除温控模式: 直接阻断 CPU 温控缓解等级写入。
- (void)setCPUMitigationLevel:(int)level {
trackPowerController(self);
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(level);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kFullPowerCPULevel);
return;
}
%orig(level);
}

- (void)setDVD1Level:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(level);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kFullPowerCPULevel);
return;
}
%orig(level);
}

- (void)updateCPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyLowPowerLimit()) {
reassertLowPowerStateWithoutUpdate(self);
%orig;
reassertLowPowerStateWithoutUpdate(self);
return;
}
if (shouldApplyFullCPUProtection()) {
trackPowerController(self);
%orig;
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
%orig;
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
%orig;
return;
}
%orig;
}

- (void)setCPULowPowerTarget:(int)target {
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(target);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPowerLimitMW);
return;
}
%orig(target);
}

- (void)setPackageLowPowerTarget {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
// 解除温控模式: 阻断包级低功耗目标写入
return;
}
%orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
uintptr_t propertyArg = normalizedSetMaxCPUPowerPropertyArgument(self, property);
if (g_restoringFullPower) {
%orig(target, legacy, propertyArg);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(target, legacy, propertyArg);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPowerLimitMW, NO, propertyArg);
return;
}
%orig(target, legacy, propertyArg);
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(ceiling, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPerformancePercent, source);
return;
}
%orig(ceiling, source);
}

- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(int)contributor {
if (g_restoringFullPower) {
%orig(ceiling, contributor);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(ceiling, contributor);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPerformancePercent, contributor);
return;
}
%orig(ceiling, contributor);
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(floor, source);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(floor, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(shouldApplyHighPerformanceMode() ? kUnrestrictedPerformancePercent : 0, source);
return;
}
%orig(floor, source);
}

- (void)setCPUPowerZoneTarget:(int)target {
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(target);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPerformancePercent);
return;
}
%orig(target);
}

%end

// ============================================================================
// 防温控暗屏 — 修补热配置 plist 中的背光参数
// 由 thermalPreventDimmingEnabled 开关控制
// ============================================================================

// 从设备自身热配置中选择最大数值，不写固定 nits/机型参数。
static id CPUthermalMaximumNumericValue(NSArray *values) {
    NSNumber *maximum = nil;
    for (id value in values) {
        if (![value isKindOfClass:[NSNumber class]]) continue;
        if (!maximum || [(NSNumber *)value compare:maximum] == NSOrderedDescending) maximum = value;
    }
    return maximum;
}

static void CPUthermalRecordMaximumBacklightValue(NSNumber *value, NSString *key) {
if (![value isKindOfClass:[NSNumber class]]) return;
if (!g_maxBacklightBrightnessValue || [value compare:g_maxBacklightBrightnessValue] == NSOrderedDescending) g_maxBacklightBrightnessValue = value;
}

static id CPUthermalPatchBacklightNode(id node, BOOL displayContext, NSString *parentKey) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [(NSDictionary *)node mutableCopy];
        for (id rawKey in [(NSDictionary *)node allKeys]) {
            if (![rawKey isKindOfClass:[NSString class]]) continue;
            NSString *key = (NSString *)rawKey;
            NSString *lower = [key lowercaseString];
            BOOL childContext = displayContext || [lower containsString:S("backlight")] ||
                [lower containsString:S("display")];
            id value = [(NSDictionary *)node objectForKey:key];
            if (childContext && [value isKindOfClass:[NSNumber class]] && keyIsBacklightThermalLimit(key))
                CPUthermalRecordMaximumBacklightValue(value, key);

            result[key] = CPUthermalPatchBacklightNode(value, childContext, key) ?: value;
        }
        return result;
    }

    if ([node isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)node;
        NSString *lowerKey = [parentKey lowercaseString] ?: S("");
        BOOL brightnessArray = displayContext &&
            ([lowerKey containsString:S("brightness")] ||
             [lowerKey containsString:S("luminance")] ||
             [lowerKey containsString:S("nits")]);
        if (brightnessArray && array.count > 0) {
            id maximum = CPUthermalMaximumNumericValue(array);
            if (maximum) {
                CPUthermalRecordMaximumBacklightValue(maximum, parentKey);
                NSMutableArray *filled = [NSMutableArray arrayWithCapacity:array.count];
                for (id original in array) {
                    if ([original isKindOfClass:[NSNumber class]] && [(NSNumber *)original doubleValue] <= 0.0) [filled addObject:original];
                    else [filled addObject:maximum];
                }
                return filled;
            }
        }

        NSMutableArray *result = [NSMutableArray arrayWithCapacity:array.count];
        for (id value in array) {
            [result addObject:CPUthermalPatchBacklightNode(value, displayContext, parentKey) ?: value];
        }
        return result;
    }
    return node;
}

static NSDictionary *patchThermalPlist(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]] || !thermalDimmingPreventionEnabled()) return dict;
    id patched = CPUthermalPatchBacklightNode(dict, NO, nil);
    NSLog(@"[CPUthermal] 已按设备热配置最大值修补背光亮度/功率档位");
    return [patched isKindOfClass:[NSDictionary class]] ? patched : dict;
}

// ============================================================================
// %hook: NSDictionary — 拦截热配置 plist 加载，应用防暗屏补丁
// ============================================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
id res = %orig(path);
if (thermalDimmingPreventionEnabled() && [path isKindOfClass:[NSString class]] && [path containsString:S("/System/Library/ThermalMonitor")]) {
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

// _getConfigurationFor 替换实现：调用原始函数后应用热配置补丁（防温控暗屏）
static NSDictionary *new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor ? orig_getConfigurationFor(key) : nil;
    return patchThermalPlist(config);
}

// ============================================================================
// Puppet 事件（由 Preferences 面板触发 — 模拟热级别切换）
// ============================================================================
static void executePuppetEvent(void) {
CommonProduct *product = commonProductSnapshot();
if (!product) return;
@autoreleasepool {
NSDictionary *prefs = readPrefsDictionary();
id configuredLevel = [prefs isKindOfClass:[NSDictionary class]] ? prefs[S("thermalPuppetValue")] : nil;
NSString *level = [configuredLevel isKindOfClass:[NSString class]] ? configuredLevel : S("nominal");
[product putDeviceInThermalSimulationMode:level];
NSLog(@"[CPUthermal] Puppet 事件: 热模式设为 %@", level);
}
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
executePuppetEvent();
}

static void onPowerModeChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
BOOL lowPower = NO;
CPUthermalPowerMode selected;
if (CPUthermalReadPostedPowerMode(&lowPower)) {
selected = lowPower ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
} else {
NSDictionary *prefs = readPrefsDictionary();
NSString *mode = [prefs[S("powerMode")] isKindOfClass:[NSString class]] ? prefs[S("powerMode")] : S("fullPower");
selected = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
}
if (selected == CPUthermalPowerModeLow) {
    g_highPerformanceModeEnabled = NO;
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs() ?: [NSMutableDictionary dictionary];
    if ([prefs[S("highPerformanceModeEnabled")] boolValue]) {
        prefs[S("highPerformanceModeEnabled")] = [NSNumber numberWithBool:NO];
        CPUthermalWritePrefs(prefs);
        notify_post(kCPUthermalSettingsChangedNotifC);
    }
}
BOOL blanked = CPUthermalScreenIsBlanked();
CPUthermalPowerMode previous;
os_unfair_lock_lock(&g_modeLock);
previous = g_powerMode;
g_userSelectedPowerMode = selected;
g_powerMode = blanked ? CPUthermalPowerModeLow : selected;
CPUthermalPowerMode runtimeMode = g_powerMode;
os_unfair_lock_unlock(&g_modeLock);
if (previous != runtimeMode) {
applyPowerModeToRuntime(NO);
if (previous == CPUthermalPowerModeLow && runtimeMode == CPUthermalPowerModeFull)
    scheduleThermalMonitorReload();
}
NSLog(@"[CPUthermal] 用户模式已选择:%@，当前屏幕:%@，运行模式:%@",
      selected == CPUthermalPowerModeLow ? S("低功耗") : S("解除温控"),
      blanked ? S("熄屏") : S("亮屏"),
      runtimeMode == CPUthermalPowerModeLow ? S("低功耗") : S("解除温控"));
};
if ([NSThread isMainThread]) block();
else dispatch_async(dispatch_get_main_queue(), block);
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
BOOL wasEnabled = runtimeEnabled();
BOOL previousPreventDimming = g_thermalPreventDimmingEnabled;
loadPrefs();
BOOL enabled = NO;
BOOL cpuProtection = NO;
BOOL blockPopup = NO;
BOOL preventDimming = NO;
runtimeConfigSnapshot(&enabled, &cpuProtection, NULL, &blockPopup, &preventDimming);
if (enabled) applyPowerModeToRuntime(NO);
else if (wasEnabled) restoreNativeRuntimeAfterDisable();
if (previousPreventDimming != g_thermalPreventDimmingEnabled) scheduleThermalConfigurationReload();
NSLog(S("[CPUthermal] 设置已重载 enabled:%d CPU:%d 弹窗:%d 防暗屏:%d DVFS:原生 level:%d"),
enabled, cpuProtection, blockPopup, preventDimming, targetCPUPerformanceLevel());
};
if ([NSThread isMainThread]) block();
else dispatch_async(dispatch_get_main_queue(), block);
}

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
loadPrefs();

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

// 仅解除温控模式伪造 Nominal；低功耗或禁用时保留系统真实状态。
if (shouldApplyFullCPUProtection()) CPUthermalForceNominalCombined();

BOOL cpuProtection = NO;
runtimeConfigSnapshot(NULL, &cpuProtection, NULL, NULL, NULL);
NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:已禁用 CPU性能:%d", cpuProtection);

// 功率模式与常规设置均通过 Darwin 通知实时重载，无需重启用户空间。

// 模拟热级别监听（独立功能，不影响配置重载）
CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
if (c) {
CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
(__bridge CFStringRef)S("com.huayuarc.cputhermal.puppet"),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
CFNotificationCenterAddObserver(c, NULL, onPowerModeChanged,
(__bridge CFStringRef)S(kCPUthermalPowerModeChangedNotifC),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

registerScreenWakeObservers();
installCrossVersionThermalAliases();
applyCurrentPowerModeToRuntime();
NSLog(@"[CPUthermal] 启动完成，当前功率模式:%@，低功耗将在下次亮屏/解锁后自动结束", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
}
