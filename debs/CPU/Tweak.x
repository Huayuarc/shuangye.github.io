#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <limits.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <os/lock.h>
#import <mach/host_info.h>
#import <mach/task_info.h>
#import <sys/sysctl.h>

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
static BOOL g_enabled               = YES; // 总开关（始终启用，无需用户干预）
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

static const int kMinimumPlausibleCPUFrequencyMHz = 300;
static const int kMaximumPlausibleCPUFrequencyMHz = 6000;

// 解除温控模式 CPU 目标频率（MHz）— 优先读取用户输入，未配置时使用设备硬件上限
static int g_fullPowerMaxMHz = 0;

// setCPULowPowerTarget:/setMaxCPUPowerTarget: 使用 mW；65000 是 thermalmonitord 的无限制哨兵值。
// setCPULevel:/setCPUPowerCeiling:/setCPUPowerFloor:/setCPUPowerZoneTarget: 使用 0~100 百分比。
static const int kUnrestrictedPowerLimitMW = 65000;
static const int kLowPowerCPULevel = 2;
static const int kFullPowerCPULevel = 0;
static const int kCPUDecisionSourceCount = 6;
static const int kCPUDVD1ContributorCount = 4;

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_restoringFullPower = NO;
static BOOL g_fullPowerRecoveryPulseScheduled = NO;
static BOOL g_lowPowerApplyPulseScheduled = NO;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护g_powerMode
static NSHashTable *g_applePPMInstances = nil;           // 追踪 ApplePPMCPU 实例（弱引用，防止僵尸实例泄漏）

// 满血模式保活定时器 — 每 1.0 秒重应用一次，防止系统温控恢复
static dispatch_source_t g_fullPowerKeepAliveTimer = NULL;
static const double kFullPowerKeepAliveInterval = 1.0;

// 温度计警告 & 防暗屏（由设置面板控制）
static BOOL g_thermalBlockNotifPopup = YES;
static BOOL g_thermalPreventDimmingEnabled = YES;
// 兼容既有偏好键 cpuMinPowerValue：现在仅作为解除温控模式的高频目标 MHz。
static int g_cpuMinPowerValue = 0;

static BOOL shouldApplyLowPowerLimit(void);
static int targetCPUFrequencyMHz(void);
static int targetCPUPerformanceLevel(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(BOOL respectBootGuard);
static void scheduleFullPowerRecoveryPulse(void);
static void runFullPowerRecoveryPulse(int remainingPulses);
static void scheduleLowPowerApplyPulse(void);
static void runLowPowerApplyPulse(int remainingPulses);
static void applyCurrentModeToApplePPMCPU(void);
static void startFullPowerKeepAliveTimer(void);
static void stopFullPowerKeepAliveTimer(void);
static void reapplyTrackedCPUFrequencyTargets(void);
static void restoreTrackedCPUFrequencyTargets(void);
static void forceCPUPerformanceLevelOnController(id controller);
static void applyFullPowerBudgetsOnController(id controller);
static void applyLowPowerToCommonProduct(void);
static void applyLowPowerPerformancePreferenceToController(id controller);

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
return g_enabled && g_cpuProtection && isFullPowerMode();
}

static BOOL shouldApplyLowPowerLimit(void) {
return g_enabled && g_cpuProtection && isLowPowerMode();
}

static io_registry_entry_t copyPMGRDeviceTreeEntry(void) {
const char *paths[] = {
"IODeviceTree:/arm-io/pmgr",
"IODeviceTree:/arm-io/pmgr0",
NULL
};
for (int index = 0; paths[index]; index++) {
io_registry_entry_t entry = IORegistryEntryFromPath(kIOMasterPortDefault, paths[index]);
if (entry != MACH_PORT_NULL) return entry;
}
return MACH_PORT_NULL;
}

