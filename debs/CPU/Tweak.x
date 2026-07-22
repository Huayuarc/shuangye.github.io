#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <limits.h>
#import <os/lock.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>
#include <CPUthermalMonitor.h>
#import <IOKit/IOKitLib.h>

// ============================================================================
// CPUthermal — 温控插件（完全版）
//
// 双防护层设计:
//   第1层 (IOKit): 拦截传感器温度读取、降频操作、属性写入、Darwin 通知广播
//   第2层 (ObjC):  钩住 thermalmonitord 内部类决策方法，阻止热缓解动作
//
// 冲突避免原则:
//   - 传感器读数拦截只走 IOKit，不走 ObjC
//   - 不再主动调用热级别模拟接口，低功耗改用模拟热压力级别触发系统自然降频
//   - 所有新增 hook 有独立开关
//   - 保留系统紧急热保护安全阀 (100°C+，并始终放行紧急 selector)
//
// 注意: 禁止使用 @"" ObjC 字符串常量（roothide 重映射会破坏 __cfstring）
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================================

// ============================================================================
// ObjC 类声明（thermalmonitord 内部类，class-dump 获取）
// ============================================================================
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setThermalState:(id)state;
@end

@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)temperature service:(id)service;
@end

// ============================================================================
// 新增: 分析发现的额外类声明
// ============================================================================
@interface ThermalManager : NSObject
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
- (void)evaluateDecisionTree;
- (id)findComponent:(id)component;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (float)getReleaseRateForComponent:(id)component;
- (void)updateThermalNotification:(id)notification;
- (id)getBatteryServiceSuggestion:(id)suggestion;
@end

@interface ThermalControl : NSObject
- (id)findCC:(id)component;
- (float)dieTempFilteredMaxAverage;
- (float)getHighestSkinTemp;
- (float)thermalSensorValuesMaxFromIndexSet:(id)indexSet;
- (void)copyDieTempSensorIndexSetForFourthChar:(char)c sensors:(id)sensors;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
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
- (void)updatePackage;
- (void)setCPULowPowerTarget:(int)target;
- (void)setPackageLowPowerTarget;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(uintptr_t)contributor;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
- (void)updatePowerTarget;
- (void)calculateMitigation;
- (void)computePowerTarget;
- (void)setCPMSMitigationState:(int)state;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (BOOL)shouldSuppressMitigations;
@end

@interface TableDrivenLowTempController : NSObject
- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra;
@end

@interface FormulaDrivenLowTempController : NSObject
- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra;
@end

@interface FormulaDrivenLowTempController_CPU : FormulaDrivenLowTempController
@end

@interface ThermalDecisionTable : NSObject
- (id)initDecisionTable:(id)table;
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
static BOOL g_enabled               = NO;  // 总开关（默认关闭，安装后由用户手动启用）
static BOOL g_cpuProtection         = NO; // CPU 性能保护(降频/决策树/控制力度/配置表)
static BOOL g_brightnessProtection  = NO; // 屏幕亮度保护(降亮度/背光配置)
static BOOL g_suppressThermalNotifications = NO; // 默认屏蔽误触发高温通知

// ============================================================================
// 温控监控（移植自 Battman 温控等级: 热压/通知/重置）
// ============================================================================
static BOOL g_pressureMonitor       = NO; // 热压监控开关
static BOOL g_notificationMonitor   = NO; // 通知级别监控开关
static BOOL g_pressureOverrideEnabled = NO; // 热压覆盖开关
static int  g_pressureOverrideValue = 0;   // 热压覆盖值 (10/20/30/40/50)
static dispatch_source_t g_thermalMonitorTimer = NULL; // 温控监控定时器

// 最低安全频率（全功率恢复时钳位用）
static const int64_t kMinimumSafeCPUFrequencyMHz = 1428;

// 温度安全阀 — 超过此值不拦截任何保护
// 100°C 后优先交还系统温控，并始终放行 0x60-0x6F 紧急保护。
static const int64_t kSafetyTempThreshold = 100000;
static const int64_t kThermalThresholdRaise = 15000;

// 唤醒爆发恢复参数（使用 burst 写入，无需自适应定时器）

// A15 降频操作 selector 范围:
//   0x10-0x1F: 温度传感器读取
//   0x20-0x2F: 电源域状态查询（A15 新增）
//   0x30-0x5F: 降频/功率控制（含 A15 新增范围）
//   0x60-0x6F: 紧急保护 — 永不拦截
#define SELECTOR_IS_TEMP(s)        ((s) >= 0x10 && (s) <= 0x1F)
#define SELECTOR_IS_MITIGATION(s)  ((s) >= 0x20 && (s) <= 0x5F)
#define SELECTOR_IS_CRITICAL(s)    ((s) >= 0x60 && (s) <= 0x6F)

static CommonProduct *g_commonProduct = nil;
static NSMutableArray *g_mitigationControllers = nil;
static BOOL g_restoringFullPower = NO;
static NSMutableDictionary *g_originalControllerValues = nil;
static CFAbsoluteTime g_processStartTime = 0;
static const double kFullPowerBootGuardDuration = 1.0;
static BOOL g_deferredRuntimeApplyScheduled = NO;
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;

// 喚醒追蹤狀態
static volatile CFAbsoluteTime g_lastWakeTime = 0;
static BOOL g_wakeBurstInProgress = NO;

// ============================================================================
// 运行时维护定时器
// 定时补写满性能状态，防止系统唤醒/状态机覆盖。
// ============================================================================
static dispatch_source_t g_continuousTimer = NULL;
static const int64_t kContinuousTimerIntervalMs = 1500;

static void stopContinuousTimer(void);

// 前向声明
static BOOL fullPowerBootGuardActive(void);
static BOOL shouldApplyFullCPUProtection(void);
static void applyFullPowerToCommonProduct(void);
static void restoreFullPowerToTrackedControllers(void);
static void beginWakeRecovery(void);
static void loadPrefs(void);
__attribute__((unused)) static void scheduleDeferredRuntimeApply(double delay);
static NSDictionary *readPrefsDictionary(void);

