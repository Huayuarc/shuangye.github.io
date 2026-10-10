#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <stdint.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <signal.h>
#include <pthread.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <CPUthermalPaths.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <os/lock.h>
#import <mach/host_info.h>
#import <mach/task_info.h>

// ============================================================================
// ObjC 类声明（thermalmonitord 内部类，class-dump 获取）
// ============================================================================
@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)arg1 service:(uintptr_t)arg2;
@end

@interface CommonProduct : NSObject
- (id)initProduct:(uintptr_t)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setThermalState:(int)state; // 主动调用仍按运行时 encoding 校验，不信任声明。
- (BOOL)setServiceProperty:(uintptr_t)service key:(id)key value:(uintptr_t)value scaleToFixedPoint:(BOOL)scale;
- (void)setHiPFeatureEnabled:(BOOL)enabled;
- (int)dieTempFilteredMaxAverage;
- (int)getHighestSkinTemp;
- (BOOL)shouldEnforceLightThermalPressure;
- (int)getPotentialForcedThermalLevel:(uintptr_t)component;
- (int)getPotentialForcedThermalPressureLevel;
@end

// ============================================================================
@interface ThermalManager : NSObject
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
- (id)getConfigurationFor:(NSString *)key;
- (void)evaluateDecisionTree;
- (id)findComponent:(id)component;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (float)getReleaseRateForComponent:(uintptr_t)component;
- (int)getPotentialForcedThermalLevel:(uintptr_t)component;
- (int)getPotentialForcedThermalPressureLevel;
- (void)updateThermalPressureLevelNotification:(int)notification shouldForceThermalPressure:(BOOL)force;
- (void)updateThermalNotification:(int)notification;
- (BOOL)shouldEnforceLightThermalPressure;
- (void)setCPMSMitigationState:(int)state;
@end

@interface ThermalControl : NSObject
- (float)calculateControlEffort:(uintptr_t)trigger trigger:(uintptr_t)arg2;
- (id)findCC:(id)component;
- (int)dieTempFilteredMaxAverage;
- (int)getHighestSkinTemp;
- (float)thermalSensorValuesMaxFromIndexSet:(id)indexSet;
- (void)copyDieTempSensorIndexSetForFourthChar:(char)c sensors:(id)sensors;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(uintptr_t)token;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(uintptr_t)saveParams powerZoneParams:(uintptr_t)zoneParams;
- (id)initWithParams:(uintptr_t)params;
- (void)updatePowerParameters:(uintptr_t)params;
- (BOOL)setServiceProperty:(uintptr_t)service key:(id)key value:(uintptr_t)value scaleToFixedPoint:(BOOL)scale;
- (void)setHiPFeatureEnabled:(BOOL)enabled;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface MitigationController : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(uintptr_t)saveParams powerZoneParams:(uintptr_t)zoneParams;
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
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setGPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setGPUPowerZoneTarget:(int)target;
- (void)setSGXLevel:(int)level;
- (void)setMaxGraphicsDrivePowerTarget:(int)target;
- (void)setPackagePowerBudgetDirect:(int)budget withDetails:(id)details;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setPackagePowerZoneTarget;
- (void)setMaxPackagePower:(int)power;
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
- (id)initWithParams:(uintptr_t)params aggdController:(id)aggd;
@end

@interface CommonAggdController : NSObject
- (id)initWithParams:(uintptr_t)params product:(id)product;
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
CPUthermalPowerModeLow  = 1,
CPUthermalPowerModeExtreme = 2
} CPUthermalPowerMode;

// 专用串行队列：所有模式应用/重申/脉冲都离开 thermalmonitord 主线程，
// 避免与守护自身主线程锁互相等待导致 watchdog 挂起（180s 无 checkin → 用户空间重启）。
static dispatch_queue_t CPUthermalEngineQueue(void) {
    static dispatch_queue_t queue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.huayuarc.cputhermal.engine", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
static BOOL g_applyingPowerMode = NO;
// 周期性重申总开关：实测 setCPULevel/预算 setter 在 iOS 16 上不被 CLPC 采纳，
// 而跨线程反复调用 thermalmonitord 对象是 watchdog 挂起（主线程无 checkin）的主要来源。
// 置 NO 后只保留“切档时应用一次”，不再有任何周期性重入。
static const BOOL kPeriodicReassertEnabled = NO;
static os_unfair_lock g_applyLock = OS_UNFAIR_LOCK_INIT;

static CPUthermalPowerMode g_powerMode = CPUthermalPowerModeFull;
static CPUthermalPowerMode g_userSelectedPowerMode = CPUthermalPowerModeFull;
static __thread BOOL g_reassertingLowPower = NO;  // 防 updateCPU 钩子与 reassert 互相递归

// setCPULowPowerTarget:/setMaxCPUPowerTarget: 使用 mW；65000 是 thermalmonitord 的无限制哨兵值。
// setCPULevel:/setCPUPowerCeiling:/setCPUPowerFloor:/setCPUPowerZoneTarget: 使用 0~100 百分比。
static const int kUnrestrictedPowerLimitMW = 65000;
static const int kUnrestrictedPerformancePercent = 100;
static const int kLowPowerCPULevel = 2;
static const int kLowPowerPowerLimitMW = 2500;
static const int kLowPowerPerformancePercent = 45;
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
static int g_lockStateToken = -1;
static int g_blankedScreenToken = -1;
static int g_thermalNotificationToken = -1;
static int g_thermalPressureToken = -1;
static dispatch_queue_t g_thermalResetQueue = NULL;
static os_unfair_lock g_thermalResetLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime g_lastThermalReset = 0;
static os_unfair_lock g_nominalLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime g_lastNominalCorrection = 0;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护g_powerMode
static NSHashTable *g_applePPMInstances = nil;           // 追踪 ApplePPMCPU 实例（弱引用，防止僵尸实例泄漏）
// 高温告警默认屏蔽；防暗屏仍由用户设置决定。
// 屏蔽高温温度计警告：**恒开**（面板已移除开关，避免误操作）
static BOOL g_thermalBlockNotifPopup = YES;
static BOOL g_thermalPreventDimmingEnabled = NO;
static BOOL isFullPowerMode(void);
static BOOL shouldApplyLowPowerLimit(void);
static void CPUthermalApplySimulatedThermalLevel(void);
static int targetCPUPerformanceLevel(void);
static void loadPrefs(void);
static NSDictionary *readPrefsDictionary(void);
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
static void applyLowPowerLimitsToTrackedControllers(void);
static void restoreNativeRuntimeAfterDisable(void);
static void correctNominalStateIfNeeded(void);
static void switchToLowPowerForSleep(const char *source);
static void restoreUserModeAfterWake(const char *source);
static void registerScreenWakeObservers(void);
static void CPUthermalCaptureExistingBacklightMaximum(void);
static void CPUthermalScheduleBacklightRecovery(void);

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
return enabled && blockNetwork && isFullPowerMode();
}

static BOOL thermalPopupBlockingEnabled(void) {
BOOL enabled = NO;
BOOL blockPopup = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, &blockPopup, NULL);
return enabled && blockPopup;
}

static BOOL thermalDimmingPreventionEnabled(void) {
// 防温控暗屏恒开：不再依赖任何偏好开关（面板已移除该项）。
BOOL enabled = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL, NULL);
return enabled;
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
CPUthermalPowerMode m = g_powerMode;
os_unfair_lock_unlock(&g_modeLock);
return m == CPUthermalPowerModeLow;
}

static BOOL isFullPowerMode(void) {
os_unfair_lock_lock(&g_modeLock);
CPUthermalPowerMode m = g_powerMode;
os_unfair_lock_unlock(&g_modeLock);
return m == CPUthermalPowerModeFull;
}


static BOOL shouldApplyFullCPUProtection(void) {
return runtimeProtectionEnabled() && isFullPowerMode();
}

static BOOL shouldPinCPUAtMaximum(void) {
// “解除温控”仍使用 fullPower 偏好值，但 CPU 上下限均锁定 100。
return runtimeProtectionEnabled() && isFullPowerMode();
}

static BOOL shouldRestoreNativePerformance(void) {
return shouldApplyFullCPUProtection();
}

static BOOL shouldApplyLowPowerLimit(void) {
// 低功耗运行方式：与解除温控同一总开关，按当前模式判定（此前恒为 NO 导致切档无效果）。
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

static void switchToLowPowerForSleep(const char *source) {
(void)source; // 低功耗已移除；熄屏不改变温控运行模式。
}

static void restoreUserModeAfterWake(const char *source) {
(void)source;
// 锁屏/亮屏是同一事务的两个通知；同一 engine queue 上合并，不重复
// controller updateCPU、六轮恢复脉冲与模拟热档写入。
static CFAbsoluteTime lastWakeRestore = 0;
CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
if (now - lastWakeRestore < 0.5) return;
lastWakeRestore = now;
os_unfair_lock_lock(&g_modeLock);
CPUthermalPowerMode target = g_userSelectedPowerMode;
g_powerMode = target;
os_unfair_lock_unlock(&g_modeLock);
applyPowerModeToRuntime(NO);
// 解锁/亮屏后系统会重新评估热状态：立即重申 + 稍后再补几次，确保频率回到该模式对应档位
for (int i = 0; i < 3; i++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + i * 2.0) * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (shouldApplyFullCPUProtection()) CPUthermalApplySimulatedThermalLevel();
    });
}
// 解锁/亮屏后系统会重新评估性能等级：低功耗模式下必须立刻重申锁频，
// 否则界面仍是低功耗但频率会回到最高。
if (isLowPowerMode()) {
CPUthermalApplySimulatedThermalLevel();
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
startLowPowerRescheduleTimer();

}

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