// 从 PMGR 的 voltage-states*-sram 中识别真实性能核频点。
// 每个条目由 little-endian uint32 频率(Hz) + uint32 电压/辅助值组成；
// 多张表中最大频率最高的一张即性能核 P-State 表，避免依赖设备型号硬编码。
static NSArray<NSNumber *> *performanceClusterFrequenciesMHz(void) {
static NSArray<NSNumber *> *s_frequencies = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
io_registry_entry_t pmgr = copyPMGRDeviceTreeEntry();
if (pmgr == MACH_PORT_NULL) {
s_frequencies = [NSArray array];
return;
}

CFMutableDictionaryRef propertiesRef = NULL;
kern_return_t result = IORegistryEntryCreateCFProperties(pmgr, &propertiesRef, kCFAllocatorDefault, 0);
IOObjectRelease(pmgr);
if (result != KERN_SUCCESS || !propertiesRef) {
s_frequencies = [NSArray array];
return;
}

NSDictionary *properties = CFBridgingRelease(propertiesRef);
NSArray<NSNumber *> *bestTable = nil;
NSString *bestKey = nil;
int bestMaxMHz = 0;
NSUInteger bestCount = 0;

for (id rawKey in properties) {
if (![rawKey isKindOfClass:[NSString class]]) continue;
NSString *key = (NSString *)rawKey;
NSString *lowerKey = [key lowercaseString];
if (![lowerKey hasPrefix:S("voltage-states")]) continue;

id rawValue = properties[key];
if (![rawValue isKindOfClass:[NSData class]]) continue;
NSData *data = (NSData *)rawValue;
if (data.length < 24) continue;

const uint8_t *bytes = (const uint8_t *)data.bytes;
const NSUInteger strides[] = {8, 12, 16};
for (NSUInteger strideIndex = 0; strideIndex < sizeof(strides) / sizeof(strides[0]); strideIndex++) {
NSUInteger stride = strides[strideIndex];
if ((data.length % stride) != 0 || data.length < stride * 3) continue;

NSMutableArray<NSNumber *> *candidate = [NSMutableArray array];
int previousMHz = 0;
BOOL monotonic = YES;
for (NSUInteger offset = 0; offset + stride <= data.length; offset += stride) {
uint32_t rawFrequency = 0;
memcpy(&rawFrequency, bytes + offset, sizeof(rawFrequency));
uint32_t frequencyHz = CFSwapInt32LittleToHost(rawFrequency);
int frequencyMHz = (int)((frequencyHz + 500000U) / 1000000U);
if (frequencyMHz < kMinimumPlausibleCPUFrequencyMHz ||
frequencyMHz > kMaximumPlausibleCPUFrequencyMHz) {
continue;
}
if (previousMHz > 0 && frequencyMHz < previousMHz) monotonic = NO;
if (frequencyMHz != previousMHz) {
[candidate addObject:[NSNumber numberWithInt:frequencyMHz]];
previousMHz = frequencyMHz;
}
}

if (!monotonic || candidate.count < 3) continue;
int candidateMaxMHz = [[candidate lastObject] intValue];
if (candidateMaxMHz > bestMaxMHz ||
(candidateMaxMHz == bestMaxMHz && candidate.count > bestCount)) {
bestMaxMHz = candidateMaxMHz;
bestCount = candidate.count;
bestTable = [candidate copy];
bestKey = key;
}
}
}

s_frequencies = bestTable ?: [NSArray array];
if (s_frequencies.count > 0) {
NSLog(S("[CPUthermal] 已识别性能核 P-State 表 %@: %@ MHz"), bestKey, s_frequencies);
} else {
NSLog(S("[CPUthermal] 未能从 PMGR 识别性能核 P-State 表，将使用兼容回退"));
}
});
return s_frequencies;
}

static int nearestSupportedCPUFrequencyMHz(int requestedMHz) {
if (requestedMHz <= 0) return requestedMHz;
NSArray<NSNumber *> *frequencies = performanceClusterFrequenciesMHz();
if (frequencies.count == 0) return requestedMHz;

int bestMHz = [frequencies[0] intValue];
int bestDistance = abs(bestMHz - requestedMHz);
for (NSNumber *frequency in frequencies) {
int candidateMHz = [frequency intValue];
int distance = abs(candidateMHz - requestedMHz);
if (distance < bestDistance || (distance == bestDistance && candidateMHz > bestMHz)) {
bestMHz = candidateMHz;
bestDistance = distance;
}
}
return bestMHz;
}