static void startContinuousTimer(void) {
if (g_continuousTimer) return;
if (!g_enabled || !g_cpuProtection) return;

g_continuousTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
dispatch_source_set_timer(g_continuousTimer,
dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContinuousTimerIntervalMs * NSEC_PER_MSEC)),
(uint64_t)(kContinuousTimerIntervalMs * NSEC_PER_MSEC),
(uint64_t)(20 * NSEC_PER_MSEC));
dispatch_source_set_event_handler(g_continuousTimer, ^{
@autoreleasepool {
if (!g_enabled || !g_cpuProtection) {
stopContinuousTimer();
return;
}
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
}
}
});
dispatch_resume(g_continuousTimer);
NSLog(@"[CPUthermal] 性能维护定时器已启动 (间隔 %.1f 秒)", (double)kContinuousTimerIntervalMs / 1000.0);
}

static void stopContinuousTimer(void) {
if (g_continuousTimer) {
dispatch_source_cancel(g_continuousTimer);
g_continuousTimer = NULL;
NSLog(@"[CPUthermal] 性能维护定时器已停止");
}
}

// ============================================================================
// 温控监控定时器（移植自 Battman — 热压/通知级别读取日志）
// ============================================================================
static const int64_t kThermalMonitorIntervalMs = 3000; // 3 秒间隔

static void startThermalMonitorTimer(void);
static void stopThermalMonitorTimer(void);

static void startThermalMonitorTimer(void) {
if (g_thermalMonitorTimer) return;
if (!g_enabled) return;
if (!g_pressureMonitor && !g_notificationMonitor) return;

g_thermalMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
dispatch_source_set_timer(g_thermalMonitorTimer,
dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kThermalMonitorIntervalMs * NSEC_PER_MSEC)),
(uint64_t)(kThermalMonitorIntervalMs * NSEC_PER_MSEC),
(uint64_t)(50 * NSEC_PER_MSEC));
dispatch_source_set_event_handler(g_thermalMonitorTimer, ^{
@autoreleasepool {
if (!g_enabled) {
stopThermalMonitorTimer();
return;
}

if (g_pressureMonitor) {
CPUthermalPressureLevel pressure = CPUthermalPressure();
static CPUthermalPressureLevel lastPressure = kCPUthermalPressureError;
if (pressure != lastPressure) {
NSLog(@"[CPUthermalMonitor] 热压级别: %s (%d)",
CPUthermalPressureString(pressure), (int)pressure);
lastPressure = pressure;
}
}

if (g_notificationMonitor) {
CPUthermalNotifLevel notif = CPUthermalCurrentNotifLevel();
static CPUthermalNotifLevel lastNotif = kCPUthermalNotifNone;
if (notif != lastNotif) {
NSLog(@"[CPUthermalMonitor] 热通知级别: %s",
CPUthermalNotifLevelString(notif, true));
lastNotif = notif;
}
}
}
});
dispatch_resume(g_thermalMonitorTimer);
NSLog(@"[CPUthermal] 温控监控定时器已启动 (热压:%d 通知:%d 间隔:%lldms)",
g_pressureMonitor, g_notificationMonitor, kThermalMonitorIntervalMs);
}

static void stopThermalMonitorTimer(void) {
if (g_thermalMonitorTimer) {
dispatch_source_cancel(g_thermalMonitorTimer);
g_thermalMonitorTimer = NULL;
NSLog(@"[CPUthermal] 温控监控定时器已停止");
}
}

// ============================================================================
// 唤醒爆发恢复
// 设备唤醒后系统会重设CPU频率目标，通过多次爆发写入确保频率锁定不被覆盖。
// 时序: 0ms(同步) + 100ms + 300ms + 800ms + 1500ms
// ============================================================================
static void beginWakeRecovery(void) {
if (!g_enabled || !g_cpuProtection) return;
if (g_wakeBurstInProgress) return;
g_wakeBurstInProgress = YES;
g_lastWakeTime = CFAbsoluteTimeGetCurrent();

// 同步写入
dispatch_async(dispatch_get_main_queue(), ^{
@autoreleasepool {
loadPrefs();
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
}
});

// 爆发写入延迟序列
const double burstDelays[] = {0.1, 0.3, 0.8, 1.5};
for (size_t i = 0; i < sizeof(burstDelays)/sizeof(burstDelays[0]); i++) {
double delay = burstDelays[i];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
@autoreleasepool {
if (!g_enabled || !g_cpuProtection) return;
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
NSLog(@"[CPUthermal] 唤醒爆发写入 +%.1fs", delay);
}
}
});
}

dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
g_wakeBurstInProgress = NO;
});
}

static NSString *controllerKey(id controller, const char *name) {
return [NSString stringWithFormat:S("%p:%s"), controller, name];
}

static int rememberedOriginalIntValue(id controller, const char *name, int fallback) {
NSNumber *value = [g_originalControllerValues objectForKey:controllerKey(controller, name)];
return value ? [value intValue] : fallback;
}

static BOOL fullPowerBootGuardActive(void) {
if (g_processStartTime <= 0) return NO;
return (CFAbsoluteTimeGetCurrent() - g_processStartTime) < kFullPowerBootGuardDuration;
}

static BOOL shouldApplyFullCPUProtection(void) {
return g_enabled && g_cpuProtection && !fullPowerBootGuardActive();
}

static int fullPowerTargetValue(void) {
return 100;
}

static int fullPowerFrequencyValue(void) {
// 直接返回设备原生最高频率，不再使用 deviceLock
return (int)CPUthermalNativeMaxPCoreFrequencyMHz();
}

static int fullPowerPercentValue(void) {
return 100;
}

static int lowTempFullPowerOutputValue(void) {
return fullPowerPercentValue();
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
if (remembered > 0) return remembered;

int maxPower = intIvarValue(controller, "_maxCPUPower", 0);
if (maxPower > 0) return maxPower;

int realTarget = intIvarValue(controller, "_currentRealCPUPowerTarget", 0);
if (realTarget > 0) return realTarget;

return fullPowerFrequencyValue();
}

static int fullPowerCeilingForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "CPUPowerCeiling", fullPowerTargetValue());
return remembered > 0 ? remembered : fullPowerTargetValue();
}

static int fullPowerFloorForController(id controller) {
return rememberedOriginalIntValue(controller, "CPUPowerFloor", 0);
}

static int fullPowerZoneTargetForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "CPUPowerZoneTarget", 0);
if (remembered > 0) return remembered;
return fullPowerTargetForController(controller);
}

