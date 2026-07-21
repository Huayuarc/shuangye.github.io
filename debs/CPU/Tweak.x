#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <limits.h>
#import <stdint.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>
#import <IOKit/IOKitLib.h>
#import "PowercuffManager.h"

// ============================================================================
// CPUthermal — 温控插件（完全版）
//
// 双防护层设计:
//   第1层 (IOKit): 拦截传感器温度读取、降频操作、属性写入、Darwin 通知广播
//   第2层 (ObjC):  钩住 thermalmonitord 内部类决策方法，阻止热缓解动作
//
// 冲突避免原则:
//   - 传感器读数拦截只走 IOKit，不走 ObjC
//   - 不 hook putDeviceInThermalSimulationMode: (CPUthermal 调用方)
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
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setThermalState:(id)state;
- (void)registerDefaultsDomain;
- (void)setServiceProperty:(id)svc key:(id)key value:(id)val scaleToFixedPoint:(BOOL)scale;
@end

// ============================================================================
// 新增: 分析发现的额外类声明
// ============================================================================
@interface ThermalManager : NSObject
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
- (void)evaluateDecisionTree;
- (id)findComponent:(id)component;
- (id)findCC:(id)component;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (float)getReleaseRateForComponent:(id)component;
- (void)updateThermalNotification:(id)notification;
- (void)updateThermalPressureLevelNotification:(id)notif shouldForceThermalPressure:(BOOL)force;
- (id)getPotentialForcedThermalLevel:(id)level;
- (id)getPotentialForcedThermalPressureLevel;
- (BOOL)shouldEnforceLightThermalPressure;
@end

@interface ThermalControl : NSObject
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

@interface ApplePPMGPU : NSObject
- (void)setGPULevel:(int)level;
- (void)updateGPU;
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
- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(uintptr_t)contributor;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
// GPU 功率管理（A15 游戏场景关键）
- (void)setMaxGPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setGPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setGPUPowerZoneTarget:(int)target;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
- (void)updatePowerTarget;
- (void)calculateMitigation;
- (void)computePowerTarget;
- (void)setCPMSMitigationState:(int)state;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (BOOL)shouldSuppressMitigations;
- (void)setHiPFeatureEnabled:(BOOL)en;
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
static BOOL g_disableHotInPocket    = NO; // 禁用系统 Hot-In-Pocket 口袋高温模式
static BOOL g_lockSunlightExposure  = NO; // 锁定系统阳光暴晒状态
static BOOL g_debugLogging          = NO; // 高频 hook 调试日志（默认关闭，避免拖慢 thermalmonitord）

static void CPUthermalDebugLog(NSString *format, ...) {
if (!g_debugLogging || !format) return;
va_list args;
va_start(args, format);
NSLogv(format, args);
va_end(args);
}

BOOL CPUthermalDebugLoggingEnabled(void) {
return g_debugLogging;
}

typedef enum {
CPUthermalPowerModeFull = 0,
CPUthermalPowerModeLow  = 1
} CPUthermalPowerMode;

static CPUthermalPowerMode g_powerMode = CPUthermalPowerModeFull;

// Powercuff 热模拟 — 上一次成功应用的级别（避免冗余调用）
static NSString *g_lastPowercuffLevel = nil;

// CPU频率锁定 — 手动选择芯片代际锁定频率(MHz)，0=无锁定
static NSInteger g_deviceLockMHz = 0;

// 低功耗/稳帧模式 CPU 频率限制（MHz）
// 只限制上限，不强制抬高最低频，避免轻负载锁高频导致发热。
static const int64_t kLowPowerMinFrequencyMHz = 600;
static const int64_t kLowPowerMaxFrequencyMHz = 1800;

// 温度安全阀 — 超过此值不拦截任何保护
// 100°C 后优先交还系统温控，并始终放行 0x60-0x6F 紧急保护。
static const int64_t kSafetyTempThreshold = 100000;
static const int64_t kThermalThresholdRaise = 5000;

static CommonProduct *g_commonProduct = nil;
static NSMutableArray *g_mitigationControllers = nil;
static BOOL g_restoringFullPower = NO;
static BOOL g_applyingLowPower = NO;
static NSMutableDictionary *g_originalControllerValues = nil;
static CFAbsoluteTime g_processStartTime = 0;
static const double kFullPowerBootGuardDuration = 1.0;
static BOOL g_deferredRuntimeApplyScheduled = NO;