// 芯片硬件主频查表 (MHz) — 仅作为设备树与 sysctl 动态读取失败时的兜底
static int getFallbackMaxFrequencyForMachine(NSString *machine) {
if ([machine hasPrefix:S("iPhone8,")]) return 1850;  // A9
if ([machine hasPrefix:S("iPhone9,")]) return 2340;  // A10
if ([machine hasPrefix:S("iPhone10,")]) return 2390; // A11 (iPhone 8 / 8P / X)
if ([machine hasPrefix:S("iPhone11,")]) return 2490; // A12 (iPhone XS / XR)
if ([machine hasPrefix:S("iPhone12,")]) return 2650; // A13 (iPhone 11 系列)
if ([machine hasPrefix:S("iPhone13,")]) return 3100; // A14 (iPhone 12 系列)
if ([machine hasPrefix:S("iPhone14,")]) return 3240; // A15 (iPhone 13 系列 / 14 / 14 Plus)
if ([machine hasPrefix:S("iPhone15,2")] || [machine hasPrefix:S("iPhone15,3")]) return 3460; // A16 (iPhone 14 Pro / 15)
if ([machine hasPrefix:S("iPhone15,4")] || [machine hasPrefix:S("iPhone15,5")]) return 3460; // A16 (iPhone 15 Plus)
if ([machine hasPrefix:S("iPhone16,")]) return 3780; // A17 Pro (iPhone 15 Pro 系列)
if ([machine hasPrefix:S("iPhone17,")]) return 4040; // A18 / A18 Pro (iPhone 16 系列)
if ([machine hasPrefix:S("iPod9,")]) return 2340;     // A10
if ([machine hasPrefix:S("iPad11,")]) return 2490;   // A12
if ([machine hasPrefix:S("iPad12,")]) return 2650;   // A13
if ([machine hasPrefix:S("iPad13,")]) return 3200;   // A14 / M1
if ([machine hasPrefix:S("iPad14,1")] || [machine hasPrefix:S("iPad14,2")]) return 3240; // A15
if ([machine hasPrefix:S("iPad14,")]) return 3490;   // M2
return 0; // 匹配不到则返回 0，交由外层逻辑处理
}

static int hardwareMaxFrequencyMHz(void) {
static int s_hardwareMaxMHz = 0;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
NSArray<NSNumber *> *frequencies = performanceClusterFrequenciesMHz();
if (frequencies.count > 0) {
s_hardwareMaxMHz = [[frequencies lastObject] intValue];
return;
}

uint64_t freqHz = 0;
const char *frequencyNames[] = {
"hw.cpufrequnrestricted",
"hw.cpufrequency_max",
"hw.cpufreq_max",
"hw.cpufreq",
NULL
};
for (int index = 0; frequencyNames[index]; index++) {
size_t size = sizeof(freqHz);
freqHz = 0;
if (sysctlbyname(frequencyNames[index], &freqHz, &size, NULL, 0) == 0 && freqHz > 0) break;
}

if (freqHz > 0) {
s_hardwareMaxMHz = freqHz >= 100000000ULL
? (int)(freqHz / 1000000ULL)
: (freqHz >= 100000ULL ? (int)(freqHz / 1000ULL) : (int)freqHz);
} else {
// 兜底：若 sysctl 失败，尝试通过设备型号查表
char machineChar[32] = {0};
size_t mSize = sizeof(machineChar);
if (sysctlbyname("hw.machine", machineChar, &mSize, NULL, 0) == 0) {
NSString *machine = [NSString stringWithUTF8String:machineChar];
s_hardwareMaxMHz = getFallbackMaxFrequencyForMachine(machine);
}
}
});

return s_hardwareMaxMHz;
}

static int fullPowerFrequencyValue(void) {
int hardwareMaxMHz = hardwareMaxFrequencyMHz();
int configuredMHz = g_cpuMinPowerValue > 0 ? g_cpuMinPowerValue : g_fullPowerMaxMHz;
if (configuredMHz > 0 &&
(configuredMHz < kMinimumPlausibleCPUFrequencyMHz || configuredMHz > kMaximumPlausibleCPUFrequencyMHz)) {
configuredMHz = 0;
}
if (configuredMHz <= 0) configuredMHz = hardwareMaxMHz;
if (hardwareMaxMHz > 0 && configuredMHz > hardwareMaxMHz) configuredMHz = hardwareMaxMHz;
return nearestSupportedCPUFrequencyMHz(configuredMHz);
}

static int targetCPUFrequencyMHz(void) {
if (!isFullPowerMode()) return 0;
return fullPowerFrequencyValue();
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
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, source);
}
}
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
if (!controller || !g_enabled || !g_cpuProtection) return;
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
if (!controller || !g_enabled || !g_cpuProtection) return;
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 0);
}
if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), kUnrestrictedPowerLimitMW);
}
if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
sendSetMaxCPUPowerTarget(controller, kUnrestrictedPowerLimitMW, NO);
}
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW, source);
}
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW, source);
}
}
for (int contributor = 0; contributor < kCPUDVD1ContributorCount; contributor++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), kUnrestrictedPowerLimitMW, contributor);
}
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), kUnrestrictedPowerLimitMW);
}
if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
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
if (!controller || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
g_restoringFullPower = YES;
applyFullPowerBudgetsOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
NSLog(@"[CPUthermal] 已主动恢复解除温控 CPU 锁定: %dMHz level:%d controller:%@", targetCPUFrequencyMHz(), targetCPUPerformanceLevel(), controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 恢复解除温控 CPU 上限失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void restoreFullPowerToTrackedControllers(void) {
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@autoreleasepool {
NSArray *controllers = trackedPowerControllersSnapshot();
for (id controller in controllers) {
restoreFullPowerToController(controller);
}
}
}

static void setCommonProductCeiling(SEL selector, int ceiling) {
if (!g_commonProduct || ![g_commonProduct respondsToSelector:selector]) return;
((void (*)(id, SEL, int, id))objc_msgSend)(g_commonProduct, selector, ceiling, S("CPUthermal"));
}

static void applyLowPowerToCommonProduct(void) {
if (!g_commonProduct || !shouldApplyLowPowerLimit()) return;
@try {
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), YES);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), kLowPowerCPULevel);
}
setCommonProductCeiling(@selector(setCPUPowerFloor:fromDecisionSource:), 0);
if ([g_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
((void (*)(id, SEL))objc_msgSend)(g_commonProduct, @selector(tryTakeAction));
}
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 即时套用低功耗 CommonProduct 状态失败: %@", exception);
}
}