static void restoreFullPowerToController(id controller) {
if (!controller || !shouldApplyFullCPUProtection()) return;
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
NSLog(@"[CPUthermal] 已主动恢复解除温控功率上限 controller:%@", controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 恢复解除温控 CPU 上限失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void restoreFullPowerToTrackedControllers(void) {
if (!shouldApplyFullCPUProtection()) return;
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
if (!g_commonProduct || !shouldApplyFullCPUProtection()) return;
@try {
g_restoringFullPower = YES;
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), 0);
}
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), 0);
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), 0);
if ([g_commonProduct respondsToSelector:@selector(setThermalState:)]) {
((void (*)(id, SEL, id))objc_msgSend)(g_commonProduct, @selector(setThermalState:), [NSNumber numberWithInt:0]);
}
NSLog(@"[CPUthermal] 已主动套用解除温控 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用解除温控 CommonProduct 状态失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

__attribute__((unused)) static void scheduleDeferredRuntimeApply(double delay) {
if (g_deferredRuntimeApplyScheduled) return;
g_deferredRuntimeApplyScheduled = YES;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
g_deferredRuntimeApplyScheduled = NO;
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
}
});
}

static void scheduleWakeRuntimeApply(void) {
if (!g_enabled || !g_cpuProtection) return;
g_lastWakeTime = CFAbsoluteTimeGetCurrent();
dispatch_async(dispatch_get_main_queue(), ^{
loadPrefs();
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
beginWakeRecovery();
}
});
}

// ============================================================================
// 以下两个频率转换函数供全功率恢复安全钳位使用
// ============================================================================
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

static BOOL isThermalNotificationName(NSString *name) {
if (!name) return NO;
NSString *lower = [name lowercaseString];
return [lower containsString:S("thermalstate")] ||
[lower containsString:S("thermal-level")] ||
[lower containsString:S("osthermal")] ||
[lower containsString:S("kosthermalnotification")] ||
([lower containsString:S("thermal")] &&
([lower containsString:S("high")] ||
[lower containsString:S("pressure")] ||
[lower containsString:S("warning")] ||
[lower containsString:S("notification")]));
}

static BOOL shouldBlockBrightnessProperty(NSString *key, CFTypeRef value) {
if (!key) return NO;
NSString *lower = [key lowercaseString];
BOOL isBrightnessKey = [lower containsString:S("brightness")] || [lower containsString:S("backlight")];
if (!isBrightnessKey) return NO;
// 放行电源/显示状态关键操作
if ([lower containsString:S("displaystatus")] ||
[lower containsString:S("blank")] ||
[lower containsString:S("sleep")] ||
[lower containsString:S("wake")] ||
[lower containsString:S("powerstate")]) {
return NO;
}
// 放行 0 值（关机/息屏场景）
if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
double numericValue = 0;
if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &numericValue) && numericValue <= 0.01) {
return NO;
}
}
// 拦截所有 IOKit 层的亮度/背光写操作
// iOS 用户亮度调节通过 UIScreen/SpringBoard，不走 IOKit IOServiceSetProperty
// 所以拦截 IOKit 层亮度写操作不影响用户正常调节亮度
return YES;
}

static BOOL keyLooksChargingRelated(NSString *key) {
if (!key) return NO;
NSString *lower = [key lowercaseString];
return [lower containsString:S("charge")] ||
[lower containsString:S("charger")] ||
[lower containsString:S("charging")] ||
[lower containsString:S("battery")] ||
[lower containsString:S("batt")] ||
[lower containsString:S("adapter")] ||
[lower containsString:S("adaptor")] ||
[lower containsString:S("brick")] ||
[lower containsString:S("usb")] ||
[lower containsString:S("vbus")] ||
[lower containsString:S("pmu")] ||
[lower containsString:S("gasgauge")] ||
[lower containsString:S("gas gauge")];
}

static BOOL shouldBlockCPUProperty(NSString *key) {
if (!key || keyLooksChargingRelated(key)) return NO;
NSString *lower = [key lowercaseString];
BOOL isComputeKey = [lower containsString:S("cpu")] ||
[lower containsString:S("clpc")] ||
[lower containsString:S("ppm")] ||
[lower containsString:S("processor")] ||
[lower containsString:S("package")] ||
[lower containsString:S("perf")];
BOOL isMitigationKey = [lower containsString:S("thermal")] ||
[lower containsString:S("therm")] ||
[lower containsString:S("throttle")] ||
[lower containsString:S("mitigat")] ||
[lower containsString:S("freq")] ||
[lower containsString:S("frequency")] ||
[lower containsString:S("powerzone")] ||
[lower containsString:S("power-zone")] ||
[lower containsString:S("lowpower")] ||
[lower containsString:S("low-power")] ||
[lower containsString:S("power target")] ||
[lower containsString:S("power-target")] ||
[lower containsString:S("power_target")] ||
[lower containsString:S("level")];
return isComputeKey && isMitigationKey;
}