static void handleThermalLevelNotification(int token) {
    uint64_t state = 0;
    if (token <= 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK || state == 0 || !shouldApplyFullCPUProtection()) return;
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&g_thermalResetLock);
    BOOL allowed=(now-g_lastThermalReset)>=5.0;
    if(allowed)g_lastThermalReset=now;
    os_unfair_lock_unlock(&g_thermalResetLock);
    if (!allowed) return;
    CPUthermalForceNominalCombined();
    os_unfair_lock_lock(&g_nominalLock);
    g_lastNominalCorrection = now;
    os_unfair_lock_unlock(&g_nominalLock);
}

static void registerThermalLevelResetObservers(void) {
    if (!g_thermalResetQueue) g_thermalResetQueue=dispatch_queue_create("com.huayuarc.cputhermal.thermal-reset",DISPATCH_QUEUE_SERIAL);
    if (g_thermalPressureToken < 0) {
        notify_register_dispatch(kOSThermalNotificationPressureLevelName, &g_thermalPressureToken,
                                 g_thermalResetQueue, ^(int token) { handleThermalLevelNotification(token); });
    }
    if (g_thermalNotificationToken < 0) {
        notify_register_dispatch("com.apple.system.thermalnotification", &g_thermalNotificationToken,
                                 g_thermalResetQueue, ^(int token) { handleThermalLevelNotification(token); });
    }
}

static void registerScreenWakeObservers(void) {
if (g_lockStateToken < 0) {
notify_register_dispatch("com.apple.springboard.lockstate", &g_lockStateToken, CPUthermalEngineQueue(), ^(int token) {
handleLockStateToken(token);
});
}
if (g_blankedScreenToken < 0) {
notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &g_blankedScreenToken, CPUthermalEngineQueue(), ^(int token) {
handleBlankedScreenToken(token);
});
}
// daemon 可能在设备已经熄屏时启动，注册后立即同步一次当前屏幕状态。
handleBlankedScreenToken(g_blankedScreenToken);
}

static int targetCPUPerformanceLevel(void) {
if (isLowPowerMode()) return kLowPowerCPULevel;
return kFullPowerCPULevel;   // fullPower 使用 Level 0（无 mitigation）；实际 CPU 频率由 Floor=100 请求固定
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

static void applyExplicitLowPowerBudgets(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)])
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), kLowPowerPowerLimitMW);
if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)])
sendSetMaxCPUPowerTarget(controller, kLowPowerPowerLimitMW, NO);
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)])
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), kLowPowerPerformancePercent);
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)])
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, (uintptr_t)source);
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)])
sendTwoIntegerArguments(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), kLowPowerPerformancePercent, (uintptr_t)source);
}
for (int contributor = 0; contributor < kCPUDVD1ContributorCount; contributor++)
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)])
sendTwoIntegerArguments(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), kLowPowerPerformancePercent, (uintptr_t)contributor);
}

static void reassertLowPowerStateWithoutUpdate(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
if (g_reassertingLowPower) return;   // 已在重断言中：hook 回调直接放行，杜绝递归
g_reassertingLowPower = YES;
@try {
trackPowerController(controller);
// CPU CPMS 必须开启，CPU Level/预算才会真正落到 ApplePPM；PowerSave/Package 仍保持关闭，避免显示联动。
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
// CPU 专用预算执行，不向显示/Package 发布全局节能状态。
if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
if ([controller respondsToSelector:@selector(setCPULevel:)])
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kLowPowerCPULevel);
// 注意：此处绝不能再 msgSend updateCPU —— 它会回到 updateCPU 钩子形成无限递归（栈溢出崩溃）
if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
if ([controller respondsToSelector:@selector(setCPULevel:)])
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kLowPowerCPULevel);
applyExplicitLowPowerBudgets(controller);
} @finally {
g_reassertingLowPower = NO;
}
}

// 手动低功耗与指定应用低功耗统一使用 2500mW / 45% 明确预算。
static void applyLowPowerPerformancePreferenceToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
trackPowerController(controller);
// 低功耗只限制 CPU：开启 CPU CPMS 执行 Level/预算；不启用 PowerSave，也不调用 Package 低功耗目标。
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
sendSetPowerSaveToken(controller, 0);
applyExplicitLowPowerBudgets(controller);
forceCPUPerformanceLevelOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)])
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
applyExplicitLowPowerBudgets(controller);
forceCPUPerformanceLevelOnController(controller);
}

// 解除温控模式统一恢复 CPU level 与 DVD1 level。
static void forceCPUPerformanceLevelOnController(id controller) {
if (!controller || !runtimeProtectionEnabled()) return;
int targetLevel = targetCPUPerformanceLevel();

if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), targetLevel);
}
if (!isLowPowerMode() && [controller respondsToSelector:@selector(setDVD1Level:)]) {
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
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), shouldPinCPUAtMaximum() ? kUnrestrictedPerformancePercent : 0, (uintptr_t)source);
}
}
for (int contributor = 0; contributor < kCPUDVD1ContributorCount; contributor++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)]) {
sendTwoIntegerArguments(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), kUnrestrictedPerformancePercent, (uintptr_t)contributor);
}
}
if ([controller respondsToSelector:@selector(setGPUPowerZoneTarget:)]) ((void (*)(id,SEL,int))objc_msgSend)(controller,@selector(setGPUPowerZoneTarget:),kUnrestrictedPerformancePercent);
if ([controller respondsToSelector:@selector(setSGXLevel:)]) ((void (*)(id,SEL,int))objc_msgSend)(controller,@selector(setSGXLevel:),0);
if ([controller respondsToSelector:@selector(setMaxGraphicsDrivePowerTarget:)]) ((void (*)(id,SEL,int))objc_msgSend)(controller,@selector(setMaxGraphicsDrivePowerTarget:),kUnrestrictedPowerLimitMW);
if ([controller respondsToSelector:@selector(setMaxPackagePower:)]) ((void (*)(id,SEL,int))objc_msgSend)(controller,@selector(setMaxPackagePower:),kUnrestrictedPowerLimitMW);
for (int source=0;source<kCPUDecisionSourceCount;source++) {
if ([controller respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) sendTwoIntegerArguments(controller,@selector(setGPUPowerCeiling:fromDecisionSource:),kUnrestrictedPerformancePercent,(uintptr_t)source);
if ([controller respondsToSelector:@selector(setGPUPowerFloor:fromDecisionSource:)]) sendTwoIntegerArguments(controller,@selector(setGPUPowerFloor:fromDecisionSource:),0,(uintptr_t)source);
if ([controller respondsToSelector:@selector(setPackagePowerCeiling:fromDecisionSource:)]) sendTwoIntegerArguments(controller,@selector(setPackagePowerCeiling:fromDecisionSource:),kUnrestrictedPerformancePercent,(uintptr_t)source);
if ([controller respondsToSelector:@selector(setPackagePowerFloor:fromDecisionSource:)]) sendTwoIntegerArguments(controller,@selector(setPackagePowerFloor:fromDecisionSource:),0,(uintptr_t)source);
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
BOOL previousRestoring = g_restoringFullPower;
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
// 原生 update 可能按残留低功耗缓存回写 Level 2；更新一次后最终覆盖即可。
applyFullPowerBudgetsOnController(controller);
} @catch (__unused NSException *exception) {
} @finally {
g_restoringFullPower = previousRestoring;
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
// 禁用/卸载后清掉每个 CPU decision source 的锁定下限，交还系统原生预算。
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)])
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, (uintptr_t)source);
}
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updateGPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateGPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
}
} @catch (__unused NSException *exception) {
} @finally {
g_restoringFullPower = NO;
}
}
}

static void setCommonProductCeiling(CommonProduct *product, SEL selector, int ceiling) {
if (!product || !selector) return;
Method method = class_getInstanceMethod(object_getClass(product), selector);
char result[16] = {0};
if (!method || method_getNumberOfArguments(method) != 4) return;
method_getReturnType(method, result, sizeof(result));
if (strcmp(result, "v") != 0) return;
char valueType = methodArgumentTypeCode(product, selector, 2);
char sourceType = methodArgumentTypeCode(product, selector, 3);
// decision source 只接受已识别整数；绝不传字符串对象或未知指针。
if (!strchr("iIqQ", valueType) || !valueType ||
    !strchr("iIqQ", sourceType) || !sourceType) {

    return;
}
sendTwoIntegerArguments(product, selector, ceiling, 0);
}

static void clearCommonProductThermalState(CommonProduct *product) {
SEL selector = @selector(setThermalState:);
Method method = product ? class_getInstanceMethod(object_getClass(product), selector) : NULL;
char result[16] = {0};
if (!method || method_getNumberOfArguments(method) != 3) return;
method_getReturnType(method, result, sizeof(result));
if (strcmp(result, "v") != 0) return;
switch (methodArgumentTypeCode(product, selector, 2)) {
    case 'i': ((void (*)(id, SEL, int))objc_msgSend)(product, selector, 0); break;
    case 'I': ((void (*)(id, SEL, unsigned int))objc_msgSend)(product, selector, 0u); break;
    case 'q': ((void (*)(id, SEL, int64_t))objc_msgSend)(product, selector, (int64_t)0); break;
    case 'Q': ((void (*)(id, SEL, uint64_t))objc_msgSend)(product, selector, (uint64_t)0); break;
    default:

        break; // 对象参数的值格式也未知，不再猜测 NSNumber。
}
}