static void applyFullPowerToCommonProduct(void) {
if (!g_commonProduct || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
g_restoringFullPower = YES;
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
// CommonProduct 的 ceiling/floor 同样是 0~100 百分比，不是 mW。
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW);
setCommonProductCeiling(@selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW);
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

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime(YES);
}

static void applyPowerModeToRuntime(BOOL respectBootGuard) {
if (!g_enabled || !g_cpuProtection) return;
(void)respectBootGuard;
if (isLowPowerMode()) {
stopFullPowerKeepAliveTimer();
restoreTrackedCPUFrequencyTargets();
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleLowPowerApplyPulse();
return;
}
if (isFullPowerMode()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
scheduleFullPowerRecoveryPulse();
startFullPowerKeepAliveTimer();  // 启动满血保活定时器
}
}

static void scheduleFullPowerRecoveryPulse(void) {
if (g_fullPowerRecoveryPulseScheduled || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
g_fullPowerRecoveryPulseScheduled = YES;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runFullPowerRecoveryPulse(10);
});
}

static void runFullPowerRecoveryPulse(int remainingPulses) {
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection || !isFullPowerMode()) {
g_fullPowerRecoveryPulseScheduled = NO;
return;
}
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
if (remainingPulses <= 1) {
g_fullPowerRecoveryPulseScheduled = NO;
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runFullPowerRecoveryPulse(remainingPulses - 1);
});
}

static void scheduleLowPowerApplyPulse(void) {
if (g_lowPowerApplyPulseScheduled || !g_enabled || !g_cpuProtection || !isLowPowerMode()) return;
g_lowPowerApplyPulseScheduled = YES;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runLowPowerApplyPulse(10);
});
}

static void runLowPowerApplyPulse(int remainingPulses) {
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection || !isLowPowerMode()) {
g_lowPowerApplyPulseScheduled = NO;
return;
}
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
if (remainingPulses <= 1) {
g_lowPowerApplyPulseScheduled = NO;
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runLowPowerApplyPulse(remainingPulses - 1);
});
}