static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary() ?: [NSDictionary dictionary];
g_enabled               = [d[S("enabled")] ?: [NSNumber numberWithBool:NO] boolValue];
	g_cpuProtection         = [d[S("cpuProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
	g_brightnessProtection  = [d[S("brightnessProtection")] ?: [NSNumber numberWithBool:YES] boolValue];
	g_suppressThermalNotifications = [d[S("suppressThermalNotifications")] ?: [NSNumber numberWithBool:YES] boolValue];

	// 温控监控偏好（移植自 Battman）
	g_pressureMonitor       = [d[S(kCPUthermalPressureMonitorKeyC)] ?: [NSNumber numberWithBool:NO] boolValue];
	g_notificationMonitor   = [d[S(kCPUthermalNotificationMonitorKeyC)] ?: [NSNumber numberWithBool:NO] boolValue];
	g_pressureOverrideEnabled = [d[S(kCPUthermalPressureOverrideEnabledKeyC)] ?: [NSNumber numberWithBool:NO] boolValue];
	NSNumber *overrideVal   = d[S(kCPUthermalPressureOverrideKeyC)];
	g_pressureOverrideValue = overrideVal ? [overrideVal intValue] : 0;

	// 重置热通知请求
	BOOL resetNotifs = [d[S(kCPUthermalResetNotifKeyC)] ?: [NSNumber numberWithBool:NO] boolValue];
	if (resetNotifs) {
		int ret = CPUthermalResetNotifLevel();
		NSLog(@"[CPUthermal] 热通知级别重置请求: result=%d", ret);
	}

	// 热压覆盖
	if (g_enabled && g_pressureOverrideEnabled && g_pressureOverrideValue > 0) {
		CPUthermalPressureLevel pressure = (CPUthermalPressureLevel)g_pressureOverrideValue;
		int ret = CPUthermalSetPressure(pressure);
		NSLog(@"[CPUthermal] 热压覆盖: %s (%d) result=%d",
			CPUthermalPressureString(pressure), g_pressureOverrideValue, ret);
	} else if (g_enabled && !g_pressureOverrideEnabled && g_pressureOverrideValue > 0) {
		// 覆盖关闭但之前有残留值 — 重置为 Nominal
		CPUthermalResetPressure();
		NSLog(@"[CPUthermal] 热压覆盖已关闭，重置为 Nominal");
	}

// 管理温控监控定时器
if (g_enabled && (g_pressureMonitor || g_notificationMonitor)) {
	startThermalMonitorTimer();
} else {
	stopThermalMonitorTimer();
}
}
}


// ============================================================================
// IOKit connection 追踪 + 温度安全阀
// ============================================================================
static const char *g_hotServices[] = {
    "AppleSPU", "AppleSPU.original",
    "AppleARMPlatform",
    "pmu", "ApplePMGR",
    "AppleCLPC", "AppleCLPCv2",
    NULL
};

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

// 温度安全阀 — 超过 100°C 时放行所有保护
// 读取失败时不放行（NO），保持保护激活；同时检查多个温度源以确保安全
static BOOL isTemperatureAboveSafetyCeiling(void) {
    // 尝试从多个温度源读取，任何一个超过安全值则返回 YES
    const char *tempServices[] = {"AppleARMPlatform", NULL};

    for (int i = 0; tempServices[i]; i++) {
        CFMutableDictionaryRef matching = IOServiceMatching(tempServices[i]);
        if (!matching) continue;

        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
        if (!service) continue;

        CFStringRef tempKey = CFStringCreateWithCString(kCFAllocatorDefault, "temperature", kCFStringEncodingUTF8);
        CFTypeRef temp = tempKey ? IORegistryEntryCreateCFProperty(service, tempKey, kCFAllocatorDefault, 0) : NULL;
        if (tempKey) CFRelease(tempKey);
        IOObjectRelease(service);

        if (temp && CFGetTypeID(temp) == CFNumberGetTypeID()) {
            int64_t tempVal = 0;
            if (CFNumberGetValue((CFNumberRef)temp, kCFNumberSInt64Type, &tempVal)) {
                if (tempVal >= kSafetyTempThreshold) {
                    if (temp) CFRelease(temp);
                    NSLog(@"[CPUthermal] 温度安全阀触发: %.1f°C (源: %s)", (double)tempVal / 1000.0, tempServices[i]);
                    return YES;
                }
            }
        }
        if (temp) CFRelease(temp);
    }

    // 所有温度源均低于安全值，或读取失败（保持保护）
    return NO;
}

// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

NSString *ks = (__bridge NSString *)key;
if (g_cpuProtection && shouldBlockCPUProperty(ks)) {
// g_restoringFullPower 窗口期内放行高值恢复写入，但钳位最低频率防止归零
if (g_restoringFullPower && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
int64_t numVal = 0;
if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &numVal)) {
int64_t mhz = frequencyMHzFromValue(numVal);
if (mhz < kMinimumSafeCPUFrequencyMHz) {
int64_t safeValueNum = frequencyValueFromMHz(kMinimumSafeCPUFrequencyMHz, numVal);
CFTypeRef safeValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &safeValueNum);
kern_return_t ret = orig_IOServiceSetProperty(service, key, safeValue);
if (safeValue) CFRelease(safeValue);
return ret;
}
if (numVal > 0) {
return orig_IOServiceSetProperty(service, key, value);
}
}
return KERN_SUCCESS;
}
return KERN_SUCCESS;
}
if (g_brightnessProtection && shouldBlockBrightnessProperty(ks, value)) {
return KERN_SUCCESS;
}
return orig_IOServiceSetProperty(service, key, value);
}

// --- IOServiceSetProperties — 复数版本，系统可能通过此路径绕过单数 hook ---
static kern_return_t (*orig_IOServiceSetProperties)(io_service_t, CFDictionaryRef) = NULL;

static kern_return_t hooked_IOServiceSetProperties(io_service_t service, CFDictionaryRef properties) {
    if (!g_enabled) {
        return orig_IOServiceSetProperties(service, properties);
    }

    // 过滤字典中所有键值对
    CFIndex count = CFDictionaryGetCount(properties);
    if (count <= 0) {
        return orig_IOServiceSetProperties(service, properties);
    }

    // 快速判断是否有需要拦截的键
    CFStringRef keys[count];
    CFDictionaryGetKeysAndValues(properties, (const void **)keys, NULL);

    BOOL needsBlock = NO;
    BOOL needsFilter = NO;
    NSMutableDictionary *replacementDict = nil;

    for (CFIndex i = 0; i < count; i++) {
        NSString *ks = (__bridge NSString *)keys[i];
        if (!ks) continue;

        if (g_cpuProtection && shouldBlockCPUProperty(ks)) {
            // 恢复窗口: 放行高值写入，频率过低时钳位至最低安全值
            if (g_restoringFullPower) {
                CFTypeRef val = CFDictionaryGetValue(properties, keys[i]);
                if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
                    int64_t numVal = 0;
                    if (CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &numVal)) {
                        int64_t mhz = frequencyMHzFromValue(numVal);
                        if (mhz < kMinimumSafeCPUFrequencyMHz) {
                            // 钳位至最低安全频率
                            int64_t safeVal = frequencyValueFromMHz(kMinimumSafeCPUFrequencyMHz, numVal);
                            if (!replacementDict) {
                                replacementDict = [NSMutableDictionary dictionary];
                                for (CFIndex j = 0; j < count; j++) {
                                    NSString *ok = (__bridge NSString *)keys[j];
                                    if (ok && j != i) {
                                        CFTypeRef ov = CFDictionaryGetValue(properties, keys[j]);
                                        if (ov) replacementDict[ok] = (__bridge id)ov;
                                    }
                                }
                            }
                            replacementDict[ks] = [NSNumber numberWithLongLong:safeVal];
                            continue;
                        }
                        if (numVal > 0) {
                            continue; // 放行恢复写入
                        }
                    }
                }
            }
            needsBlock = YES; // 拦截降频写入
        }

        if (g_brightnessProtection && !needsBlock) {
            if (shouldBlockBrightnessProperty(ks, CFDictionaryGetValue(properties, keys[i]))) {
                needsBlock = YES;
            }
        }
    }

    if (needsBlock) {
        return KERN_SUCCESS;
    }

    if (needsFilter && replacementDict) {
        NSDictionary *replacementCopy = [replacementDict copy];
        return orig_IOServiceSetProperties(service, (__bridge CFDictionaryRef)replacementCopy);
    }

    return orig_IOServiceSetProperties(service, properties);
}

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

    // 恢复满功率期间 — 放行所有调用
    if (g_restoringFullPower) {
        return %orig;
    }

    // 紧急保护 — 任何情况都不拦截 (安全阀)
    if (SELECTOR_IS_CRITICAL(selector)) {
        return %orig;
    }

    // 超过安全阀温度时放行所有保护
    if (isTemperatureAboveSafetyCeiling()) {
        return %orig;
    }

    // 温度传感器读取拦截 — 返回 30°C，让 thermalmonitord 认为设备凉爽
    // 从根本上阻止其内部状态机进入高压热级别
    if (g_enabled && g_cpuProtection && SELECTOR_IS_TEMP(selector)) {
        if (output && outputCnt && *outputCnt > 0) {
            for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
                output[i] = 30000;  // 30°C (毫摄氏度)
            }
        }
        return KERN_SUCCESS;
    }

    // 解除温控模式下拦截所有降频/功率控制操作
    if (shouldApplyFullCPUProtection() && SELECTOR_IS_MITIGATION(selector)) {
        return KERN_SUCCESS;
    }
    return %orig;
}