static void applyLowPowerToCommonProduct(void) {
if (!shouldApplyLowPowerLimit()) return;
CommonProduct *product = commonProductSnapshot();
if (!product) return;
@try {
if ([product respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(product, @selector(setCPULevel:), kLowPowerCPULevel);
}
setCommonProductCeiling(product, @selector(setCPUPowerFloor:fromDecisionSource:), 0);
// 不调用 tryTakeAction：它会执行全组件热缓解（含显示/DCP），与“低功耗只限 CPU”相冲突。
} @catch (__unused NSException *exception) {
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
setCommonProductCeiling(product, @selector(setCPUPowerFloor:fromDecisionSource:), shouldPinCPUAtMaximum() ? kUnrestrictedPerformancePercent : 0);
setCommonProductCeiling(product, @selector(setGPUPowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent);
setCommonProductCeiling(product, @selector(setPackagePowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent);
clearCommonProductThermalState(product);
CPUthermalForceNominalCombined();
} @catch (__unused NSException *exception) {
} @finally {
g_restoringFullPower = previousRestoring;
}
}

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime(YES);
}

// ============================================================================
// nominal 校正独立于 CPU 专用预算；模式切换不制造热档，不重启守护。
// ============================================================================
// 高性能不再按 5 秒定时写 CommonProduct 模拟热档：只在明确模式/唤醒事务更新。

static void CPUthermalApplySimulatedThermalLevel(void) {
    CommonProduct *product = commonProductSnapshot();
    if (!product) return;
    // 关键修复：低功耗**不再**模拟 “Moderate” 热压力。
    // 实测：主动模拟热压力会让系统按热档执行降背光/降亮度（切到低功耗瞬间亮度掉落），
    // CPU 专用低功耗只从 Level/预算 setter 下发，与热模拟无关。
    // 这里始终只声明 nominal，杜绝我们自己触发系统降亮度。
    NSString *level = S("nominal");
    @try {
        if ([product respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
            [product putDeviceInThermalSimulationMode:level];

        }
    } @catch (__unused NSException *e) { }
}

// CPU 专用预算通过已有运行时控制器刷新，不缩放整份热配置。
// 避免进程重启清空限流计数，以及未知配置字段产生显示/Package 联动。
static void applyPowerModeToRuntime(BOOL respectBootGuard) {
os_unfair_lock_lock(&g_applyLock);
if (g_applyingPowerMode) { os_unfair_lock_unlock(&g_applyLock); return; }   // 嵌套调用直接放弃，防死锁
g_applyingPowerMode = YES;
os_unfair_lock_unlock(&g_applyLock);
@try {
if (!runtimeProtectionEnabled()) return;
(void)respectBootGuard;
if (isLowPowerMode()) {
// 低功耗同样必须保护屏幕亮度：恢复 90 版做法 —— 捕获用户亮度/面板上限并调度亮度重提交，
// 否则热降亮度后无人复位（此前删除这三行导致低功耗下防亮度失效）。
CPUthermalCaptureExistingBacklightMaximum();
CPUthermalScheduleBacklightRecovery();
CPUthermalApplySimulatedThermalLevel();
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleLowPowerApplyPulse();
startLowPowerRescheduleTimer();
return;
}
if (isFullPowerMode()) {
// 切回解除温控后主动清理低功耗残留的 DCP cap，并恢复切换前用户亮度。
CPUthermalApplySimulatedThermalLevel();
CPUthermalForceNominalCombined();
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleFullPowerRecoveryPulse();
stopLowPowerRescheduleTimer();
CPUthermalScheduleBacklightRecovery();
}
} @finally {
os_unfair_lock_lock(&g_applyLock);
g_applyingPowerMode = NO;
os_unfair_lock_unlock(&g_applyLock);
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
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), CPUthermalEngineQueue(), ^{
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
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), CPUthermalEngineQueue(), ^{
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
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), CPUthermalEngineQueue(), ^{
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
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), CPUthermalEngineQueue(), ^{
runLowPowerApplyPulse(remainingPulses - 1);
});
}


static void stopLowPowerRescheduleTimer(void) {
    dispatch_source_t timer=g_lowPowerRescheduleTimer;g_lowPowerRescheduleTimer=NULL;
    if(timer)dispatch_source_cancel(timer);
}
static void startLowPowerRescheduleTimer(void) {
    if(!kPeriodicReassertEnabled){stopLowPowerRescheduleTimer();return;}   // 已停用周期性重申
    if(!shouldApplyLowPowerLimit()){stopLowPowerRescheduleTimer();return;}
    if(g_lowPowerRescheduleTimer)return;
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,CPUthermalEngineQueue());
    if(!timer)return;g_lowPowerRescheduleTimer=timer;
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,100ull*NSEC_PER_MSEC),1ull*NSEC_PER_SEC,100ull*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{
        if(!shouldApplyLowPowerLimit()){stopLowPowerRescheduleTimer();return;}
        applyLowPowerToCommonProduct();applyLowPowerLimitsToTrackedControllers();applyCurrentModeToApplePPMCPU();
    });
    dispatch_resume(timer);
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

static NSNumber *g_maxBacklightBrightnessValue = nil; // 设备自身亮度 cap（如13Pro=1060），动态发现，不硬编码
static NSNumber *g_userBrightnessBeforeModeChange = nil; // 切换前用户滑块/实际亮度（如850.1）
static BOOL g_backlightRecoveryScheduled = NO;
static os_unfair_lock g_brightnessRecommitLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime g_lastBrightnessRecommitSchedule = 0;

static id CPUthermalCopyUserBrightness(void) {
    const char *paths[]={
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness",NULL};
    for(int i=0;paths[i];i++)if(dlopen(paths[i],RTLD_NOW|RTLD_LOCAL))break;
    Class cls=objc_getClass("BrightnessSystemClient"); if(!cls)return nil;
    id client=[[cls alloc]init]; SEL cp=sel_registerName("copyPropertyForKey:");
    if(![client respondsToSelector:cp])return nil;
    id display=((id(*)(id,SEL,id))objc_msgSend)(client,cp,S("DisplayBrightness"));
    id b=[display isKindOfClass:[NSDictionary class]]?display[S("Brightness")]:nil;
    return [b respondsToSelector:@selector(doubleValue)]&&[b doubleValue]>0.0?b:nil;
}


static void CPUthermalRecommitUserBrightness(void) {
    // 已禁用（关键修复）。原实现把“当前读到的亮度值”当作“用户亮度”用 Commit:YES 提交：
    // 一旦该值是被温控/低功耗压暗后的值（实测 163.3 nits），就会把暗值写死成新的请求值，
    // 且 20 秒自检周期会不断重申 -> 切回高性能/注销都无法恢复。
    // 现在亮度恢复完全交给 DisplayGuard 的“只抬不压”通道（按用户滑块值抬高上限），
    // 不再由本函数向 CoreBrightness 提交任何亮度。
    (void)CPUthermalCopyUserBrightness;
    return;
}

static void CPUthermalRecommitUserBrightnessSoon(void) {
    if (CPUthermalScreenIsBlanked()) return;
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&g_brightnessRecommitLock);
    BOOL allowed=(now-g_lastBrightnessRecommitSchedule)>=0.20;
    if(allowed)g_lastBrightnessRecommitSchedule=now;
    os_unfair_lock_unlock(&g_brightnessRecommitLock);
    if(!allowed)return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50ull*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{CPUthermalRecommitUserBrightness();});
}

// 任何 iPhone 面板亮度上限都远高于 400 nits；低于该值的观测一律视为
// “已被温控压低的值”，不作为原生上限采信，也绝不写回 DCP。
static const double kCPUthermalMinimumPlausibleBacklightLimit = 400.0;
// 部分显示键（如 AppleCLCD2 的 BLNitsCap）使用 16.16 定点 nits，
// 直接写 nits 会把上限写成 0.x nits 级别，必须按同一空间换算。
static const double kCPUthermalFixedPointScale = 65536.0;
static const char * const kCPUthermalBacklightLimitKeys[] = {
    "IOMFB_brightness_limit","IOMFB_max_brightness","IOMFB_brightness_max",
    "brightness-limit","brightness_limit","brightness-max","brightness-cap",
    "max-brightness","maxbrightness","MaxBrightness","brightnesscap","BrightnessCap",
    "BLNitsCap",NULL};

static double CPUthermalMaximumNumericInValue(id value);


static void CPUthermalRememberBacklightMaximum(id value) {
    if(![value respondsToSelector:@selector(doubleValue)])return;
    double v=[value doubleValue];
    // 低于 400 nits 的一律不采信为原生上限，避免把被温控压低的值学成“上限”。
    if(v<kCPUthermalMinimumPlausibleBacklightLimit||v>10000.0)return;
    if(!g_maxBacklightBrightnessValue||v>[g_maxBacklightBrightnessValue doubleValue]){
        g_maxBacklightBrightnessValue=[NSNumber numberWithDouble:v];

    }
}

