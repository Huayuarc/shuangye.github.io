#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>
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

typedef enum {
CPUthermalPowerModeFull = 0,
CPUthermalPowerModeLow  = 1
} CPUthermalPowerMode;

static CPUthermalPowerMode g_powerMode = CPUthermalPowerModeFull;

// 低功耗模式 CPU 峰值限制（MHz）
// 使用设备原生最高频率的温和比例，不再固定 2016MHz，避免游戏/高刷场景明显掉帧。
static const int64_t kLowPowerMinimumCapMHz = 2200;
static const int64_t kLowPowerMaximumCapMHz = 2200;
static const int64_t kLowPowerCapPercent = 78;

// 温度安全阀 — 超过此值不拦截任何保护
// 100°C 后优先交还系统温控，并始终放行 0x60-0x6F 紧急保护。
static const int64_t kSafetyTempThreshold = 100000;
static const int64_t kThermalThresholdRaise = 15000;

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
static BOOL g_applyingLowPower = NO;
static NSMutableDictionary *g_originalControllerValues = nil;
static CFAbsoluteTime g_processStartTime = 0;
static const double kFullPowerBootGuardDuration = 1.0;
static BOOL g_deferredRuntimeApplyScheduled = NO;

// ============================================================================
// 运行时维护定时器
// 防温控模式下低频率补写满性能状态，避免 0.8s 高频刷写造成额外卡顿。
// ============================================================================
static dispatch_source_t g_continuousTimer = NULL;
static const int64_t kContinuousTimerIntervalMs = 2000;

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
if (!g_enabled || !g_cpuProtection) return;

g_continuousTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
dispatch_source_set_timer(g_continuousTimer,
dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContinuousTimerIntervalMs * NSEC_PER_MSEC)),
(uint64_t)(kContinuousTimerIntervalMs * NSEC_PER_MSEC),
(uint64_t)(50 * NSEC_PER_MSEC));
dispatch_source_set_event_handler(g_continuousTimer, ^{
@autoreleasepool {
if (!g_enabled || !g_cpuProtection) {
stopContinuousTimer();
return;
}
if (shouldApplyLowPowerLimit()) {
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
} else if (shouldApplyFullCPUProtection()) {
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
int64_t native = CPUthermalNativeMaxPCoreFrequencyMHz();
if (native <= 0) native = kCPUthermalDefaultMaxPCoreFrequencyMHz;

int64_t cap = (native * kLowPowerCapPercent) / 100;
if (cap < kLowPowerMinimumCapMHz) cap = MIN(native, kLowPowerMinimumCapMHz);
if (cap > kLowPowerMaximumCapMHz) cap = kLowPowerMaximumCapMHz;
if (cap > native) cap = native;
return (int)cap;
}

static int lowPowerPowerCeilingValue(void) {
return 85;
}

static int lowPowerPowerFloorValue(void) {
return 0;
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

static int lowTempLimitedOutputValue(int original) {
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
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
// GPU 低功耗限制（v3.1 新增强化）：限制 GPU 功率上限避免游戏场景 GPU 过载发热
if ([controller respondsToSelector:@selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:)]) {
((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller, @selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:), lowPowerTargetValue(), NO, setMaxCPUPowerPropertyArgument(controller));
}
if ([controller respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue(), 0);
}
if ([controller respondsToSelector:@selector(setGPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setGPUPowerZoneTarget:), lowPowerTargetValue());
}
if ([controller respondsToSelector:@selector(updateGPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateGPU));
}
NSLog(@"[CPUthermal] 已主动下发低功耗 CPU+GPU 限制: %lld-%lldMHz controller:%@", kLowPowerMinimumCapMHz, kLowPowerMaximumCapMHz, controller);
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
((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller, @selector(setMaxGPUPowerTarget:useLegacyPath:setProperty:), fullPowerTargetValue(), NO, setMaxCPUPowerPropertyArgument(controller));
}
if ([controller respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerCeiling:fromDecisionSource:), fullPowerTargetValue(), 0);
}
if ([controller respondsToSelector:@selector(setGPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setGPUPowerZoneTarget:), fullPowerTargetValue());
}
if ([controller respondsToSelector:@selector(setGPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerFloor:fromDecisionSource:), fullPowerTargetValue(), 0);
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
NSLog(@"[CPUthermal] 已主动恢复防温控功率上限 (CPU+GPU) controller:%@", controller);
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
NSLog(@"[CPUthermal] 已主动套用防温控 CommonProduct 状态");
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
setCommonProductCeiling(@selector(setGPUPowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue());
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), lowPowerPowerCeilingValue());
NSLog(@"[CPUthermal] 已主动套用低功耗 CommonProduct 状态");
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
if (mhz < kLowPowerMinimumCapMHz) mhz = kLowPowerMinimumCapMHz;
if (mhz > kLowPowerMaximumCapMHz) mhz = kLowPowerMaximumCapMHz;
return frequencyValueFromMHz(mhz, value);
}

static CFTypeRef copyLowPowerFrequencyValueForKey(NSString *key, CFTypeRef originalValue) {
if (!keyMatchesLowPowerLimit(key)) return NULL;
NSString *lower = [key lowercaseString];
BOOL isMinKey = [key localizedCaseInsensitiveContainsString:S("min")] ||
[key localizedCaseInsensitiveContainsString:S("floor")];
BOOL isFrequencyKey = [lower containsString:S("freq")] ||
[lower containsString:S("frequency")];

int64_t original = kLowPowerMaximumCapMHz;
if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
} else if (isMinKey && isFrequencyKey) {
original = kLowPowerMinimumCapMHz;
}

int64_t replacement = isMinKey && isFrequencyKey
? frequencyValueFromMHz(kLowPowerMinimumCapMHz, original)
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

int64_t original = originalNumber ? [originalNumber longLongValue] : kLowPowerMaximumCapMHz;
int64_t replacement = (isMinKey && isFrequencyKey)
? frequencyValueFromMHz(kLowPowerMinimumCapMHz, original)
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

	int thermalPrefsResult = CPUthermalApplyThermalStatusOverridesFromPrefs(d);
	if (thermalPrefsResult != kSCStatusOK) {
	NSLog(@"[CPUthermal] OSThermalStatus 写入失败: %d", thermalPrefsResult);
	}

	NSString *mode = d[S("powerMode")] ?: S("fullPower");
g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;

// CPU频率锁定已移除（面板中不再提供此开关）
}
}