// --- IOConnectCallAsyncMethod — 拦截非同步降频操作 ---
// thermalmonitord 可能通过异步 IOConnect 路径执行热缓解操作
%hookf(kern_return_t, IOConnectCallAsyncMethod, mach_port_t connection, uint32_t selector, mach_port_t wakePort, uint64_t *reference, uint32_t referenceCnt, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
if (!g_enabled || !isThermalConnection(connection)) {
return %orig;
}

// 恢复满功率期间 — 放行所有调用
if (g_restoringFullPower) {
return %orig;
}

// 紧急保护 — 任何情况都不拦截 (安全阀)
if (SELECTOR_IS_CRITICAL(selector)) {
return %orig;
}

// 超过安全阀温度时放行所有保护
if (isTemperatureAboveSafetyCeiling()) {
return %orig;
}

// 温度传感器读取拦截 — 返回 30°C
if (g_enabled && g_cpuProtection && SELECTOR_IS_TEMP(selector)) {
if (output && outputCnt && *outputCnt > 0) {
for (uint32_t i = 0; i < MIN(*outputCnt, 4); i++) {
output[i] = 30000;
}
}
return KERN_SUCCESS;
}

// 拦截降频/功率控制操作
if (shouldApplyFullCPUProtection() && SELECTOR_IS_MITIGATION(selector)) {
return KERN_SUCCESS;
}
return %orig;
}

// --- notify_post — 拦截高温广播 ---
%hookf(uint32_t, notify_post, const char *name) {
if (g_enabled && g_suppressThermalNotifications && name) {
// 动态创建 NSString 避免 roothide __cfstring 损坏
NSString *ns = [NSString stringWithUTF8String:name];
if (isThermalNotificationName(ns)) {
return NOTIFY_STATUS_OK;
}
}
return %orig;
}

// --- IORegistryEntryCreateCFProperty — 返回假温度/频率/亮度值 ---
// 第2层温度欺骗: 拦截 IOKit 属性读取，确保所有路径都返回假低温
%hookf(CFTypeRef, IORegistryEntryCreateCFProperty, io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
if (!g_enabled || !g_cpuProtection) return %orig;

// 安全阀
if (isTemperatureAboveSafetyCeiling()) return %orig;

// 恢复满功率期间 — 放行
if (g_restoringFullPower) return %orig;

// 始终拦截温度读取，返回假低温
NSString *ks = (__bridge NSString *)key;
if ([ks localizedCaseInsensitiveContainsString:S("temperature")] ||
[ks localizedCaseInsensitiveContainsString:S("thermal-level")] ||
[ks localizedCaseInsensitiveContainsString:S("hot-level")] ||
[ks localizedCaseInsensitiveContainsString:S("thermalstate")]) {
int zero = 0;
return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
}

// 亮度保护
if (g_brightnessProtection && (
[ks localizedCaseInsensitiveContainsString:S("brightness")] ||
[ks localizedCaseInsensitiveContainsString:S("backlight")])) {
float one = 1.0;
return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &one);
}

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
if ([self respondsToSelector:@selector(setThermalState:)]) {
((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setThermalState:), [NSNumber numberWithInt:0]);
}
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
}
NSLog(@"[CPUthermal] CommonProduct init, 已复位 nominal 状态");
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
if (!isTemperatureAboveSafetyCeiling()) {
return;
}
}
%orig;
}

// 拦截系统切换至高压热状态 — 保持 nominal
- (void)setThermalState:(id)state {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig(state);
}

%end

%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig(arg1, arg2);
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层 — 新增自 1.dylib 分析）
//
// 冲突避免说明:
//   - 传感器读数 getHighestSkinTemp/dieTempFilteredMaxAverage/thermalSensorValuesMaxFromIndexSet
//     不在此处 hook (IOKit 层已拦截)
//   - 低功耗改为模拟 Moderate 热压力级别，触发系统自然频率调控
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
if (shouldApplyFullCPUProtection()) {
NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
return;
}
%orig;
}

// 热通知 — 可选择性阻断
- (void)updateThermalNotification:(id)notification {
if (g_enabled && g_suppressThermalNotifications) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止热通知: %@", notification);
return;
}
}
%orig;
}

// 获取组件释放速率 — 游戏场景直接归零，避免任何降频释放
- (float)getReleaseRateForComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止组件释放速率: %@", component);
return 0.01f;
}
}
return %orig(component);
}