// ============================================================================
// 运行时维护定时器
// 仅稳帧低功耗模式需要低频补写；防温控模式不再周期性拉满功率，避免越刷越热。
// ============================================================================
static dispatch_source_t g_continuousTimer = NULL;
static const int64_t kContinuousTimerIntervalMs = 8000;

static void stopContinuousTimer(void);

// 前向声明 — 供性能维护定时器 block 使用
static BOOL isLowPowerMode(void);
static BOOL isFullPowerMode(void);
static BOOL fullPowerBootGuardActive(void);
static BOOL shouldApplyFullCPUProtection(void);
static BOOL shouldApplyLowPowerLimit(void);
static void applyLowPowerToCommonProduct(void);
static void applyLowPowerLimitsToTrackedControllers(void);
static void applyFullPowerToCommonProduct(void);
static void restoreFullPowerToTrackedControllers(void);

static void startContinuousTimer(void) {
if (g_continuousTimer) return;
if (!shouldApplyLowPowerLimit()) return;

g_continuousTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
dispatch_source_set_timer(g_continuousTimer,
dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContinuousTimerIntervalMs * NSEC_PER_MSEC)),
(uint64_t)(kContinuousTimerIntervalMs * NSEC_PER_MSEC),
(uint64_t)(50 * NSEC_PER_MSEC));
dispatch_source_set_event_handler(g_continuousTimer, ^{
@autoreleasepool {
if (!shouldApplyLowPowerLimit()) {
stopContinuousTimer();
return;
}
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
// Powercuff: 低功耗时同步应用热模拟
NSString *pcLevel = powercuffReadLevel();
if (pcLevel && g_commonProduct) {
powercuffApply(g_commonProduct, pcLevel);
}
}
});
dispatch_resume(g_continuousTimer);
CPUthermalDebugLog(@"[CPUthermal] 性能维护定时器已启动 (间隔 %.1f 秒)", (double)kContinuousTimerIntervalMs / 1000.0);
}

static void stopContinuousTimer(void) {
if (g_continuousTimer) {
dispatch_source_cancel(g_continuousTimer);
g_continuousTimer = NULL;
CPUthermalDebugLog(@"[CPUthermal] 性能维护定时器已停止");
}
}

static int lowPowerTargetValue(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(BOOL respectBootGuard);
static void scheduleDeferredRuntimeApply(double delay);

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
if (g_deviceLockMHz > 0) return MIN((int)g_deviceLockMHz, (int)kLowPowerMaxFrequencyMHz);
return (int)kLowPowerMaxFrequencyMHz;
}

static int lowPowerPowerCeilingValue(void) {
return 35;
}

static int lowPowerGPUPowerCeilingValue(void) {
return 65;
}

static int lowPowerPackagePowerCeilingValue(void) {
return MAX(lowPowerPowerCeilingValue(), lowPowerGPUPowerCeilingValue());
}

static int lowPowerPowerFloorValue(void) {
return 0;
}

static int fullPowerTargetValue(void) {
return 100;
}

static int fullPowerFrequencyValue(void) {
if (g_deviceLockMHz > 0) return (int)g_deviceLockMHz;
return (int)CPUthermalNativeMaxPCoreFrequencyMHz();
}

static int fullPowerPercentValue(void) {
return 100;
}

static int fullPowerGPUFloorValue(void) {
return 0;
}

static int lowPowerLimitedGPUValue(int original) {
if (original <= 0) return lowPowerGPUPowerCeilingValue();
return MIN(original, lowPowerGPUPowerCeilingValue());
}

static int lowTempFullPowerOutputValue(void) {
return fullPowerPercentValue();
}

static int lowTempLimitedOutputValue(int original) {
if (g_deviceLockMHz > 0) return MIN(original, (int)g_deviceLockMHz);
return MIN(original, lowPowerTargetValue());
}