// ============================================================================
// IOKit connection 追踪 + 温度安全阀
// ============================================================================
static const char *g_hotServices[] = {
    "AppleSPU", "AppleSPU.original",
    "AppleARMPlatform",
    "pmu", "ApplePMGR",
    "AGXKext", "AGXKextA15",
    "AppleCLPC", "AppleCLPCv2",
    "ANECompilerService",
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

// 温度安全阀 — 超过 100°C 或读温失败时放行所有保护
static BOOL isTemperatureAboveSafetyCeiling(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleARMPlatform");
    if (!matching) return YES;

    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    if (!service) return YES;

    CFStringRef tempKey = CFStringCreateWithCString(kCFAllocatorDefault, "temperature", kCFStringEncodingUTF8);
    CFTypeRef temp = tempKey ? IORegistryEntryCreateCFProperty(service, tempKey, kCFAllocatorDefault, 0) : NULL;
    if (tempKey) CFRelease(tempKey);
    IOObjectRelease(service);

    BOOL above = YES;
    if (temp && CFGetTypeID(temp) == CFNumberGetTypeID()) {
        int64_t tempVal = 0;
        if (CFNumberGetValue((CFNumberRef)temp, kCFNumberSInt64Type, &tempVal)) {
            above = tempVal >= kSafetyTempThreshold;
        }
    }
    if (temp) CFRelease(temp);
    return above;
}

// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

NSString *ks = (__bridge NSString *)key;
if (g_cpuProtection && shouldBlockCPUProperty(ks)) {
if (isFullPowerMode()) {
// 修复: g_restoringFullPower 窗口期内只放行高值恢复写入，拦截降频写入
if (g_restoringFullPower && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
int64_t numVal = 0;
if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &numVal) && numVal > lowPowerTargetValue()) {
return orig_IOServiceSetProperty(service, key, value);
}
}
return KERN_SUCCESS;
}
if (!g_restoringFullPower && shouldApplyLowPowerLimit()) {
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
    BOOL needsReplace = NO;
    NSMutableDictionary *replacementDict = nil;

    for (CFIndex i = 0; i < count; i++) {
        NSString *ks = (__bridge NSString *)keys[i];
        if (!ks) continue;

        if (g_cpuProtection && shouldBlockCPUProperty(ks)) {
            if (isFullPowerMode()) {
                // 窗口修复: 恢复期只放行高值(>低功耗上限)的写入
                if (g_restoringFullPower) {
                    CFTypeRef val = CFDictionaryGetValue(properties, keys[i]);
                    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
                        int64_t numVal = 0;
                        if (CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &numVal) && numVal > lowPowerTargetValue()) {
                            continue; // 放行恢复写入
                        }
                    }
                }
                needsBlock = YES; // 拦截降频写入
            } else if (!g_restoringFullPower && shouldApplyLowPowerLimit()) {
                needsReplace = YES;
                if (!replacementDict) {
                    replacementDict = [NSMutableDictionary dictionary];
                    // 复制非 CPU 属性
                    for (CFIndex j = 0; j < count; j++) {
                        if (j == i) continue;
                        NSString *otherKey = (__bridge NSString *)keys[j];
                        if (otherKey) {
                            CFTypeRef val = CFDictionaryGetValue(properties, keys[j]);
                            if (val) replacementDict[otherKey] = (__bridge id)val;
                        }
                    }
                }
                CFTypeRef val = CFDictionaryGetValue(properties, keys[i]);
                CFTypeRef replacement = copyLowPowerFrequencyValueForKey(ks, val);
                if (replacement) {
                    replacementDict[ks] = (__bridge id)replacement;
                    CFRelease(replacement);
                }
            }
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

    if (needsReplace && replacementDict) {
        CFDictionaryRef cfReplacement = (__bridge CFDictionaryRef)[replacementDict copy];
        kern_return_t ret = orig_IOServiceSetProperties(service, cfReplacement);
        CFRelease(cfReplacement);
        return ret;
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

    // 防温控模式下拦截所有降频/功率控制操作
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
NSLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal, 功率模式:%@", isLowPowerMode() ? S("低功耗") : S("防温控"));
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
NSLog(@"[CPUthermal] 阻止决策树评估 (evaluateDecisionTree)");
return;
}
%orig;
}