static void applyCurrentModeToApplePPMCPU(void) {
if (!g_enabled || !g_cpuProtection) return;
NSArray *instances = trackedApplePPMInstancesSnapshot();
for (id ppm in instances) {
if (!ppm) continue;
if ([ppm respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
if ([ppm respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(ppm, @selector(updateCPU));
}
}
}

// ============================================================================
// 满血模式保活定时器 — 每 1.5 秒重应用一次，防止系统温控恢复
// ============================================================================
static void startFullPowerKeepAliveTimer(void) {
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) {
stopFullPowerKeepAliveTimer();
return;
}
if (g_fullPowerKeepAliveTimer) return;

g_fullPowerKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
if (!g_fullPowerKeepAliveTimer) return;

dispatch_source_set_timer(g_fullPowerKeepAliveTimer,
dispatch_walltime(NULL, 0),  // 使用墙上时钟，深睡后唤醒会立即补触发
(int64_t)(kFullPowerKeepAliveInterval * NSEC_PER_SEC),
0);  // leeway=0，最大限度缩短定时偏移

dispatch_source_set_event_handler(g_fullPowerKeepAliveTimer, ^{
// 使用缓存状态，不读磁盘
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) {
stopFullPowerKeepAliveTimer();
return;
}

// 强制热压力 Nominal + 重置热通知级别
CPUthermalForceNominalCombined();
// 重新套用 CommonProduct 满血状态
applyFullPowerToCommonProduct();
// 恢复所有已知控制器到满血状态
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
});

dispatch_resume(g_fullPowerKeepAliveTimer);
NSLog(@"[CPUthermal] 满血保活定时器已启动 (每 %.1fs)", kFullPowerKeepAliveInterval);
}

static void stopFullPowerKeepAliveTimer(void) {
if (g_fullPowerKeepAliveTimer) {
dispatch_source_cancel(g_fullPowerKeepAliveTimer);
#if !OS_OBJECT_USE_OBJC
dispatch_release(g_fullPowerKeepAliveTimer);
#endif
g_fullPowerKeepAliveTimer = NULL;
NSLog(@"[CPUthermal] 满血保活定时器已停止");
}
}

static BOOL keyMatchesCPUFrequencyTarget(NSString *key) {
if (!key) return NO;
NSString *lower = [key lowercaseString];
BOOL isCPUKey = [lower containsString:S("cpu")] ||
[lower containsString:S("ppm")] ||
[lower containsString:S("processor")];
BOOL isFrequencyKey = [lower containsString:S("freq")] ||
[lower containsString:S("frequency")];
return isCPUKey && isFrequencyKey;
}

static int64_t frequencyValueFromMHz(int64_t mhz, int64_t originalValue) {
int64_t magnitude = llabs(originalValue);
if (magnitude >= 100000000LL) return mhz * 1000000LL;
if (magnitude >= 100000LL) return mhz * 1000LL;
return mhz;
}

static int64_t lockedFrequencyValue(int64_t value, int64_t targetMHz) {
return frequencyValueFromMHz(targetMHz, value);
}

static CFTypeRef copyLockedFrequencyValueForKey(NSString *key, CFTypeRef originalValue, int64_t targetMHz) {
if (!isFullPowerMode() || !keyMatchesCPUFrequencyTarget(key) || targetMHz <= 0) return NULL;

int64_t original = targetMHz;
if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
}

int64_t replacement = lockedFrequencyValue(original, targetMHz);
return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacement);
}

static CFDictionaryRef copyLockedFrequencyProperties(CFTypeRef properties, int64_t targetMHz) {
if (!isFullPowerMode() || !properties || CFGetTypeID(properties) != CFDictionaryGetTypeID() || targetMHz <= 0) return NULL;
NSDictionary *source = (__bridge NSDictionary *)properties;
NSMutableDictionary *locked = [source mutableCopy];
BOOL changed = NO;
for (id rawKey in source) {
if (![rawKey isKindOfClass:[NSString class]]) continue;
CFTypeRef replacement = copyLockedFrequencyValueForKey(rawKey, (__bridge CFTypeRef)source[rawKey], targetMHz);
if (!replacement) continue;
locked[rawKey] = CFBridgingRelease(replacement);
changed = YES;
}
return changed ? CFBridgingRetain(locked) : NULL;
}

#define MAX_TRACKED_CPU_FREQUENCY_TARGETS 32

typedef struct {
io_registry_entry_t entry;
CFStringRef key;
int64_t sampleValue;
} CPUFrequencyTarget;

static CPUFrequencyTarget g_cpuFrequencyTargets[MAX_TRACKED_CPU_FREQUENCY_TARGETS];
static int g_cpuFrequencyTargetCount = 0;
static os_unfair_lock g_cpuFrequencyTargetLock = OS_UNFAIR_LOCK_INIT;
static __thread BOOL g_writingTrackedCPUFrequencyTarget = NO;

static void trackCPUFrequencyTarget(io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
if (g_writingTrackedCPUFrequencyTarget || entry == MACH_PORT_NULL || !key || !value || CFGetTypeID(value) != CFNumberGetTypeID()) return;
NSString *keyString = (__bridge NSString *)key;
if (!keyMatchesCPUFrequencyTarget(keyString)) return;

int64_t sampleValue = 0;
if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &sampleValue)) return;

os_unfair_lock_lock(&g_cpuFrequencyTargetLock);
for (int index = 0; index < g_cpuFrequencyTargetCount; index++) {
CPUFrequencyTarget *target = &g_cpuFrequencyTargets[index];
if (target->entry == entry && CFEqual(target->key, key)) {
target->sampleValue = sampleValue;
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);
return;
}
}
BOOL hasCapacity = g_cpuFrequencyTargetCount < MAX_TRACKED_CPU_FREQUENCY_TARGETS;
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);
if (!hasCapacity) return;

CFStringRef keyCopy = CFStringCreateCopy(kCFAllocatorDefault, key);
if (!keyCopy) return;
if (IOObjectRetain(entry) != KERN_SUCCESS) {
CFRelease(keyCopy);
return;
}