// 散热/电池服务建议 — 关闭时返回 nil 屏蔽系统散热提示
// (适配自 fuckThermal 逆向还原分析)
- (id)getBatteryServiceSuggestion:(id)suggestion {
id result = %orig(suggestion);
if (g_enabled && g_suppressThermalNotifications) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 拦截 ThermalManager 散热建议");
return nil;
}
}
return result;
}

// 热压力升级通知 — 阻止系统升级热压力级别（CPUQ 移植）
- (void)updateThermalPressureLevelNotification:(id)notification shouldForceThermalPressure:(BOOL)force {
if (g_enabled && g_cpuProtection) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止热压力升级: %@ force:%d", notification, force);
%orig(notification, NO);
return;
}
}
%orig;
}

// 是否应执行轻度热压力 — 阻止（CPUQ 移植）
- (BOOL)shouldEnforceLightThermalPressure {
if (g_enabled && g_cpuProtection) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 阻止 enforceLightThermalPressure");
return NO;
}
}
return %orig;
}

// 获取强制热级别 — 返回最低 nominal 级（CPUQ 移植）
- (int)getPotentialForcedThermalLevel:(id)component {
if (g_enabled && g_cpuProtection) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 覆盖强制热级别: %@ -> 0 (nominal)", component);
return 0; // kThermalLevelNominal
}
}
return %orig(component);
}

// 获取强制热压力级别 — 返回最低（CPUQ 移植）
- (int)getPotentialForcedThermalPressureLevel {
if (g_enabled && g_cpuProtection) {
if (!isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 覆盖强制热压力级别 -> 0");
return 0;
}
}
return %orig;
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
}
}
return res;
}

- (id)initWithParams:(id)params {
id res = %orig(params);
if (res) {
trackPowerController(res);
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
}
}
return res;
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) {
return %orig;
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
if (shouldApplyFullCPUProtection()) {
%orig(nil);
return;
}
%orig;
}

// 计算控制力度 — throttle 量的核心（CPUQ 移植）
// soften 模式下减半但不归零，保留基础调节能力
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
if (shouldApplyFullCPUProtection()) {
if (!isTemperatureAboveSafetyCeiling()) {
float effort = %orig(trigger, arg2);
float newEffort = effort * 0.5f;
if (newEffort < 0 && effort > 0) newEffort = 0;
NSLog(@"[CPUthermal] 软化控制力度: %.2f -> %.2f", effort, newEffort);
return newEffort;
}
}
return %orig(trigger, arg2);
}

// ===============================================================
// 在解除温控模式下让 thermalmonitord 读到"假低温"，
// 阻止其内部状态机进入高压热级别，从根本上避免降频决策。
// 安全阀: 真实温度超过 100°C 时不拦截，确保紧急热保护有效。
// ===============================================================

// dieTemp 滤波最大值 — 芯片核心温度
- (float)dieTempFilteredMaxAverage {
float temp = %orig;
if (shouldApplyFullCPUProtection() && temp > 0) {
if (temp >= (float)kSafetyTempThreshold) {
return temp;
}
NSLog(@"[CPUthermal] 拦截 dieTempFilteredMaxAverage: %.0f -> 35000", temp);
return 35000.0f;
}
return temp;
}

// 最高皮肤温度 — 外壳温度触发降频关键
- (float)getHighestSkinTemp {
float temp = %orig;
if (shouldApplyFullCPUProtection() && temp > 0) {
if (temp >= (float)kSafetyTempThreshold) {
return temp;
}
NSLog(@"[CPUthermal] 拦截 getHighestSkinTemp: %.0f -> 30000", temp);
return 30000.0f;
}
return temp;
}

// 传感器组最大值 — NAND/充电等组件温度
- (float)thermalSensorValuesMaxFromIndexSet:(id)indexSet {
float temp = %orig(indexSet);
if (shouldApplyFullCPUProtection() && temp > 0) {
if (temp >= (float)kSafetyTempThreshold) {
return temp;
}
return 30000.0f;
}
return temp;
}

// updatePowerParameters — A15 上有独立的电源参数更新路径（游戏场景关键）
- (void)updatePowerParameters:(id)params {
if (shouldApplyFullCPUProtection()) {
NSLog(@"[CPUthermal] 阻止电源参数更新");
return;
}
%orig;
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

// init — 追踪新实例，防止唤醒后重新初始化丢失追踪
- (id)init {
id res = %orig;
if (res) {
trackPowerController(res);
}
return res;
}

- (void)setCPULevel:(int)level {
// 追踪未注册的实例（init 可能不被调用或已存在实例）
if (![g_mitigationControllers containsObject:self]) {
trackPowerController(self);
}
if (g_restoringFullPower) {
%orig(level);
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

%end

// --- MitigationController: 功率目标控制 ---
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
}
}
return res;
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) {
return %orig;
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
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyFullCPUProtection()) {
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
%orig;
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
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerTargetForController(self), legacy, propertyArg);
return;
}
%orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerCeilingForController(self), source);
return;
}
%orig;
}

- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(uintptr_t)contributor {
if (g_restoringFullPower) {
%orig(ceiling, contributor);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerCeilingForController(self), contributor);
return;
}
%orig;
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(floor, source);
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
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerZoneTargetForController(self));
return;
}
%orig;
}


- (void)updatePowerTarget {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)calculateMitigation {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)computePowerTarget {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

- (void)setCPMSMitigationState:(int)state {
if (g_restoringFullPower) {
%orig(state);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig;
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
if (g_restoringFullPower) {
%orig(enabled);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(NO);
return;
}
%orig;
}

- (BOOL)shouldSuppressMitigations {
if (shouldApplyFullCPUProtection()) {
return YES;
}
return %orig;
}

%end

%hook TableDrivenLowTempController

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
int original = %orig(temperature, soc, ra);
if (shouldApplyFullCPUProtection()) {
return MAX(original, lowTempFullPowerOutputValue());
}
return original;
}

%end

%hook FormulaDrivenLowTempController

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
int original = %orig(temperature, soc, ra);
if (shouldApplyFullCPUProtection()) {
return MAX(original, lowTempFullPowerOutputValue());
}
return original;
}

%end

%hook FormulaDrivenLowTempController_CPU

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
int original = %orig(temperature, soc, ra);
if (shouldApplyFullCPUProtection()) {
return MAX(original, lowTempFullPowerOutputValue());
}
return original;
}