// 尽力而为：从 CoreBrightness 客户端读取亮度信息（纯数字 0~1 的滑块值会被
// 400 nits 下限过滤掉，不会污染原生上限）。
static void CPUthermalRememberCoreBrightnessMaximum(void) {
    static BOOL tried = NO;
    if (tried) return;
    tried = YES;
    const char *paths[]={"/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                         "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness",NULL};
    for (int i=0;paths[i];i++) if (dlopen(paths[i], RTLD_NOW|RTLD_LOCAL)) break;
    Class cls = objc_getClass("BrightnessSystemClient");
    if (!cls) return;
    id client = nil;
    @try { client = [[cls alloc] init]; } @catch (__unused NSException *e) { return; }
    if (!client || ![client respondsToSelector:NSSelectorFromString(S("copyPropertyForKey:"))]) return;
    NSArray *keys = @[@"DisplayBrightness", @"DisplayBrightnessLimit", @"BrightnessLimit"];
    for (NSString *key in keys) {
        id value = nil;
        @try { value = ((id(*)(id,SEL,id))objc_msgSend)(client, NSSelectorFromString(S("copyPropertyForKey:")), key); }
        @catch (__unused NSException *e) { value = nil; }
        if (!value) continue;
        double v = CPUthermalMaximumNumericInValue(value);
        if (v > 0.0) CPUthermalRememberBacklightMaximum(@(v));
    }
}

static void CPUthermalCaptureExistingBacklightMaximum(void) {
    if(!thermalDimmingPreventionEnabled()||CPUthermalScreenIsBlanked())return;
    CPUthermalRememberCoreBrightnessMaximum();
    io_iterator_t it=IO_OBJECT_NULL;
    if(IORegistryCreateIterator(kIOMasterPortDefault,kIOServicePlane,kIORegistryIterateRecursively,&it)!=KERN_SUCCESS||it==IO_OBJECT_NULL)return;
    io_registry_entry_t e;
    while((e=IOIteratorNext(it))!=IO_OBJECT_NULL){
        for(int i=0;kCPUthermalBacklightLimitKeys[i];i++){
            CFStringRef k=CFStringCreateWithCString(NULL,kCPUthermalBacklightLimitKeys[i],kCFStringEncodingUTF8); if(!k)continue;
            CFTypeRef v=IORegistryEntryCreateCFProperty(e,k,NULL,0);
            if(v){ if(CFGetTypeID(v)==CFNumberGetTypeID()||CFGetTypeID(v)==CFStringGetTypeID())CPUthermalRememberBacklightMaximum((__bridge id)v); CFRelease(v); }
            CFRelease(k);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

// 只“抬高”不“压低”：仅当节点当前值低于已发现的原生上限时才写回，
// 任何情况下都不会把屏幕压暗（旧实现无条件写回，配合被污染的上限值锁死屏幕）。
static NSUInteger CPUthermalRaiseExistingBacklightLimits(void) {
    if(!thermalDimmingPreventionEnabled()||CPUthermalScreenIsBlanked())return 0;
    if(!g_maxBacklightBrightnessValue)CPUthermalCaptureExistingBacklightMaximum();
    double target=g_maxBacklightBrightnessValue?[g_maxBacklightBrightnessValue doubleValue]:0.0;
    if(target<kCPUthermalMinimumPlausibleBacklightLimit)return 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS || iterator == IO_OBJECT_NULL) return 0;
    NSUInteger raised = 0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        for (int i=0; kCPUthermalBacklightLimitKeys[i]; i++) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, kCPUthermalBacklightLimitKeys[i], kCFStringEncodingUTF8);
            if (!key) continue;
            CFTypeRef existing = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
            if (existing) {
                BOOL numeric = NO; double current = 0.0;
                if (CFGetTypeID(existing)==CFNumberGetTypeID()) { current=[(__bridge NSNumber *)existing doubleValue]; numeric=YES; }
                else if (CFGetTypeID(existing)==CFStringGetTypeID()) { current=[(__bridge NSString *)existing doubleValue]; numeric=YES; }
                if (numeric && current > 0.0 && target > 0.0) {
                    BOOL fixedPoint = (current > kCPUthermalFixedPointScale);
                    double scaled = fixedPoint ? target * kCPUthermalFixedPointScale : target;
                    // 只抬不压：定点键按 16.16 换算后比较，避免误写 0.x nits
                    if (current + 0.5 < scaled) {
                        id writeValue = fixedPoint ? @((long long)(scaled + 0.5)) : g_maxBacklightBrightnessValue;
                        IORegistryEntrySetCFProperty(entry, key, (__bridge CFTypeRef)writeValue);
                        raised++;
                    }
                }
                CFRelease(existing);
            }
            CFRelease(key);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);

    return raised;
}

static void CPUthermalRestoreExistingBacklightLimit(void) {
    if (!thermalDimmingPreventionEnabled() || CPUthermalScreenIsBlanked()) return;
    CPUthermalRaiseExistingBacklightLimits();
    CPUthermalRecommitUserBrightness();
}

// 周期自检（仅抬高限制，不动用户滑块，避免与自动亮度打架）：
// 覆盖“限制被别的进程写入 / 注销 SpringBoard 后无人复位”的场景。
static void CPUthermalBacklightAuditTick(void) {
    if (thermalDimmingPreventionEnabled()) {
        CPUthermalCaptureExistingBacklightMaximum();
        CPUthermalRaiseExistingBacklightLimits();
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20ull*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{CPUthermalBacklightAuditTick();});
}

static void CPUthermalStartBacklightAuditTimer(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20ull*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{CPUthermalBacklightAuditTick();});
}