os_unfair_lock_lock(&g_cpuFrequencyTargetLock);
for (int index = 0; index < g_cpuFrequencyTargetCount; index++) {
CPUFrequencyTarget *target = &g_cpuFrequencyTargets[index];
if (target->entry == entry && CFEqual(target->key, keyCopy)) {
target->sampleValue = sampleValue;
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);
IOObjectRelease(entry);
CFRelease(keyCopy);
return;
}
}
if (g_cpuFrequencyTargetCount < MAX_TRACKED_CPU_FREQUENCY_TARGETS) {
CPUFrequencyTarget *target = &g_cpuFrequencyTargets[g_cpuFrequencyTargetCount++];
target->entry = entry;
target->key = keyCopy;
target->sampleValue = sampleValue;
keyCopy = NULL;
}
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);

if (keyCopy) {
IOObjectRelease(entry);
CFRelease(keyCopy);
}
}

static void trackCPUFrequencyProperties(io_registry_entry_t entry, CFTypeRef properties) {
if (g_writingTrackedCPUFrequencyTarget || entry == MACH_PORT_NULL || !properties || CFGetTypeID(properties) != CFDictionaryGetTypeID()) return;
NSDictionary *dictionary = (__bridge NSDictionary *)properties;
for (id rawKey in dictionary) {
if (![rawKey isKindOfClass:[NSString class]]) continue;
trackCPUFrequencyTarget(entry, (__bridge CFStringRef)rawKey, (__bridge CFTypeRef)dictionary[rawKey]);
}
}

static void reapplyTrackedCPUFrequencyTargets(void) {
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
int targetMHz = targetCPUFrequencyMHz();
if (targetMHz <= 0) return;

CPUFrequencyTarget snapshot[MAX_TRACKED_CPU_FREQUENCY_TARGETS] = {0};
int snapshotCount = 0;

os_unfair_lock_lock(&g_cpuFrequencyTargetLock);
snapshotCount = g_cpuFrequencyTargetCount;
for (int index = 0; index < snapshotCount; index++) {
snapshot[index] = g_cpuFrequencyTargets[index];
IOObjectRetain(snapshot[index].entry);
CFRetain(snapshot[index].key);
}
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);

for (int index = 0; index < snapshotCount; index++) {
int64_t replacementValue = lockedFrequencyValue(snapshot[index].sampleValue, targetMHz);
CFNumberRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacementValue);
if (replacement) {
g_writingTrackedCPUFrequencyTarget = YES;
IORegistryEntrySetCFProperty(snapshot[index].entry, snapshot[index].key, replacement);
g_writingTrackedCPUFrequencyTarget = NO;
CFRelease(replacement);
}
CFRelease(snapshot[index].key);
IOObjectRelease(snapshot[index].entry);
}
}

static void restoreTrackedCPUFrequencyTargets(void) {
if (!g_enabled || !g_cpuProtection || !isLowPowerMode()) return;

CPUFrequencyTarget snapshot[MAX_TRACKED_CPU_FREQUENCY_TARGETS] = {0};
int snapshotCount = 0;

os_unfair_lock_lock(&g_cpuFrequencyTargetLock);
snapshotCount = g_cpuFrequencyTargetCount;
for (int index = 0; index < snapshotCount; index++) {
snapshot[index] = g_cpuFrequencyTargets[index];
IOObjectRetain(snapshot[index].entry);
CFRetain(snapshot[index].key);
}
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);

int restoredCount = 0;
for (int index = 0; index < snapshotCount; index++) {
CFNumberRef originalValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &snapshot[index].sampleValue);
if (originalValue) {
g_writingTrackedCPUFrequencyTarget = YES;
kern_return_t result = IORegistryEntrySetCFProperty(snapshot[index].entry, snapshot[index].key, originalValue);
g_writingTrackedCPUFrequencyTarget = NO;
if (result == KERN_SUCCESS) restoredCount++;
CFRelease(originalValue);
}
CFRelease(snapshot[index].key);
IOObjectRelease(snapshot[index].entry);
}

NSLog(@"[CPUthermal] 低功耗切换已释放解除温控频率锁: %d/%d", restoredCount, snapshotCount);
}

static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
// 关键修复：读取失败时立即返回，保留当前内存中正确的 g_powerMode，防止回退到解除温控
if (!d || d.count == 0) return;

g_enabled = YES;
g_thermalBlockNotifPopup = [d[S("thermalBlockNotifPopup")] ?: @YES boolValue];
g_thermalPreventDimmingEnabled = [d[S("thermalPreventDimmingEnabled")] ?: @YES boolValue];

NSNumber *prefFullMax = d[S("fullPowerMaxMHz")];
if (prefFullMax) g_fullPowerMaxMHz = [prefFullMax intValue];