static CFStringRef cpuMaxPowerPropertyName(void) {
static CFStringRef propertyName = NULL;
static dispatch_once_t once;
dispatch_once(&once, ^{
propertyName = CFStringCreateWithCString(kCFAllocatorDefault, "CPUMaxPower", kCFStringEncodingUTF8);
});
return propertyName;
}

static CFStringRef gpuMaxPowerPropertyName(void) {
static CFStringRef propertyName = NULL;
static dispatch_once_t once;
dispatch_once(&once, ^{
propertyName = CFStringCreateWithCString(kCFAllocatorDefault, "GPUMaxPower", kCFStringEncodingUTF8);
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

static BOOL setMaxGPUPowerTargetUsesCFString(id controller) {
return methodEncodingContains(controller, @selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:), "^{__CFString=}");
}

static uintptr_t setMaxGPUPowerPropertyArgument(id controller) {
return setMaxGPUPowerTargetUsesCFString(controller)
? (uintptr_t)gpuMaxPowerPropertyName()
: (uintptr_t)YES;
}

static uintptr_t normalizedSetMaxGPUPowerPropertyArgument(id controller, uintptr_t property) {
if (setMaxGPUPowerTargetUsesCFString(controller) && property < 4096) {
return (uintptr_t)gpuMaxPowerPropertyName();
}
return property;
}

static void sendSetMaxCPUPowerTarget(id controller, int target, BOOL legacy) {
if (!controller || ![controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) return;
((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:),
target, legacy, setMaxCPUPowerPropertyArgument(controller));
}

static void sendSetMaxGPUPowerTarget(id controller, int target, BOOL legacy) {
if (!controller || ![controller respondsToSelector:@selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:)]) return;
((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
@selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:),
target, legacy, setMaxGPUPowerPropertyArgument(controller));
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
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), lowPowerTargetValue());
}
if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxCPUPowerTarget(controller, lowPowerTargetValue(), NO);
}
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue(), 0);
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), lowPowerTargetValue());
}
if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
}
if ([controller respondsToSelector:@selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxGPUPowerTarget(controller, lowPowerGPUPowerCeilingValue(), NO);
}
if ([controller respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerCeiling:fromDecisionSource:), lowPowerGPUPowerCeilingValue(), 0);
}
if ([controller respondsToSelector:@selector(setGPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setGPUPowerZoneTarget:), lowPowerGPUPowerCeilingValue());
}
if ([controller respondsToSelector:@selector(setGPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerFloor:fromDecisionSource:), lowPowerPowerFloorValue(), 0);
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
CPUthermalDebugLog(@"[CPUthermal] 已主动下发稳帧限制: CPU %lld-%lldMHz GPU ceiling:%d controller:%@", kLowPowerMinFrequencyMHz, kLowPowerMaxFrequencyMHz, lowPowerGPUPowerCeilingValue(), controller);
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
if ([controller respondsToSelector:@selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxGPUPowerTarget(controller, fullPowerTargetValue(), NO);
}
if ([controller respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerCeiling:fromDecisionSource:), fullPowerTargetValue(), 0);
}
if ([controller respondsToSelector:@selector(setGPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setGPUPowerZoneTarget:), fullPowerTargetValue());
}
if ([controller respondsToSelector:@selector(setGPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerFloor:fromDecisionSource:), fullPowerGPUFloorValue(), 0);
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
CPUthermalDebugLog(@"[CPUthermal] 已主动恢复防温控功率上限 (CPU+GPU) controller:%@", controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 恢复防温控 CPU 上限失败: %@", exception);
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
setCommonProductCeiling(@selector(setGPUPowerCeiling:fromDecisionSource:), 0);
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), 0);
if ([g_commonProduct respondsToSelector:@selector(setThermalState:)]) {
((void (*)(id, SEL, id))objc_msgSend)(g_commonProduct, @selector(setThermalState:), [NSNumber numberWithInt:0]);
}
CPUthermalDebugLog(@"[CPUthermal] 已主动套用防温控 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用防温控 CommonProduct 状态失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void applyLowPowerToCommonProduct(void) {
if (!g_commonProduct || !shouldApplyLowPowerLimit()) return;
@try {
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), 1);
}
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue());
setCommonProductCeiling(@selector(setGPUPowerCeiling:fromDecisionSource:), lowPowerGPUPowerCeilingValue());
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), lowPowerPackagePowerCeilingValue());
CPUthermalDebugLog(@"[CPUthermal] 已主动套用稳帧 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用低功耗 CommonProduct 状态失败: %@", exception);
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
startContinuousTimer();
return;
}
if (isFullPowerMode()) {
stopContinuousTimer();
if (respectBootGuard && fullPowerBootGuardActive()) {
double elapsed = CFAbsoluteTimeGetCurrent() - g_processStartTime;
double remaining = kFullPowerBootGuardDuration - elapsed;
scheduleDeferredRuntimeApply(MAX(remaining, 0.1) + 0.1);
return;
}
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
startContinuousTimer();
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

static void scheduleWakeRuntimeApply(void) {
if (!g_enabled || !g_cpuProtection) return;
dispatch_async(dispatch_get_main_queue(), ^{
loadPrefs();
applyPowerModeToRuntime(NO);
startContinuousTimer();
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
if ([lower containsString:S("displaystatus")] ||
[lower containsString:S("blank")] ||
[lower containsString:S("sleep")] ||
[lower containsString:S("wake")] ||
[lower containsString:S("powerstate")]) {
return NO;
}
if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
double numericValue = 0;
if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &numericValue) && numericValue <= 0.01) {
return NO;
}
}
return [lower containsString:S("thermal")] ||
[lower containsString:S("mitigat")] ||
[lower containsString:S("throttle")] ||
[lower containsString:S("reduce")] ||
[lower containsString:S("limit")] ||
[lower containsString:S("target")] ||
[lower containsString:S("sunlight")] ||
[lower containsString:S("pressure")] ||
[lower containsString:S("hot")];
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
[lower containsString:S("gpu")] ||
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
	g_disableHotInPocket    = [d[S(kCPUthermalDisableHotInPocketKeyC)] ?: [NSNumber numberWithBool:NO] boolValue];
	g_lockSunlightExposure  = [d[S(kCPUthermalLockSunlightExposureKeyC)] ?: [NSNumber numberWithBool:NO] boolValue];
	g_debugLogging          = [d[S("debugLogging")] ?: [NSNumber numberWithBool:NO] boolValue];

	int thermalPrefsResult = CPUthermalApplyThermalStatusOverridesFromPrefs(d);
	if (thermalPrefsResult != kSCStatusOK) {
	NSLog(@"[CPUthermal] OSThermalStatus 写入失败: %d", thermalPrefsResult);
	}

NSString *mode = d[S("powerMode")] ?: S("lowPower");
g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;

// CPU频率锁定
NSString *chipKey = d[S(kCPUthermalDeviceLockKeyC)];
g_deviceLockMHz = CPUthermalFrequencyForChipKey(chipKey);
}
}


// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

NSString *ks = (__bridge NSString *)key;
if (g_cpuProtection && !g_restoringFullPower && shouldBlockCPUProperty(ks)) {
if (isFullPowerMode()) return KERN_SUCCESS;
if (shouldApplyLowPowerLimit()) {
CFTypeRef replacement = copyLowPowerFrequencyValueForKey(ks, value);
if (replacement) {
kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
CFRelease(replacement);
return ret;
}
}
}
if (g_brightnessProtection && shouldBlockBrightnessProperty(ks, value)) {
return KERN_SUCCESS;
}
return orig_IOServiceSetProperty(service, key, value);
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
CPUthermalDebugLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal, 功率模式:%@", isLowPowerMode() ? S("稳帧降温") : S("极限防温控"));
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

// 拦截系统切换至高压热状态 — 保持 nominal
- (void)setThermalState:(id)state {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig(state);
}

// 阻止注册默认域（额外防护层，防止热监控重置配置）
- (void)registerDefaultsDomain {
CPUthermalDebugLog(@"[CPUthermal] 阻止 registerDefaultsDomain");
// 不调用 %orig，跳过默认值注册
}

// ============================================================
// Powercuff 热模拟持久化钩子
// 防止系统/CC 模块切换时将热模拟状态复位为 off/nominal
// ============================================================
- (void)putDeviceInThermalSimulationMode:(id)mode {
    NSString *desiredLevel = powercuffReadLevel();
    if (desiredLevel) {
        // Powercuff 已启用 — 检查是否是复位调用
        NSString *incoming = (NSString *)mode;
        BOOL isReset = (!incoming || incoming.length == 0 ||
                        [incoming isEqualToString:@"off"] ||
                        [incoming isEqualToString:@"nominal"]);
        if (isReset) {
            CPUthermalDebugLog(@"[CPUthermal][Powercuff] ← 拦截复位 '%@' → 重定向至 '%@'", incoming, desiredLevel);
            g_lastPowercuffLevel = desiredLevel;
            %orig(desiredLevel);
            return;
        }
    }
    // 非复位调用或 powercuff 关闭 — 正常放行
    g_lastPowercuffLevel = nil;
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
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
return;
}
%orig;
}