static void CPUthermalScheduleBacklightRecovery(void) {
    if (!thermalDimmingPreventionEnabled() || g_backlightRecoveryScheduled) return;
    g_backlightRecoveryScheduled = YES;
    CPUthermalStartBacklightAuditTimer();
    const double delays[] = {0.10,0.40,0.90,1.80,3.00,6.00,12.00};
    for (NSUInteger i=0;i<sizeof(delays)/sizeof(delays[0]);i++) {
        BOOL finalAttempt=(i+1==sizeof(delays)/sizeof(delays[0]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delays[i]*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{CPUthermalRestoreExistingBacklightLimit();if(finalAttempt)dispatch_async(dispatch_get_main_queue(),^{g_backlightRecoveryScheduled=NO;g_userBrightnessBeforeModeChange=nil;});});
    }
}

static BOOL keyIsDisplayLifecycleProperty(NSString *key) {
if (!key || key.length == 0) return NO;
NSString *lower = [key lowercaseString];
return [lower containsString:S("idle")] || [lower containsString:S("autolock")] ||
       [lower containsString:S("lockstate")] || [lower containsString:S("sleep")] ||
       [lower containsString:S("blank")] || [lower containsString:S("screenoff")] ||
       [lower containsString:S("screen-off")] || [lower containsString:S("powerstate")] ||
       [lower containsString:S("power-state")] || [lower containsString:S("displaystate")] ||
       [lower containsString:S("screenstate")] || [lower containsString:S("wake")] ||
       [lower containsString:S("proximity")] || [lower containsString:S("backlightpower")];
}

static BOOL keyIsBacklightThermalLimit(NSString *key) {
if (!key || key.length == 0) return NO;
NSString *lower = [key lowercaseString];
if (keyIsDisplayLifecycleProperty(key)) return NO;
if ([lower isEqualToString:S("iomfb_brightness_limit")] ||
    [lower isEqualToString:S("max-brightness")] ||
    [lower isEqualToString:S("brightness-limit")] ||
    [lower isEqualToString:S("brightness_limit")] ||
    [lower isEqualToString:S("maxbrightness")] ||
    [lower isEqualToString:S("brightnesscap")]) return YES;
BOOL explicitThermal = [lower containsString:S("thermal")] ||
                       [lower containsString:S("mitigation")] ||
                       [lower containsString:S("temperature")];
BOOL explicitCap = [lower containsString:S("limit")] ||
                   [lower containsString:S("ceiling")] ||
                   [lower containsString:S("maximum")] ||
                   [lower containsString:S("max-")] ||
                   [lower containsString:S("cap")];
BOOL brightnessValue = [lower containsString:S("brightness")] ||
                       [lower containsString:S("luminance")] ||
                       [lower containsString:S("nits")];
BOOL displayOwner = [lower containsString:S("iomfb")] ||
                    [lower containsString:S("backlight")] ||
                    [lower containsString:S("display")];
return brightnessValue && explicitCap && (explicitThermal || displayOwner);
}

static id maximumBacklightReplacementForKey(NSString *key) {
return g_maxBacklightBrightnessValue;
}

static id backlightReplacementMatchingValue(NSString *key, id originalValue) {
CPUthermalRememberBacklightMaximum(originalValue);
id maximum = maximumBacklightReplacementForKey(key);
if (!maximum) return nil;
if ([originalValue isKindOfClass:[NSString class]]) {
double v = [(NSString *)originalValue doubleValue];
if (v <= 0.0) return nil;
if (v > kCPUthermalFixedPointScale) {
double raw = [(NSNumber *)maximum doubleValue] * kCPUthermalFixedPointScale;
return [NSString stringWithFormat:@"%.0f", raw];
}
return [(NSNumber *)maximum stringValue];
}
if ([originalValue isKindOfClass:[NSNumber class]]) {
double v = [(NSNumber *)originalValue doubleValue];
if (v <= 0.0) return nil;
if (v > kCPUthermalFixedPointScale)
return @([(NSNumber *)maximum doubleValue] * kCPUthermalFixedPointScale);
return maximum;
}
return nil;
}

// 判断是否为 thermalmonitord 发出的约束属性。
// 这里只丢弃用户态温控上限写入，不向内核写固定频点，因此不会锁死原生 DVFS。
static BOOL keyIsThermalThrottleProperty(NSString *key) {
if (!key || key.length == 0) return NO;
NSString *lower = [key lowercaseString];
if (keyIsDisplayLifecycleProperty(key)) return NO;

// Floor/Minimum 属于性能下限而非热降频上限，不能拦截。
if ([lower containsString:S("floor")]) return NO;

// 明确的温控缓解关键词 — 无条件拦截
if ([lower containsString:S("throttle")]) return YES;
if ([lower containsString:S("mitigation")]) return YES;
// 低电量模式会明显压低 CPU 上限，属于“降性能”来源，直接拦
if ([lower containsString:S("lowpower")] || [lower containsString:S("low-power")]) return YES;
if ([lower isEqualToString:S("lpm")] || [lower hasSuffix:S("lpm")]) return YES;

BOOL mentionsCPU = [lower containsString:S("cpu")] ||
[lower containsString:S("core")] ||
[lower containsString:S("ppm")] ||
[lower containsString:S("processor")];
BOOL mentionsGPU = [lower containsString:S("gpu")];
BOOL mentionsPackage = [lower containsString:S("package")] ||
[lower containsString:S("component")];
BOOL mentionsThermal = [lower containsString:S("thermal")];
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

BOOL protectedComponent = mentionsCPU || mentionsGPU || mentionsPackage || mentionsThermal;
if (protectedComponent) {
// 日常解除温控只保护 CPU；高性能模式额外保护 GPU 与 Package 功率墙。
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
    id original = [source objectForKey:key];
    id replacement = backlightReplacementMatchingValue(key, original);
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

// 每个 selector 只由这一运行时安装器拥有；不再与 Logos 重复安装。
static pthread_mutex_t g_thermalABIInstallLock = PTHREAD_MUTEX_INITIALIZER;
typedef struct {
    const char *className;
    const char *selectorName;
    const char *returnType;
    const char *argument1;
    const char *argument2;
    IMP replacement;
    IMP *original;
} CPUthermalABIHook;

// 每种完整 ABI 独立保存原 IMP；禁用保护时仍按真实 ABI 透传。
#define CT_VOID0(NAME, CORRECT) \
static IMP NAME##_original = NULL; \
static void NAME(id self, SEL cmd) { \
    if (shouldApplyFullCPUProtection()) { if (CORRECT) correctNominalStateIfNeeded(); return; } \
    ((void (*)(id, SEL))NAME##_original)(self, cmd); \
}
#define CT_RELEASE(NAME, RETURN, ARG) \
static IMP NAME##_original = NULL; \
static RETURN NAME(id self, SEL cmd, ARG component) { \
    if (shouldApplyFullCPUProtection()) return (RETURN)0; \
    return ((RETURN (*)(id, SEL, ARG))NAME##_original)(self, cmd, component); \
}
#define CT_EFFORT(NAME, RETURN, ARG) \
static IMP NAME##_original = NULL; \
static RETURN NAME(id self, SEL cmd, ARG effort, ARG trigger) { \
    if (shouldApplyFullCPUProtection()) return (RETURN)0; \
    return ((RETURN (*)(id, SEL, ARG, ARG))NAME##_original)(self, cmd, effort, trigger); \
}
#define CT_CPMS(NAME, ARG) \
static IMP NAME##_original = NULL; \
static void NAME(id self, SEL cmd, ARG state) { \
    ((void (*)(id, SEL, ARG))NAME##_original)(self, cmd, \
        shouldApplyFullCPUProtection() ? (ARG)0 : state); \
}
#define CT_NOTIFICATION(NAME, ARG) \
static IMP NAME##_original = NULL; \
static void NAME(id self, SEL cmd, ARG notification) { \
    if (shouldApplyFullCPUProtection()) return; \
    ((void (*)(id, SEL, ARG))NAME##_original)(self, cmd, notification); \
}

CT_VOID0(ctTreeEvaluate, YES)
CT_VOID0(ctTreeAction, NO)
CT_VOID0(ctTreeReadSingular, NO)
#define CT_RELEASE_VARIANTS(PREFIX) \
CT_RELEASE(PREFIX##FO, float, id) CT_RELEASE(PREFIX##DO, double, id) \
CT_RELEASE(PREFIX##FQ, float, uint64_t) CT_RELEASE(PREFIX##DQ, double, uint64_t) \
CT_RELEASE(PREFIX##Fq, float, int64_t) CT_RELEASE(PREFIX##Dq, double, int64_t) \
CT_RELEASE(PREFIX##FI, float, unsigned int) CT_RELEASE(PREFIX##DI, double, unsigned int) \
CT_RELEASE(PREFIX##Fi, float, int) CT_RELEASE(PREFIX##Di, double, int) \
CT_RELEASE(PREFIX##FP, float, void *) CT_RELEASE(PREFIX##DP, double, void *)
CT_RELEASE_VARIANTS(ctTreeRelease)
CT_RELEASE_VARIANTS(ctManagerRelease)
#define CT_EFFORT_VARIANTS(PREFIX) \
CT_EFFORT(PREFIX##FO, float, id) CT_EFFORT(PREFIX##DO, double, id) \
CT_EFFORT(PREFIX##FQ, float, uint64_t) CT_EFFORT(PREFIX##DQ, double, uint64_t) \
CT_EFFORT(PREFIX##Fq, float, int64_t) CT_EFFORT(PREFIX##Dq, double, int64_t) \
CT_EFFORT(PREFIX##FI, float, unsigned int) CT_EFFORT(PREFIX##DI, double, unsigned int) \
CT_EFFORT(PREFIX##Fi, float, int) CT_EFFORT(PREFIX##Di, double, int) \
CT_EFFORT(PREFIX##FP, float, void *) CT_EFFORT(PREFIX##DP, double, void *)
CT_EFFORT_VARIANTS(ctSupervisorEffort)
CT_EFFORT_VARIANTS(ctControlEffort)
CT_CPMS(ctComponentCPMSi, int)
CT_CPMS(ctComponentCPMSI, unsigned int)
CT_CPMS(ctComponentCPMSq, int64_t)
CT_CPMS(ctComponentCPMSQ, uint64_t)
CT_NOTIFICATION(ctNotificationO, id)
CT_NOTIFICATION(ctNotificationi, int)
CT_NOTIFICATION(ctNotificationI, unsigned int)

#define CT_ENTRY(CLS, SELNAME, RET, A1, A2, NAME) \
{ CLS, SELNAME, RET, A1, A2, (IMP)NAME, &NAME##_original }
#define CT_RELEASE_ENTRIES(CLS, PREFIX) \
CT_ENTRY(CLS,"getReleaseRateForComponent:","f","@",NULL,PREFIX##FO), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","d","@",NULL,PREFIX##DO), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","f","Q",NULL,PREFIX##FQ), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","d","Q",NULL,PREFIX##DQ), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","f","q",NULL,PREFIX##Fq), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","d","q",NULL,PREFIX##Dq), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","f","I",NULL,PREFIX##FI), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","d","I",NULL,PREFIX##DI), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","f","i",NULL,PREFIX##Fi), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","d","i",NULL,PREFIX##Di), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","f","^v",NULL,PREFIX##FP), \
CT_ENTRY(CLS,"getReleaseRateForComponent:","d","^v",NULL,PREFIX##DP)
#define CT_EFFORT_ENTRIES(CLS, PREFIX) \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","f","@","@",PREFIX##FO), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","d","@","@",PREFIX##DO), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","f","Q","Q",PREFIX##FQ), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","d","Q","Q",PREFIX##DQ), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","f","q","q",PREFIX##Fq), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","d","q","q",PREFIX##Dq), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","f","I","I",PREFIX##FI), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","d","I","I",PREFIX##DI), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","f","i","i",PREFIX##Fi), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","d","i","i",PREFIX##Di), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","f","^v","^v",PREFIX##FP), \
CT_ENTRY(CLS,"calculateControlEffort:trigger:","d","^v","^v",PREFIX##DP)

static CPUthermalABIHook g_thermalABIHooks[] = {
    CT_ENTRY("TableDrivenDecisionTree","evaluateDecisionTree","v",NULL,NULL,ctTreeEvaluate),
    CT_ENTRY("TableDrivenDecisionTree","actionComponentControl","v",NULL,NULL,ctTreeAction),
    CT_ENTRY("TableDrivenDecisionTree","readReleaseRateForAllComponents","v",NULL,NULL,ctTreeReadSingular),
    CT_RELEASE_ENTRIES("TableDrivenDecisionTree",ctTreeRelease),
    CT_RELEASE_ENTRIES("ThermalManager",ctManagerRelease),
    CT_EFFORT_ENTRIES("SupervisorControl",ctSupervisorEffort),
    CT_EFFORT_ENTRIES("ThermalControl",ctControlEffort),
    CT_ENTRY("ComponentControl","setCPMSMitigationState:","v","i",NULL,ctComponentCPMSi),
    CT_ENTRY("ComponentControl","setCPMSMitigationState:","v","I",NULL,ctComponentCPMSI),
    CT_ENTRY("ComponentControl","setCPMSMitigationState:","v","q",NULL,ctComponentCPMSq),
    CT_ENTRY("ComponentControl","setCPMSMitigationState:","v","Q",NULL,ctComponentCPMSQ),
    CT_ENTRY("NotificationManager","updateThermalNotification:","v","@",NULL,ctNotificationO),
    CT_ENTRY("NotificationManager","updateThermalNotification:","v","i",NULL,ctNotificationi),
    CT_ENTRY("NotificationManager","updateThermalNotification:","v","I",NULL,ctNotificationI)
};

// 比较完整类型，不把对象、整数、任意指针混作 uintptr_t。
static BOOL CPUthermalABITypeMatches(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    while (*actual && strchr("rnNoORV", *actual)) actual++;
    return strcmp(actual, expected) == 0;
}
static BOOL CPUthermalABIMethodMatches(Method method, CPUthermalABIHook *hook) {
    unsigned int count = hook->argument2 ? 4 : (hook->argument1 ? 3 : 2);
    if (!method || method_getNumberOfArguments(method) != count) return NO;
    char type[256] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (!CPUthermalABITypeMatches(type, hook->returnType)) return NO;
    method_getArgumentType(method, 0, type, sizeof(type));
    if (!CPUthermalABITypeMatches(type, "@")) return NO;
    method_getArgumentType(method, 1, type, sizeof(type));
    if (!CPUthermalABITypeMatches(type, ":")) return NO;
    if (hook->argument1) {
        method_getArgumentType(method, 2, type, sizeof(type));
        if (!CPUthermalABITypeMatches(type, hook->argument1)) return NO;
    }
    if (hook->argument2) {
        method_getArgumentType(method, 3, type, sizeof(type));
        if (!CPUthermalABITypeMatches(type, hook->argument2)) return NO;
    }
    return YES;
}
static void installCrossVersionThermalAliases(void) {
    pthread_mutex_lock(&g_thermalABIInstallLock);
    size_t count = sizeof(g_thermalABIHooks) / sizeof(g_thermalABIHooks[0]);
    for (size_t i = 0; i < count; i++) {
        CPUthermalABIHook *hook = &g_thermalABIHooks[i];
        // 同一 class/selector 的所有 ABI 候选共用“已安装”判定。
        BOOL installed = NO;
        for (size_t j = 0; j < count; j++) {
            CPUthermalABIHook *other = &g_thermalABIHooks[j];
            if (!strcmp(hook->className, other->className) &&
                !strcmp(hook->selectorName, other->selectorName) && *other->original) {
                installed = YES; break;
            }
        }
        if (installed) continue;
        Class cls = objc_getClass(hook->className);
        SEL sel = sel_registerName(hook->selectorName);
        Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (!CPUthermalABIMethodMatches(method, hook)) continue;
        MSHookMessageEx(cls, sel, hook->replacement, hook->original);
    }
    pthread_mutex_unlock(&g_thermalABIInstallLock);
}
#undef CT_VOID0
#undef CT_RELEASE
#undef CT_EFFORT
#undef CT_CPMS
#undef CT_NOTIFICATION
#undef CT_RELEASE_VARIANTS
#undef CT_EFFORT_VARIANTS
#undef CT_ENTRY
#undef CT_RELEASE_ENTRIES
#undef CT_EFFORT_ENTRIES




static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

static void cleanupRemovedFeaturePrefs(void) {
NSMutableDictionary *prefs=CPUthermalReadMutablePrefs(); if(!prefs)return;
BOOL changed=NO;   // 注意：绝不回写 powerMode，否则用户所选运行方式会在每次重启后被重置
for(NSString *key in @[S("highPerformanceModeEnabled"),S("forceFastChargeEnabled"),S("killThermalStopCharging"),S("lowPowerApps"),S("hipLockedMode"),S("refreshThermalProtectionEnabled")]){
    if(prefs[key]!=nil){[prefs removeObjectForKey:key];changed=YES;}
}
if(changed)CPUthermalWritePrefs(prefs);
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
// 关键修复：读取失败时立即返回，保留当前内存中正确的 g_powerMode，防止回退到解除温控
if (!d || d.count == 0) return;

BOOL enabled = YES;
// 屏蔽高温温度计警告：恒开，不再读取偏好（面板已移除该项）
BOOL blockPopup = YES;
// 防温控暗屏：**恒开**（面板已移除开关）。此前该键缺失/为 false 时整套防降亮度保护
// 会静默失效，实测表现为高温照常降亮度且 DisplayGuard 零拦截。
BOOL preventDimming = YES;
os_unfair_lock_lock(&g_stateLock);
g_enabled = enabled;
g_thermalBlockNotifPopup = blockPopup;
g_thermalPreventDimmingEnabled = preventDimming;
os_unfair_lock_unlock(&g_stateLock);

// 运行方式解析：**键缺失时必须保持当前模式**，绝不能默认回退到解除温控
// （实测 powerMode 被其它进程写掉后，回溯到 Full 会导致“界面低功耗、频率却满血”）。
id rawRunMode = d[S("powerMode")] ?: d[S("thermalRunMode")];
os_unfair_lock_lock(&g_modeLock);
CPUthermalPowerMode currentMode = g_userSelectedPowerMode;
os_unfair_lock_unlock(&g_modeLock);
CPUthermalPowerMode userMode = currentMode;
if ([rawRunMode isKindOfClass:[NSString class]]) {
    userMode = [rawRunMode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
} else {

    NSMutableDictionary *repair = [d mutableCopy];
    repair[S("powerMode")] = (currentMode == CPUthermalPowerModeLow) ? S("lowPower") : S("fullPower");
    CPUthermalWritePrefs(repair);   // 自愈：把当前模式写回偏好
}
os_unfair_lock_lock(&g_modeLock);
g_userSelectedPowerMode = userMode;
g_powerMode = userMode;
os_unfair_lock_unlock(&g_modeLock);
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



%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
if (connection == MACH_PORT_NULL) return %orig;
return %orig;
}

// 不安装纯透传异步调用 hook：系统 IOConnectCallAsyncMethod 为 12 参数 ABI。
// 异步调用保留系统原函数，避免旧 9 参数包装破坏标量/结构体参数。

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

if (isNetworkThrottleProperty(key)) {
return KERN_SUCCESS;
}

NSString *keyString = (__bridge NSString *)key;
if (thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(keyString)) {
    id replacement = nil;
    if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID()) {
        replacement = backlightReplacementMatchingValue(keyString, (__bridge id)value);
    }
    kern_return_t result = replacement ? orig_IOServiceSetProperty(service, key, (__bridge CFTypeRef)replacement) : orig_IOServiceSetProperty(service, key, value);
    CPUthermalRecommitUserBrightnessSoon();
    return result;
}
if (shouldApplyFullCPUProtection() && keyIsThermalThrottleProperty(keyString)) {

return KERN_SUCCESS;
}
return orig_IOServiceSetProperty(service, key, value);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
if (entry == MACH_PORT_NULL || !key || !value) return %orig(entry, key, value);
if (!runtimeEnabled() || g_restoringFullPower) return %orig(entry, key, value);
if (isNetworkThrottleProperty(key)) return KERN_SUCCESS;
NSString *keyString = (__bridge NSString *)key;
if (thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(keyString)) {
    id replacement = nil;
    if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID()) {
        replacement = backlightReplacementMatchingValue(keyString, (__bridge id)value);
    }
    kern_return_t result;
    if (replacement) result = %orig(entry, key, (__bridge CFTypeRef)replacement);
    else result = %orig(entry, key, value);
    CPUthermalRecommitUserBrightnessSoon();
    return result;
}
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
static BOOL CPUthermalIsThermalServiceKey(NSString *key);

%hook CommonProduct

// 热压写入 IOKit/SMC — 解除温控下丢弃热相关键
- (BOOL)setServiceProperty:(uintptr_t)service key:(id)key value:(uintptr_t)value scaleToFixedPoint:(BOOL)scale {
if (shouldApplyFullCPUProtection() && CPUthermalIsThermalServiceKey(key)) {

return NO;
}
return %orig(service, key, value, scale);
}


// 温度 getter 保留原生：未确认返回 ABI 和单位，禁止 int/float 位模式伪装。

// 轻度热压力 — 解除温控下强制 NO
- (BOOL)shouldEnforceLightThermalPressure {
if (shouldApplyFullCPUProtection()) return NO;
return %orig;
}

// 强制热级别 / 强制热压力级别 — 解除温控下归 0
- (int)getPotentialForcedThermalLevel:(uintptr_t)component {
if (shouldApplyFullCPUProtection()) return 0;
return %orig(component);
}

- (int)getPotentialForcedThermalPressureLevel {
if (shouldApplyFullCPUProtection()) return 0;
return %orig;
}

- (id)initProduct:(uintptr_t)arg1 {
id res = %orig;
if (res && runtimeEnabled()) {
static dispatch_once_t aliasOnce;
dispatch_once(&aliasOnce, ^{
    dispatch_async(CPUthermalEngineQueue(), ^{ installCrossVersionThermalAliases(); });
});
setCommonProduct((CommonProduct *)res);
// 不再调用 putDeviceInThermalSimulationMode:（私有 API、字符串参数语义不明，
// 曾使守护进入被压低的模拟热档，进而把 CPU 频率压低且不随卸载恢复）
dispatch_async(CPUthermalEngineQueue(), ^{ applyCurrentPowerModeToRuntime(); });

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

// 低功耗开启 CPU CPMS 使 Level2/预算落硬件；解除温控关闭 CPMS。
- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
if (g_restoringFullPower) {
%orig(enabled);
return; }
if (shouldApplyLowPowerLimit()) {
%orig(YES);
return; }
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return; }
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

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
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

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(floor, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPerformancePercent, source);
return;
}
%orig(floor, source);
}

- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
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

- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
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

%end

// --- HidSensors: HID 温度事件处理（与「屏蔽高温温度计警告」共用开关）---
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(uintptr_t)arg2 {
if (thermalPopupBlockingEnabled()) {
correctNominalStateIfNeeded();
return;
}
%orig(arg1, arg2);
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层）
//
// 冲突避免说明:
//   - 传感器读数 dieTempFilteredMaxAverage → 2600、getHighestSkinTemp → 0
//     已在 ThermalControl 内按解除温控归一，避免 die 温真实值驱动决策树触发降频
//   - thermalSensorValuesMaxFromIndexSet: 与 copyDieTempSensorIndexSetForFourthChar:sensors:
//     返回值 ABI 在版本间存在 float/int 差异，保持原生实现，交由上面两个读数与 setServiceProperty 兜底
//   - putDeviceInThermalSimulationMode: 不 hook (CPUthermal 自已调用会递归)
//   - setCPMSMitigationState: 直接在决策层拦截，避免进入 CPMS 写路径
//   - setServiceProperty:key:value:scaleToFixedPoint: 仅丢弃热相关键，普通属性照常写入
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
- (void)updateThermalPressureLevelNotification:(int)notification shouldForceThermalPressure:(BOOL)force {
if (thermalPopupBlockingEnabled()) {
correctNominalStateIfNeeded();
return;
}
%orig(notification, force);
}

// 热通知 — 受 thermalBlockNotifPopup 开关控制
- (void)updateThermalNotification:(int)notification {
@autoreleasepool {
if (thermalPopupBlockingEnabled()) {
return;
}
}
%orig;
}

// 是否应执行轻度热压力 — 解除温控下强制 NO
- (BOOL)shouldEnforceLightThermalPressure {
if (shouldApplyFullCPUProtection()) return NO;
return %orig;
}

// getReleaseRateForComponent: 由运行时 ABI 安装器独占。

// 获取强制热级别 — 解除温控下归 0，杜绝外部强制降频档位
- (int)getPotentialForcedThermalLevel:(uintptr_t)component {
if (shouldApplyFullCPUProtection()) return 0;
return %orig(component);
}

// 获取强制热压力级别 — 解除温控下归 0
- (int)getPotentialForcedThermalPressureLevel {
if (shouldApplyFullCPUProtection()) return 0;
return %orig;
}

// 散热/电池服务建议 — 不拦截
- (id)getBatteryServiceSuggestion:(uintptr_t)suggestion {
return %orig(suggestion);
}

%end

// --- ThermalControl: hook 控制力度计算 ---
// 判断服务属性键是否属于热管理通道；只有热相关键才在解除温控下被丢弃，其余照常写入。
static BOOL CPUthermalIsThermalServiceKey(NSString *key) {
if (![key isKindOfClass:[NSString class]]) return NO;
NSString *k = [key lowercaseString];
for (NSString *token in @[@"thermal", @"temperature", @"die", @"skin", @"pressure", @"throttle", @"mitigation", @"cpms", @"hippocket", @"pocket", @"powerzone", @"p-state", @"pstate"]) {
if ([k containsString:token]) return YES;
}
return NO;
}

%hook ThermalControl

// 温度 getter 保留原生：未确认返回 ABI 和单位；决策/write 钩子仍保留。

// 热压写入 IOKit/SMC — 解除温控下丢弃热相关键，避免热压下发到内核 CLPC/pmgr
- (BOOL)setServiceProperty:(uintptr_t)service key:(id)key value:(uintptr_t)value scaleToFixedPoint:(BOOL)scale {
if (shouldApplyFullCPUProtection() && CPUthermalIsThermalServiceKey(key)) {

return NO;
}
return %orig(service, key, value, scale);
}


- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(uintptr_t)saveParams powerZoneParams:(uintptr_t)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
dispatch_async(CPUthermalEngineQueue(), ^{ applyCurrentPowerModeToRuntime(); });
}
return res;
}

- (id)initWithParams:(uintptr_t)params {
id res = %orig(params);
if (res) {
trackPowerController(res);
dispatch_async(CPUthermalEngineQueue(), ^{ applyCurrentPowerModeToRuntime(); });
}
return res;
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) return %orig;
// 手动低功耗仅限 CPU，不向系统/显示层暴露全局 PowerSave。
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) return NO;
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
trackPowerController(self);
if (g_restoringFullPower) {
%orig(active);
return; }
if (shouldApplyLowPowerLimit()) {
%orig(NO);
return; }   // 只限制 CPU，不启用全局 PowerSave
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return; }
%orig(active);
}

- (void)setPowerSaveToken:(uintptr_t)token {
trackPowerController(self);
if (g_restoringFullPower) {
%orig(token);
return; }
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(0);
return; }
%orig(token);
}

// calculateControlEffort:trigger: 由运行时 ABI 安装器独占。

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
// 解除温控仍向原实现写 Level 0，清除历史 Level 2；不是吞掉清除请求。

%orig(kFullPowerCPULevel);
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

// --- ApplePPM: 与 ApplePPMCPU 同源的性能等级请求，一并拦截并记录 ---
%hook ApplePPM

- (void)setCPULevel:(int)level {
if (shouldApplyFullCPUProtection()) {

%orig(kFullPowerCPULevel);
return;
}
%orig(level);
}

%end

// --- MitigationController: 功率目标控制 ---
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(uintptr_t)saveParams powerZoneParams:(uintptr_t)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
dispatch_async(CPUthermalEngineQueue(), ^{ applyCurrentPowerModeToRuntime(); });
}
return res;
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
if (g_restoringFullPower) {
%orig(enabled);
return; }
if (shouldApplyLowPowerLimit()) {
%orig(YES);
return; }
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return; }
%orig(enabled);
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) return %orig;
// 全局节能标志与 CPU 专用预算隔离，两种模式均保持显示策略不变。
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) return NO;
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
trackPowerController(self);
if (g_restoringFullPower) {
%orig(active);
return; }
if (shouldApplyLowPowerLimit()) {
%orig(NO);
return; }   // 只限制 CPU，不启用全局 PowerSave
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return; }
%orig(active);
}

- (void)setPowerSaveToken:(int)token {
if (g_restoringFullPower) {
%orig(token);
return; }
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(0);
return; }
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
if (g_reassertingLowPower) {
%orig;
return; }   // 重断言期间的回调直接放行
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
%orig(kLowPowerPowerLimitMW);
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
return; }
// 两种用户模式都不允许 Package 低功耗联动；低功耗只由 CPU 专用 setter 实现。
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) return;
%orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
uintptr_t propertyArg = normalizedSetMaxCPUPowerPropertyArgument(self, property);
if (g_restoringFullPower) {
%orig(target, legacy, propertyArg);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(kLowPowerPowerLimitMW, NO, propertyArg);
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
%orig(kLowPowerPerformancePercent, source);
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
%orig(kLowPowerPerformancePercent, contributor);
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
%orig(0, source);
return;
}
if (shouldApplyFullCPUProtection()) {
// 解除温控要求 CPU Floor 与 Ceiling 均为 100，阻止用户态原生动态调频。
%orig(kUnrestrictedPerformancePercent, source);
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
%orig(kLowPowerPerformancePercent);
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

// 按 Insulation 结构恢复 backlightComponentControl 的无热限制档位。
// 递归求值：NSNumber / NSString / NSDictionary / NSArray 中的最大数值
static double CPUthermalMaximumNumericInValue(id value) {
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]])
        return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if ([value isKindOfClass:[NSDictionary class]]) {
        double best = 0.0;
        for (id child in [(NSDictionary *)value allValues]) {
            double v = CPUthermalMaximumNumericInValue(child);
            if (v > best) best = v;
        }
        return best;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        double best = 0.0;
        for (id child in (NSArray *)value) {
            double v = CPUthermalMaximumNumericInValue(child);
            if (v > best) best = v;
        }
        return best;
    }
    return 0.0;
}

// 取背光表中数值最高的那一档（旧实现取第一档，若第一档是最低亮度档，
// 会把整张表塌成最低亮度 —— 这正是屏幕被锁在 163.3 nits 的原因）。
static id CPUthermalMaximumElementOfBacklightArray(NSArray *source) {
    id best = nil;
    double bestValue = 0.0;
    for (id element in source) {
        double v = CPUthermalMaximumNumericInValue(element);
        if (v > bestValue) { bestValue = v; best = element; }
    }
    return best;
}

// 填充背光表时使用的目标值：优先用本机已发现的真实亮度上限（nits 空间），
// 避免“表内最高档”本身仍低于面板能力（例如表内最高只有 337，面板却支持 1060）。
static NSNumber *CPUthermalBacklightFillValue(void) {
    if (!g_maxBacklightBrightnessValue) CPUthermalCaptureExistingBacklightMaximum();
    if (g_maxBacklightBrightnessValue &&
        [g_maxBacklightBrightnessValue doubleValue] >= kCPUthermalMinimumPlausibleBacklightLimit)
        return g_maxBacklightBrightnessValue;
    return nil;
}

static NSMutableArray *CPUthermalMaximizeBacklightArray(NSArray *source) {
    if (![source isKindOfClass:[NSArray class]] || source.count == 0) return nil;
    id best = CPUthermalMaximumElementOfBacklightArray(source);
    if (!best) return nil;
    double bestValue = CPUthermalMaximumNumericInValue(best);
    id replacement = [best copy];
    // 数值型表：若已知真实上限高于表内最高档，直接用真实上限。
    // 字典型表（{level,down,up}）保持结构，只整体抬到最高档。
    NSNumber *fill = CPUthermalBacklightFillValue();
    if (fill && [best isKindOfClass:[NSNumber class]] && [fill doubleValue] > bestValue)
        replacement = [fill copy];
    // 表内最高档也参与“原生上限”学习（低于 400 nits 会被过滤掉）。
    if (bestValue > 0.0) CPUthermalRememberBacklightMaximum(@(bestValue));
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:source.count];
    for (NSUInteger i = 0; i < source.count; i++) [result addObject:replacement];
    return result;
}

static BOOL CPUthermalIsDisplayMitigationKey(NSString *key);
static id CPUthermalZeroDisplayMitigationValue(id original);

static void CPUthermalPatchBacklightControl(NSMutableDictionary *backlight) {
    if (![backlight isKindOfClass:[NSMutableDictionary class]]) return;
    NSArray *brightness = [backlight[S("BacklightBrightness")] isKindOfClass:[NSArray class]]
        ? backlight[S("BacklightBrightness")] : nil;
    NSMutableArray *brightnessPatched = CPUthermalMaximizeBacklightArray(brightness);
    if (brightnessPatched) {
        backlight[S("BacklightBrightness")] = brightnessPatched;
        // 只允许抬高观测到的原生上限，绝不允许被表内低档位覆盖（旧实现直接赋值，
        // 会把 1060 改写成 163.3，随后被写进 DCP 亮度限制节点锁死屏幕）。
        double peak = CPUthermalMaximumNumericInValue(brightnessPatched.firstObject);
        if (peak > 0.0) CPUthermalRememberBacklightMaximum(@(peak));
    }
    NSArray *power = [backlight[S("BacklightPower")] isKindOfClass:[NSArray class]]
        ? backlight[S("BacklightPower")] : nil;
    // BacklightPower 是功耗表，不是 nits；保留其原生最大档，不注入亮度数值。
    if (power.count > 0) {
        id bestPower = CPUthermalMaximumElementOfBacklightArray(power);
        if (bestPower) {
            NSMutableArray *powerPatched = [NSMutableArray arrayWithCapacity:power.count];
            for (NSUInteger index = 0; index < power.count; index++) [powerPatched addObject:[bestPower copy]];
            backlight[S("BacklightPower")] = powerPatched;
        }
    }
    backlight[S("expectsCPMSSupport")] = [NSNumber numberWithBool:NO];
    backlight[S("maxThermalPower")] = [NSNumber numberWithInt:kUnrestrictedPowerLimitMW];
    backlight[S("minThermalPower")] = [NSNumber numberWithInt:kUnrestrictedPowerLimitMW];
    for(id rawKey in [backlight.allKeys copy]) if([rawKey isKindOfClass:[NSString class]] && CPUthermalIsDisplayMitigationKey(rawKey))
        backlight[rawKey]=CPUthermalZeroDisplayMitigationValue(backlight[rawKey]);
    CPUthermalScheduleBacklightRecovery();
}

static BOOL CPUthermalIsDisplayMitigationKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    const char *keys[]={"needsPushingTSFDtoDisplayDriver","displayBrightnessMitigation","displayMitigation","eventDimmingEnabled","needsContextualClamp","shouldEnforceLightThermalPressure","shouldEnforceThermalPressure","thermalPressureMitigation","performanceMitigation",NULL};
    for(int i=0;keys[i];i++)if([key caseInsensitiveCompare:S(keys[i])]==NSOrderedSame)return YES;
    return NO;
}

static id CPUthermalZeroDisplayMitigationValue(id original) {
    if ([original isKindOfClass:[NSString class]]) return S("0");
    if ([original isKindOfClass:[NSNumber class]]) return [NSNumber numberWithInt:0];
    return original;
}

static id CPUthermalPatchBacklightNode(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [(NSDictionary *)node mutableCopy];
        for (id rawKey in [(NSDictionary *)node allKeys]) {
            id value = [(NSDictionary *)node objectForKey:rawKey];
            if ([rawKey isKindOfClass:[NSString class]] && CPUthermalIsDisplayMitigationKey(rawKey)) {
                result[rawKey]=CPUthermalZeroDisplayMitigationValue(value);
                continue;
            }
            if ([rawKey isKindOfClass:[NSString class]] &&
                [(NSString *)rawKey caseInsensitiveCompare:S("backlightComponentControl")] == NSOrderedSame &&
                [value isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *backlight = [value mutableCopy];
                CPUthermalPatchBacklightControl(backlight);
                result[rawKey] = backlight;
            } else {
                result[rawKey] = CPUthermalPatchBacklightNode(value) ?: value;
            }
        }
        return result;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[node count]];
        for (id value in node) [result addObject:CPUthermalPatchBacklightNode(value) ?: value];
        return result;
    }
    return node;
}


// 配置只负责显示防热暗屏；CPU 低功耗不再按关键词递归缩放数值。
// 布尔标志、source/id、release rates 与 Package 配置保持原始类型/语义。
static NSDictionary *patchThermalPlist(NSDictionary *dict) {
    BOOL dimming = thermalDimmingPreventionEnabled();
    if (![dict isKindOfClass:[NSDictionary class]] || !dimming) return dict;
    // DeviceMonitor 的 _getConfigurationFor 可能直接返回 backlightComponentControl 子字典。
    if ([dict[S("BacklightBrightness")] isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *direct = [dict mutableCopy];
        CPUthermalPatchBacklightControl(direct);
        return direct;
    }
    id patched = CPUthermalPatchBacklightNode(dict);
    return [patched isKindOfClass:[NSDictionary class]] ? patched : dict;
}

// ============================================================================
// %hook: NSDictionary — 拦截热配置 plist 加载，应用防暗屏补丁
// ============================================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
id res = %orig(path);
if ((thermalDimmingPreventionEnabled() || isLowPowerMode()) &&
    [path isKindOfClass:[NSString class]] && [path containsString:S("/System/Library/ThermalMonitor")]) {
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
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
executePuppetEvent();
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
BOOL wasEnabled = runtimeEnabled();
loadPrefs();
BOOL enabled = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL, NULL);
if (enabled) applyPowerModeToRuntime(NO);
else if (wasEnabled) restoreNativeRuntimeAfterDisable();
// 设置仅应用运行时状态，不自动终止 thermalmonitord。

};
dispatch_async(CPUthermalEngineQueue(), block);
}

// ============================================================================
// 配置级入口（真正的根因修复）
//   thermalmonitord 通过 -[ThermalManager getConfigurationFor:] 取回各组件热配置，
//   其中 backlightComponentControl 决定屏幕亮度表与显示缓解行为。
//   旧版误以为该函数位于 Apple 的 DeviceMonitor.framework（C 函数 _getConfigurationFor），
//   实际根本不存在 —— 导致整段配置级补丁（含防温控暗屏）从未生效，
//   屏幕被系统按热配置压到 163.3 nits 也无人复位。
//   0xash 的 DeviceMonitor 引擎正是用 method_exchangeImplementations 替换
//   ThermalManager - getConfigurationFor: 来原地替换整份热配置。
// ============================================================================
%hook ThermalManager

- (id)getConfigurationFor:(NSString *)key {
id config = %orig(key);
if (!thermalDimmingPreventionEnabled()) return config;
@try { return patchThermalPlist(config); }
@catch (__unused NSException *e) { return config; }
}

%end

// ============================================================================
// 真实类名补充 — iOS 16 thermalmonitord 热压链（按 0xash DeviceMonitor 引擎
// 解出的类名表：LifetimeServoController / ArcController / CommonProduct /
// MitigationController / PackagePowerCC / TableDrivenDecisionTree /
// NotificationManager / SupervisorControl / ComponentControl / XPidComponent）
// 处理器名不同版本存在差异，这里对真实类名再挂一层，双保险。
// ============================================================================
@interface TableDrivenDecisionTree : NSObject
- (void)evaluateDecisionTree;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (double)getReleaseRateForComponent:(uintptr_t)component;
- (id)findCC:(id)arg;
- (id)initDecisionTable:(id)table;
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
@end

@interface NotificationManager : NSObject
- (void)updateThermalNotification:(int)notification;
- (void)updateThermalPressureLevelNotification:(int)notification shouldForceThermalPressure:(BOOL)force;
@end

@interface SupervisorControl : NSObject
- (double)calculateControlEffort:(uintptr_t)effort trigger:(uintptr_t)trigger;
@end

@interface ComponentControl : NSObject
- (void)updatePowerParameters:(uintptr_t)params;
- (void)updatePackage;
- (void)setPackageLowPowerTarget;
- (void)setCPMSMitigationState:(int)state;
- (BOOL)powerSaveActive;
- (BOOL)setServiceProperty:(uintptr_t)service key:(id)key value:(uintptr_t)value scaleToFixedPoint:(BOOL)scale;
@end

// TableDrivenDecisionTree 与 SupervisorControl 已由运行时 ABI 安装器独占。
%hook NotificationManager

// 热压力级别通知 — 解除温控下不下发
- (void)updateThermalPressureLevelNotification:(int)notification shouldForceThermalPressure:(BOOL)force {
if (shouldApplyFullCPUProtection()) return;
%orig(notification, force);
}

%end

%hook ComponentControl

- (void)updatePowerParameters:(uintptr_t)params {
if (shouldApplyFullCPUProtection()) return;
%orig(params);
}

- (void)updatePackage {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (void)setPackageLowPowerTarget {
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) return;
%orig;
}

// setCPMSMitigationState: 由运行时 ABI 安装器独占。
- (BOOL)powerSaveActive {
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) return NO;
return %orig;
}

- (BOOL)setServiceProperty:(uintptr_t)service key:(id)key value:(uintptr_t)value scaleToFixedPoint:(BOOL)scale {
if (shouldApplyFullCPUProtection() && CPUthermalIsThermalServiceKey(key)) {

return NO;
}
return %orig(service, key, value, scale);
}

%end

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
// Legacy thermal probe hooks are intentionally absent.

cleanupRemovedFeaturePrefs();
loadPrefs();

// 确保 IOKit 已加载
void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
if (iokit) {
kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) = (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))dlsym(iokit, "IOServiceSetProperty");
if (ptr) {
MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
}
}

// _getConfigurationFor — C 函数钩子
void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
if (monitor) {
void *getConfig = dlsym(monitor, "_getConfigurationFor");
if (getConfig) {
MSHookFunction(getConfig, (void *)new_getConfigurationFor, (void **)&orig_getConfigurationFor);

} else {

}
} else {

}

// 仅解除温控模式伪造 Nominal；低功耗或禁用时保留系统真实状态。
if (shouldApplyFullCPUProtection()) CPUthermalForceNominalCombined();




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
}

installCrossVersionThermalAliases();
// iOS 15/16/17 私有类可能晚于构造函数加载；只进行4次有界补装。
for (int retry=1;retry<=4;retry++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(retry*0.75*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ installCrossVersionThermalAliases(); });

registerThermalLevelResetObservers();
registerScreenWakeObservers();
applyCurrentPowerModeToRuntime();

}
}