%end

// ============================================================================
// C 函数钩子: _getConfigurationFor → ___New_getConfigurationFor___
//
// 在 thermalmonitord 初始化时，会调用 _getConfigurationFor(NSString*)
// 来获取热配置字典。通过返回修改后的配置，可以影响所有热管理参数。
// ============================================================================

// 前向声明 — patchThermalPlistDict 在 _getConfigurationFor 之后定义
static void patchThermalPlistDict(NSMutableDictionary *dict);

// 原函数类型: NSDictionary* _getConfigurationFor(NSString *key)
static NSDictionary* (*orig_getConfigurationFor)(NSString *key) = NULL;

static NSDictionary* new_getConfigurationFor(NSString *key) {
NSDictionary *config = orig_getConfigurationFor(key);
if (!shouldApplyFullCPUProtection() || !config) return config;

@autoreleasepool {
NSMutableDictionary *modified = [config mutableCopy];
if (!modified) return config;

// 修改系统热配置 — 增大所有热等级的触发阈值（延迟触发）
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
// 小幅提高阈值，减少频繁误触发，但不长期绕过系统温控。
int64_t raised = [val longLongValue] + kThermalThresholdRaise;
[newThresholds addObject:@(raised)];
}
modified[tk] = newThresholds;
} else if ([thresholds isKindOfClass:[NSDictionary class]]) {
NSMutableDictionary *newDict = [NSMutableDictionary dictionary];
[(NSDictionary *)thresholds enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
if ([v isKindOfClass:[NSNumber class]]) {
int64_t raised = [v longLongValue] + kThermalThresholdRaise;
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

static void patchThermalPlistDict(NSMutableDictionary *dict) {
if (!g_enabled) return;

@autoreleasepool {
// 将各热级别背光功率/亮度保持在首档，避免发热状态连带触发亮度和功率回退。
NSMutableDictionary *backlightComponentControl = [dict[S("backlightComponentControl")] mutableCopy];
if (backlightComponentControl && (g_cpuProtection || g_brightnessProtection)) {
NSArray *backlightKeys = @[S("BacklightBrightness"), S("BacklightPower")];
for (NSString *key in backlightKeys) {
id originalValues = backlightComponentControl[key];
if (![originalValues isKindOfClass:[NSArray class]]) {
continue;
}
NSMutableArray *values = [originalValues mutableCopy];
if (values.count > 0) {
id firstValue = values[0];
for (NSUInteger i = 1; i < values.count; i++) {
values[i] = firstValue;
}
backlightComponentControl[key] = values;
}
}

backlightComponentControl[S("expectsCPMSSupport")] = @NO;

int thermalPower = shouldApplyFullCPUProtection() ? fullPowerTargetValue() : 0;
if (thermalPower > 0) {
backlightComponentControl[S("maxThermalPower")] = [NSNumber numberWithInt:thermalPower];
backlightComponentControl[S("minThermalPower")] = [NSNumber numberWithInt:thermalPower];
}

dict[S("backlightComponentControl")] = backlightComponentControl;
NSLog(@"[CPUthermal] plist: 已应用 CPUthermal backlightComponentControl 补丁 power:%d", thermalPower);
}

// 提高 CPU 最大缓解档位 — 阻止系统进入深度降频
// 仅在全功率取消温控模式生效，低功耗模式放行系统原始配置
if (shouldApplyFullCPUProtection()) {
NSNumber *maxCPU = dict[S("maxCPULevel")];
if (maxCPU && [maxCPU intValue] < 3) {
dict[S("maxCPULevel")] = @3;
NSLog(@"[CPUthermal] plist: maxCPULevel %d → 3", [maxCPU intValue]);
}

// 移除/提高 Hotspot 温度阈值
NSMutableDictionary *hotspot = [dict[S("HotspotConfig")] mutableCopy];
if (hotspot) {
for (NSString *key in [hotspot allKeys]) {
id val = hotspot[key];
if ([val isKindOfClass:[NSNumber class]]) {
// 判断是否像温度阈值 (毫摄氏度, 通常 30000-90000)
int64_t num = [val longLongValue];
if (num >= 30000 && num <= 120000) {
hotspot[key] = @(num + kThermalThresholdRaise);
}
}
}
dict[S("HotspotConfig")] = hotspot;
}
}

// 亮度保护: 移除亮度相关的热缓解值
if (g_brightnessProtection) {
NSMutableDictionary *brightness = [dict[S("backlightControlConfig")] mutableCopy];
if (brightness) {
[brightness removeObjectForKey:S("nitsTarget")];
[brightness removeObjectForKey:S("maxNitsLevel")];
[brightness removeObjectForKey:S("brightnessMitigation")];
dict[S("backlightControlConfig")] = brightness;
}

// 移除或提高 ThermalControlConfig 中的亮度限制
NSMutableDictionary *thermalCtrl = [dict[S("ThermalControlConfig")] mutableCopy];
if (thermalCtrl) {
[thermalCtrl removeObjectForKey:S("backlightMaxNits")];
[thermalCtrl removeObjectForKey:S("brightnessTarget")];
dict[S("ThermalControlConfig")] = thermalCtrl;
}
}
}
}

// --- NSDictionary: 拦截 thermal plist 加载并修补 ---
// 注意: hook 系统类有风险，仅在 CPU/亮度保护开启时实际执行
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
id res = %orig;
if (g_enabled && (g_cpuProtection || g_brightnessProtection) && [path isKindOfClass:[NSString class]]) {
NSString *pathStr = (NSString *)path;
if ([pathStr containsString:S("/System/Library/ThermalMonitor/")]) {
NSMutableDictionary *patched = [res mutableCopy];
if (patched) {
patchThermalPlistDict(patched);
NSLog(@"[CPUthermal] 已修补热配置 plist: %@", [pathStr lastPathComponent]);
return patched;
}
	}
	}
	return res;
	}

%end

// ============================================================================
// Puppet 事件（由 Preferences 面板触发 — 模拟热级别切换）
// ============================================================================
static void executePuppetEvent(void) {
if (!g_commonProduct) return;
@autoreleasepool {
NSDictionary *prefs = readPrefsDictionary();
NSString *level = prefs[S("thermalPuppetValue")] ?: S("nominal");
if ([g_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
((void (*)(id, SEL, id))objc_msgSend)(g_commonProduct, @selector(putDeviceInThermalSimulationMode:), level);
}
NSLog(@"[CPUthermal] Puppet 事件: 热模式设为 %@", level);
}
}

static void onPuppetEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
executePuppetEvent();
}

// IOKit 钩子是否已安装的标志
static BOOL g_iokitHooksInstalled = NO;
static BOOL g_getConfigHookInstalled = NO;

// 在运行中安装 IOKit 钩子（从 disabled → enabled 时需要）
static void installRuntimeHooksIfNeeded(void) {
    if (g_iokitHooksInstalled) return;

    // 确保 IOKit 已加载
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (iokit) {
        kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) = (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))dlsym(iokit, "IOServiceSetProperty");
        if (ptr) {
            MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
            NSLog(@"[CPUthermal] 运行时: IOServiceSetProperty hook 已安装");
        }
        kern_return_t (*ptrSetProps)(io_service_t, CFDictionaryRef) = (kern_return_t (*)(io_service_t, CFDictionaryRef))dlsym(iokit, "IOServiceSetProperties");
        if (ptrSetProps) {
            MSHookFunction((void *)ptrSetProps, (void *)hooked_IOServiceSetProperties, (void **)&orig_IOServiceSetProperties);
            NSLog(@"[CPUthermal] 运行时: IOServiceSetProperties hook 已安装");
        }
        g_iokitHooksInstalled = YES;
    }

    if (!g_getConfigHookInstalled) {
        void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
        if (monitor) {
            void *getConfig = dlsym(monitor, "_getConfigurationFor");
            if (getConfig) {
                MSHookFunction(getConfig, (void *)new_getConfigurationFor, (void **)&orig_getConfigurationFor);
                NSLog(@"[CPUthermal] 运行时: _getConfigurationFor hook 已安装");
                g_getConfigHookInstalled = YES;
            }
        }
    }
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
installRuntimeHooksIfNeeded();
if (shouldApplyFullCPUProtection()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
}
} else {
stopContinuousTimer();
stopThermalMonitorTimer();
}
NSLog(@"[CPUthermal] 设置已重载 enabled:%d CPU:%d 亮度:%d 通知:%d 热压监控:%d 通知监控:%d 覆盖:%d",
g_enabled, g_cpuProtection, g_brightnessProtection, g_suppressThermalNotifications,
g_pressureMonitor, g_notificationMonitor, g_pressureOverrideEnabled);
}