// 热通知 — 可选择性阻断
- (void)updateThermalNotification:(id)notification {
if (g_enabled && g_suppressThermalNotifications) {
NSLog(@"[CPUthermal] 阻止热通知: %@", notification);
return;
}
%orig;
}

// 获取组件释放速率 — 游戏场景直接归零，避免任何降频释放
- (float)getReleaseRateForComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
NSLog(@"[CPUthermal] 阻止组件释放速率: %@", component);
return 0.01f;
}
return %orig(component);
}

// 散热/电池服务建议 — 关闭时返回 nil 屏蔽系统散热提示
// (适配自 fuckThermal 逆向还原分析)
- (id)getBatteryServiceSuggestion:(id)suggestion {
id result = %orig(suggestion);
if (g_enabled && g_suppressThermalNotifications) {
NSLog(@"[CPUthermal] 拦截 ThermalManager 散热建议");
return nil;
}
return result;
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

// ===============================================================
// 传感器温度读取拦截（核心改进 v3.1）
// 在防温控模式下让 thermalmonitord 读到"假低温"，
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

// 传感器组最大值 — GPU/NAND/充电等组件温度
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
NSLog(@"[CPUthermal] 阻止 actionComponentControl");
return;
}
%orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection()) {
NSLog(@"[CPUthermal] 阻止 readReleaseRateForAllComponents");
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
if (g_restoringFullPower) {
%orig(target, legacy, property);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(lowPowerTargetValue(), legacy, property);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerTargetValue(), legacy, property);
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
%orig(lowPowerPowerCeilingValue(), source);
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
%orig(0, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(fullPowerTargetValue(), source);
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
%orig(lowPowerTargetValue());
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
NSLog(@"[CPUthermal] 已应用低功耗配置: %@ target:%d (%lld-%lldMHz)", key, lowPowerTargetValue(), kLowPowerMinimumCapMHz, kLowPowerMaximumCapMHz);
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

NSLog(@"[CPUthermal] 已修改热配置表: %@", key);
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
NSLog(@"[CPUthermal] plist: maxCPULevel %d → 3", [maxCPU intValue]);
}
NSNumber *maxGPU = dict[S("maxGPULevel")];
if (maxGPU && [maxGPU intValue] < 3) {
dict[S("maxGPULevel")] = @3;
NSLog(@"[CPUthermal] plist: maxGPULevel %d → 3", [maxGPU intValue]);
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
NSLog(@"[CPUthermal] 功率模式已切换: %@", isLowPowerMode() ? S("低功耗") : S("防温控"));
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
NSLog(S("[CPUthermal] 收到唤醒/亮屏事件，准备恢复当前功率模式"));
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

// IOServiceSetProperties (复数) — 防止系统通过此路径绕过单数 hook
kern_return_t (*ptrSetProps)(io_service_t, CFDictionaryRef) = (kern_return_t (*)(io_service_t, CFDictionaryRef))dlsym(iokit, "IOServiceSetProperties");
if (ptrSetProps) {
MSHookFunction((void *)ptrSetProps, (void *)hooked_IOServiceSetProperties, (void **)&orig_IOServiceSetProperties);
NSLog(@"[CPUthermal] IOServiceSetProperties hook 已安装");
} else {
NSLog(@"[CPUthermal] 警告: 未找到 IOServiceSetProperties");
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