g_cpuMinPowerValue = [d[S("cpuMinPowerValue")] intValue];
if (g_cpuMinPowerValue < 0) g_cpuMinPowerValue = 0;

NSString *mode = d[S("powerMode")];
if (mode && [mode isKindOfClass:[NSString class]]) {
os_unfair_lock_lock(&g_modeLock);
g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
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
os_unfair_lock_lock(&g_connLock);
if (g_connCount < MAX_CONN) {
g_conns[g_connCount].conn     = conn;
g_conns[g_connCount].isThermal = thermal;
g_connCount++;
}
os_unfair_lock_unlock(&g_connLock);
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

// --- IOServiceClose — 清理已断开的 thermal connection（防止 g_conns 数组溢出后拦截失效）---
%hookf(kern_return_t, IOServiceClose, io_connect_t connect) {
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
return %orig;
}

// 异步与结构体调用必须放行，否则 ObjC 层强制后的目标也无法真正写入 ApplePPM。
%hookf(kern_return_t, IOConnectCallAsyncMethod, mach_port_t connection, uint32_t selector, mach_port_t wakePort, mach_port_t *asyncRef, uint32_t asyncRefCnt, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
return %orig;
}

%hookf(kern_return_t, IOConnectCallStructMethod, mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
return %orig;
}

// --- IOServiceSetProperty — 阻止写降频/降亮度属性 ---
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

// ===================== 新增：拦截Wi‑Fi/蜂窝基带射频温控限流 =====================
if (isNetworkThrottleProperty(key)) {
NSLog(@"[CPUthermal] 已屏蔽网络射频热节流指令: %@", (__bridge NSString *)key);
return KERN_SUCCESS; // 直接丢弃指令，不写入驱动，取消限流
}
// ==========================================================================

NSString *ks = (__bridge NSString *)key;

// 仅改写真正的 CPU frequency 字段。CPU power/level 字段必须原样放行，
// 否则会把 MitigationController 刚计算出的锁定目标一起吞掉。
if (g_cpuProtection && keyMatchesCPUFrequencyTarget(ks)) {
trackCPUFrequencyTarget(service, key, value);
CFTypeRef replacement = copyLockedFrequencyValueForKey(ks, value, targetCPUFrequencyMHz());
if (replacement) {
kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
CFRelease(replacement);
return ret;
}
}
return orig_IOServiceSetProperty(service, key, value);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
if (!g_enabled) return %orig(entry, key, value);
if (isNetworkThrottleProperty(key)) return KERN_SUCCESS;
NSString *keyString = (__bridge NSString *)key;
if (g_cpuProtection && keyMatchesCPUFrequencyTarget(keyString)) {
trackCPUFrequencyTarget(entry, key, value);
CFTypeRef replacement = copyLockedFrequencyValueForKey(keyString, value, targetCPUFrequencyMHz());
if (replacement) {
kern_return_t result = %orig(entry, key, replacement);
CFRelease(replacement);
return result;
}
}
return %orig(entry, key, value);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperties, io_registry_entry_t entry, CFTypeRef properties) {
if (!g_enabled || !g_cpuProtection) return %orig(entry, properties);
trackCPUFrequencyProperties(entry, properties);
CFDictionaryRef replacement = copyLockedFrequencyProperties(properties, targetCPUFrequencyMHz());
if (!replacement) return %orig(entry, properties);
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
// 强制热压力为 Nominal（正常温度）
CPUthermalForceNominalCombined();
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
%orig(NO);   // 满血模式关闭 CPMS
return;
}
%orig(enabled);
}

// 强制 CPU 性能百分比，防止外部代码覆盖当前模式的锁定目标。
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
%orig(targetCPUPerformanceLevel());
return;
}
%orig(level);
}

%end

// --- HidSensors: HID 温度事件处理（与「屏蔽高温温度计警告」共用开关）---
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {
if (g_enabled && g_thermalBlockNotifPopup) {
return;
}
%orig;
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层）
//
// 冲突避免说明:
//   - 传感器读数 getHighestSkinTemp/dieTempFilteredMaxAverage/thermalSensorValuesMaxFromIndexSet
//     不在此处 hook (IOKit 层已拦截)
//   - putDeviceInThermalSimulationMode: 不 hook (CPUthermal 自已调用会递归)
//   - setCPMSMitigationState: 不 hook (IOKit 层已拦截 selector 0x40-0x5F)
//   - setHiPFeatureEnabled: 不 hook
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
// 全功率模式: 阻止决策树运行，避免温控降频
if (shouldApplyFullCPUProtection()) {
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 阻止决策树评估 (全功率模式)");
return;
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
NSLog(@"[CPUthermal] 彻底拦截释放速率: %@ -> 0.0", component);
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
if (shouldApplyFullCPUProtection()) {
return NO;
}
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
%orig;
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
%orig;
}

// 计算控制力度 — 这是 throttle 量的核心
// soften 模式下减半但不归零，保留基础调节能力
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
if (shouldApplyFullCPUProtection()) {
NSLog(@"[CPUthermal] 彻底拦截控制力度: 返回 0.0");
return 0.0;  // 彻底归零，不降频
}
return %orig(trigger, arg2);
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
%orig(targetCPUPerformanceLevel());
return;
}
%orig;
}