static void onWakeRuntimeEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
scheduleWakeRuntimeApply();
}
NSLog(S("[CPUthermal] 收到唤醒/亮屏事件，准备恢复解除温控状态"));
}

// ============================================================================
// 退出清理
// ============================================================================
static void freeStaticCFStrings(void) {
static dispatch_once_t once;
dispatch_once(&once, ^{
__block CFStringRef name = NULL;
static dispatch_once_t innerOnce;
dispatch_once(&innerOnce, ^{
name = cpuMaxPowerPropertyName();
});
if (name) CFRelease(name);
});
}

static void pluginCleanup(void) {
stopContinuousTimer();
CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
if (c) {
CFNotificationCenterRemoveEveryObserver(c, NULL);
}
freeStaticCFStrings();
os_unfair_lock_lock(&g_controllerLock);
[g_mitigationControllers removeAllObjects];
[g_originalControllerValues removeAllObjects];
os_unfair_lock_unlock(&g_controllerLock);
}

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
g_processStartTime = CFAbsoluteTimeGetCurrent();
atexit(pluginCleanup); // 注册退出清理

// 始终注册通知监听（即使当前未启用），以便运行时收到启用指令后激活
CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
if (c) {
CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
CFNotificationCenterAddObserver(c, NULL, onPuppetEvent,
(__bridge CFStringRef)S("com.huayuarc.CPUthermal.puppet"),
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
CFNotificationCenterAddObserver(c, NULL, onWakeRuntimeEvent,
(__bridge CFStringRef)S("com.apple.system.power.SleepWakeState"),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
CFNotificationCenterAddObserver(c, NULL, onSettingsChanged,
(__bridge CFStringRef)S(kCPUthermalMonitorNotifC),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
NSLog(@"[CPUthermal] Darwin 通知监听已注册");
}

loadPrefs();
if (isTemperatureAboveSafetyCeiling()) {
NSLog(@"[CPUthermal] 安全阀检测到极高温度，跳过保护激活");
return;
}

if (!g_enabled) {
NSLog(@"[CPUthermal] 配置关闭，跳过加载（通知监听已注册，可在运行中激活）");
return;
}

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

// IOServiceSetProperties (复数) — 防止系统通过此路径绕过单数 hook
kern_return_t (*ptrSetProps)(io_service_t, CFDictionaryRef) = (kern_return_t (*)(io_service_t, CFDictionaryRef))dlsym(iokit, "IOServiceSetProperties");
if (ptrSetProps) {
MSHookFunction((void *)ptrSetProps, (void *)hooked_IOServiceSetProperties, (void **)&orig_IOServiceSetProperties);
NSLog(@"[CPUthermal] IOServiceSetProperties hook 已安装");
} else {
NSLog(@"[CPUthermal] 警告: 未找到 IOServiceSetProperties");
}
g_iokitHooksInstalled = YES;
}

// _getConfigurationFor — C 函数钩子
void *monitor = dlopen("/System/Library/PrivateFrameworks/DeviceMonitor.framework/DeviceMonitor", RTLD_NOW | RTLD_GLOBAL);
if (monitor) {
void *getConfig = dlsym(monitor, "_getConfigurationFor");
if (getConfig) {
MSHookFunction(getConfig, (void *)new_getConfigurationFor, (void **)&orig_getConfigurationFor);
NSLog(@"[CPUthermal] _getConfigurationFor hook 已安装");
g_getConfigHookInstalled = YES;
} else {
NSLog(@"[CPUthermal] 未找到 _getConfigurationFor (非致命)");
}
} else {
NSLog(@"[CPUthermal] 未找到 DeviceMonitor.framework (非致命)");
}

NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU性能:%d 亮度:%d 通知:%d 性能维护:%dms",
(int)(kSafetyTempThreshold / 1000),
g_cpuProtection, g_brightnessProtection,
g_suppressThermalNotifications, (int)kContinuousTimerIntervalMs);
}
}