// 热通知 — 可选择性阻断
- (void)updateThermalNotification:(id)notification {
if (g_enabled && g_suppressThermalNotifications) {
CPUthermalDebugLog(@"[CPUthermal] 阻止热通知: %@", notification);
return;
}
%orig;
}

// 获取组件释放速率 — 游戏场景直接归零，避免任何降频释放
- (float)getReleaseRateForComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止组件释放速率: %@", component);
return 0.01f;
}
return %orig(component);
}

// 散热/电池服务建议 — 关闭时返回 nil 屏蔽系统散热提示
// (适配自 fuckThermal 逆向还原分析)
- (id)getBatteryServiceSuggestion:(id)suggestion {
id result = %orig(suggestion);
if (g_enabled && g_suppressThermalNotifications) {
CPUthermalDebugLog(@"[CPUthermal] 拦截 ThermalManager 散热建议");
return nil;
}
return result;
}

// === 以下方法适配自 ThermalUnlimited 逆向分析 ===

// 阻止查找组件 — 避免热监控发现并管理组件
- (id)findComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止 findComponent: %@", component);
return nil;
}
return %orig(component);
}

// 阻止查找组件控制器
- (id)findCC:(id)cc {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止 findCC: %@", cc);
return nil;
}
return %orig(cc);
}

// 阻断热压力级别升级通知
- (void)updateThermalPressureLevelNotification:(id)notif shouldForceThermalPressure:(BOOL)force {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止热压力级别升级: %@ force:%d", notif, force);
return;
}
%orig;
}

// 强制热级别 — 防温控模式下归零
- (id)getPotentialForcedThermalLevel:(id)level {
if (shouldApplyFullCPUProtection()) {
return @(0);
}
return %orig(level);
}

// 强制热压力级别 — 防温控模式下归零
- (id)getPotentialForcedThermalPressureLevel {
if (shouldApplyFullCPUProtection()) {
return @(0);
}
return %orig;
}

// 轻量热压力强制 — 防温控模式下拒绝执行
- (BOOL)shouldEnforceLightThermalPressure {
if (shouldApplyFullCPUProtection()) {
return NO;
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

// updatePowerParameters — A15 上有独立的电源参数更新路径（游戏场景关键）
- (void)updatePowerParameters:(id)params {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止电源参数更新");
return;
}
%orig;
}

// actionComponentControl — 组件控制动作
- (void)actionComponentControl {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止 actionComponentControl");
return;
}
%orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 阻止 readReleaseRateForAllComponents");
return;
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
int lowPowerLevel = level;
if (lowPowerLevel < 0) lowPowerLevel = 0;
if (lowPowerLevel > 2) lowPowerLevel = 2;
%orig(lowPowerLevel);
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

// --- ApplePPMGPU: GPU P-state / 频率管理（A15 游戏场景关键） ---
%hook ApplePPMGPU

- (void)setGPULevel:(int)level {
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig(level);
}

- (void)updateGPU {
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
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(lowPowerTargetValue());
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
if (shouldApplyLowPowerLimit()) {
int64_t clamped = clampLowPowerFrequencyValue(target);
rememberOriginalIntValue(self, "MaxCPUPowerTarget", target);
%orig((int)clamped, legacy, propertyArg);
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
if (shouldApplyLowPowerLimit()) {
rememberOriginalIntValue(self, "CPUPowerCeiling", ceiling);
%orig(lowPowerPowerCeilingValue(), source);
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
if (shouldApplyLowPowerLimit()) {
rememberOriginalIntValue(self, "CPUPowerCeilingDVD1", ceiling);
%orig(lowPowerPowerCeilingValue(), contributor);
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
int64_t clamped = clampLowPowerFrequencyValue(target);
rememberOriginalIntValue(self, "CPUPowerZoneTarget", target);
%orig((int)clamped);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerZoneTargetForController(self));
return;
}
%orig;
}

// ======================== GPU 功率管理（A15 游戏关键） ========================

- (void)setMaxGPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
uintptr_t propertyArg = normalizedSetMaxGPUPowerPropertyArgument(self, property);
if (g_restoringFullPower) {
%orig(target, legacy, propertyArg);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(lowPowerLimitedGPUValue(target), legacy, propertyArg);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerTargetValue(), legacy, propertyArg);
return;
}
%orig;
}

- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(ceiling, source);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(lowPowerLimitedGPUValue(ceiling), source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerTargetValue(), source);
return;
}
%orig;
}

- (void)setGPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(floor, source);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(lowPowerPowerFloorValue(), source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerGPUFloorValue(), source);
return;
}
%orig;
}

- (void)setGPUPowerZoneTarget:(int)target {
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(lowPowerLimitedGPUValue(target));
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerTargetValue());
return;
}
%orig;
}

- (void)updatePowerTarget {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
return;
}
%orig;
}

- (void)calculateMitigation {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
return;
}
%orig;
}

- (void)computePowerTarget {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
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

// 强制启用 HiP（高性能）特性 — 适配自 ThermalUnlimited 逆向
- (void)setHiPFeatureEnabled:(BOOL)en {
if (shouldApplyFullCPUProtection()) {
CPUthermalDebugLog(@"[CPUthermal] 强制启用 HiP 特性");
%orig(YES);
return;
}
%orig(en);
}

%end

%hook TableDrivenLowTempController

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
int original = %orig(temperature, soc, ra);
if (shouldApplyFullCPUProtection()) {
return MAX(original, lowTempFullPowerOutputValue());
}
if (shouldApplyLowPowerLimit()) {
return lowTempLimitedOutputValue(original);
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
if (shouldApplyLowPowerLimit()) {
return lowTempLimitedOutputValue(original);
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
if (shouldApplyLowPowerLimit()) {
return lowTempLimitedOutputValue(original);
}
return original;
}

%end

%hook FormulaDrivenLowTempController_GPU

- (int)outputForBatteryTemperature:(int)temperature stateOfCharge:(int)soc batteryRaValue:(int)ra {
int original = %orig(temperature, soc, ra);
if (shouldApplyFullCPUProtection()) {
return MAX(original, lowTempFullPowerOutputValue());
}
if (shouldApplyLowPowerLimit()) {
return lowTempLimitedOutputValue(original);
}
return original;
}

%end

// ============================================================================
// 新增 %hook 类 — 适配自 ThermalUnlimited 逆向分析
// 初始化追踪层: 拦截 thermalmonitord 各子系统的初始化，注入修改参数
// ============================================================================

// --- ThermalDecisionTable: 决策表初始化追踪 ---
%hook ThermalDecisionTable

- (id)initDecisionTable:(id)table {
id res = %orig(table);
if (res) {
CPUthermalDebugLog(@"[CPUthermal] ThermalDecisionTable 已初始化");
}
return res;
}

%end

// --- HotspotController: 热点控制器 — 修改采样参数禁用温度轮询 ---
%hook HotspotController

- (id)initWithParams:(id)params aggdController:(id)aggd {
id modifiedParams = params;
if (g_enabled && g_cpuProtection && shouldApplyFullCPUProtection()) {
NSMutableDictionary *p = params ? [NSMutableDictionary dictionaryWithDictionary:params] : nil;
if (p) {
p[S("samplingInterval")] = @(99999);
p[S("enableTemperatureSampling")] = @NO;
modifiedParams = p;
CPUthermalDebugLog(@"[CPUthermal] HotspotController: 已禁用温度采样");
}
}
return %orig(modifiedParams, aggd);
}

%end

// --- CommonAggdController: 通用聚合控制器初始化追踪 ---
%hook CommonAggdController

- (id)initWithParams:(id)params product:(id)product {
id res = %orig(params, product);
if (res) {
CPUthermalDebugLog(@"[CPUthermal] CommonAggdController 已初始化");
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
CPUthermalDebugLog(@"[CPUthermal] 已应用稳帧配置: %@ target:%d (%lld-%lldMHz)", key, lowPowerTargetValue(), kLowPowerMinFrequencyMHz, kLowPowerMaxFrequencyMHz);
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

CPUthermalDebugLog(@"[CPUthermal] 已修改热配置表: %@", key);
return [modified copy];
}
}

// ============================================================================
// 热配置 plist 修补（适配自 insulation 的 IDictHepler）
// ============================================================================
static void patchThermalPlistDict(NSMutableDictionary *dict) {
if (!g_enabled) return;

@autoreleasepool {
// 提高 CPU/GPU 最大缓解档位 — 阻止系统进入深度降频
if (g_cpuProtection) {
NSNumber *maxCPU = dict[S("maxCPULevel")];
if (maxCPU && [maxCPU intValue] < 3) {
dict[S("maxCPULevel")] = @3;
CPUthermalDebugLog(@"[CPUthermal] plist: maxCPULevel %d → 3", [maxCPU intValue]);
}
NSNumber *maxGPU = dict[S("maxGPULevel")];
if (maxGPU && [maxGPU intValue] < 3) {
dict[S("maxGPULevel")] = @3;
CPUthermalDebugLog(@"[CPUthermal] plist: maxGPULevel %d → 3", [maxGPU intValue]);
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
// 注意: hook 系统类有风险，仅在亮度保护开启时实际执行
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
id res = %orig;
if (g_enabled && g_brightnessProtection && [path isKindOfClass:[NSString class]]) {
NSString *pathStr = (NSString *)path;
if ([pathStr containsString:S("/System/Library/ThermalMonitor/")]) {
NSMutableDictionary *patched = [res mutableCopy];
if (patched) {
patchThermalPlistDict(patched);
CPUthermalDebugLog(@"[CPUthermal] 已修补热配置 plist: %@", [pathStr lastPathComponent]);
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
// Powercuff: 功率模式切换时同步应用/关闭热模拟
if (isLowPowerMode() && g_commonProduct) {
NSString *pcLevel = powercuffReadLevel();
if (pcLevel) {
powercuffApply(g_commonProduct, pcLevel);
CPUthermalDebugLog(@"[CPUthermal][Powercuff] 稳帧降温模式已同步热模拟: %@", pcLevel);
} else {
CPUthermalDebugLog(@"[CPUthermal][Powercuff] 稳帧降温模式但 powercuff 未启用");
}
} else if (g_commonProduct) {
// 切换到防温控模式 — 如果不关闭热模拟，initProduct 那边已经重置为 nominal 了
}
NSLog(@"[CPUthermal] 功率模式已切换: %@", isLowPowerMode() ? S("稳帧降温") : S("极限防温控"));
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
applyPowerModeToRuntime(NO);
} else {
stopContinuousTimer();
}
	NSLog(@"[CPUthermal] 设置已重载 enabled:%d CPU:%d 亮度:%d 通知:%d 口袋:%d 暴晒:%d",
	g_enabled, g_cpuProtection, g_brightnessProtection, g_suppressThermalNotifications,
	g_disableHotInPocket, g_lockSunlightExposure);
	}

static void onWakeRuntimeEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
scheduleWakeRuntimeApply();
}
CPUthermalDebugLog(S("[CPUthermal] 收到唤醒/亮屏事件，准备恢复当前功率模式"));
}

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
g_processStartTime = CFAbsoluteTimeGetCurrent();
loadPrefs();
if (!g_enabled) {
NSLog(@"[CPUthermal] 配置关闭，跳过加载");
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

NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:%d°C CPU性能:%d 亮度:%d 通知:%d 性能维护:%dms",
(int)(kSafetyTempThreshold / 1000),
g_cpuProtection, g_brightnessProtection,
g_suppressThermalNotifications, (int)kContinuousTimerIntervalMs);

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
}
}
}