- (void)updateCPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
if (self && [self respondsToSelector:@selector(setCPULevel:)]) {
[self setCPULevel:targetCPUPerformanceLevel()];
}
%orig;
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
if (shouldApplyFullCPUProtection()) {
return NO;
}
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

// MitigationController 的 CPULevel 是 0~100 百分比，统一锁到当前模式目标。
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

- (void)setDVD1Level:(int)level {
if (g_restoringFullPower) {
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
trackPowerController(self);
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
trackPowerController(self);
applyFullPowerBudgetsOnController(self);
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
%orig;  // 放行，让 GPU 功率目标正常更新
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
%orig;  // 放行，让 Package 功率目标正常更新
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
%orig(MAX(target, kUnrestrictedPowerLimitMW));
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
[self setPowerSaveActive:NO];
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
%orig(target, legacy, propertyArg);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(kUnrestrictedPowerLimitMW, legacy, propertyArg);
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
%orig(ceiling, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(MAX(ceiling, kUnrestrictedPowerLimitMW), source);
return;
}
%orig;
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
%orig(MAX(ceiling, kUnrestrictedPowerLimitMW), contributor);
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
%orig(floor, source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(MAX(floor, kUnrestrictedPowerLimitMW), source);
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
%orig(target);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(MAX(target, kUnrestrictedPowerLimitMW));
return;
}
%orig;
}

%end

// ============================================================================
// 防温控暗屏 — 修补热配置 plist 中的背光参数
// 由 thermalPreventDimmingEnabled 开关控制
// ============================================================================

// 补丁热配置字典：仅处理背光。backlight max/minThermalPower 不是 CPU MHz。
static NSDictionary *patchThermalPlist(NSDictionary *dict) {
if (!g_thermalPreventDimmingEnabled) return dict;

NSMutableDictionary *mutableDict = [dict mutableCopy];

// Patch backlight component control
NSDictionary *backlight = mutableDict[S("backlightComponentControl")];
if ([backlight isKindOfClass:[NSDictionary class]]) {
NSMutableDictionary *mutableBacklight = [backlight mutableCopy];

if (g_thermalPreventDimmingEnabled) {
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
}

mutableDict[S("backlightComponentControl")] = mutableBacklight;

NSLog(@"[CPUthermal] 已修补热配置: 防温控暗屏=%d", g_thermalPreventDimmingEnabled);
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

// _getConfigurationFor 替换实现：调用原始函数后应用热配置补丁（防温控暗屏）
static NSDictionary *new_getConfigurationFor(NSString *key) {
    NSDictionary *config = orig_getConfigurationFor ? orig_getConfigurationFor(key) : nil;
    return patchThermalPlist(config);
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
dispatch_block_t block = ^{
loadPrefs();
applyPowerModeToRuntime(NO);
NSLog(S("[CPUthermal] 功率模式已切换: %@ target:%dMHz level:%d"),
isLowPowerMode() ? S("低功耗") : S("解除温控"),
targetCPUFrequencyMHz(), targetCPUPerformanceLevel());
};
if ([NSThread isMainThread]) block();
else dispatch_async(dispatch_get_main_queue(), block);
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
loadPrefs();
if (g_enabled) applyPowerModeToRuntime(NO);
NSLog(S("[CPUthermal] 设置已重载 enabled:%d CPU:%d 弹窗:%d 防暗屏:%d target:%dMHz level:%d"),
g_enabled, g_cpuProtection, g_thermalBlockNotifPopup, g_thermalPreventDimmingEnabled,
targetCPUFrequencyMHz(), targetCPUPerformanceLevel());
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

// 强制系统热压力为 Nominal 并重置热通知级别
CPUthermalForceNominalCombined();

NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:已禁用 CPU性能:%d",
g_cpuProtection);

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

applyCurrentPowerModeToRuntime();
NSLog(@"[CPUthermal] 启动完成，当前功率模式:%@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
}
