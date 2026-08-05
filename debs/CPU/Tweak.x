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

// 低功耗模式期望目标（MHz）；运行时会按设备真实性能核 P-State 选择最接近档位。
static const int kLowPowerRequestedFrequencyMHz = 1380;
static const int kMinimumPlausibleCPUFrequencyMHz = 300;
static const int kMaximumPlausibleCPUFrequencyMHz = 6000;

// 解除温控模式 CPU 目标频率（MHz）— 优先读取用户输入，未配置时使用设备硬件上限
static int g_fullPowerMaxMHz = 0;

// setCPULowPowerTarget:/setMaxCPUPowerTarget: 使用 mW；65000 是 thermalmonitord 的无限制哨兵值。
// setCPULevel:/setCPUPowerCeiling:/setCPUPowerFloor:/setCPUPowerZoneTarget: 使用 0~100 百分比。
static const int kUnrestrictedPowerLimitMW = 65000;
static const int kCPUPerformanceLevelMin = 1;
static const int kCPUPerformanceLevelMax = 100;
static const int kCPUDecisionSourceCount = 6;
static const int kCPUDVD1ContributorCount = 4;

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_restoringFullPower = NO;
static BOOL g_applyingLowPower = NO;
static NSMutableDictionary *g_originalControllerValues = nil;
static CFAbsoluteTime g_processStartTime = 0;
static const double kFullPowerBootGuardDuration = 0.0;
static BOOL g_deferredRuntimeApplyScheduled = NO;
static BOOL g_fullPowerRecoveryPulseScheduled = NO;
static BOOL g_lowPowerApplyPulseScheduled = NO;
static BOOL g_wakeRuntimeApplyScheduled = NO;

// 持久性低功耗保持定时器
static dispatch_source_t g_lowPowerKeepAliveTimer = NULL;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护g_powerMode
static const double kLowPowerKeepAliveInterval = 1.0;  // 每1.0s秒重应用一次，缩短周期防止频率漂移
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
static void scheduleDeferredRuntimeApply(double delay);
static void scheduleLowPowerApplyPulse(void);
static void runLowPowerApplyPulse(int remainingPulses);
static void scheduleFullPowerRecoveryPulse(void);
static void runFullPowerRecoveryPulse(int remainingPulses);
static void scheduleWakeRuntimeApply(void);
static void runWakeRuntimeApplyPulse(int remainingPulses);
static void startLowPowerKeepAliveTimer(void);
static void stopLowPowerKeepAliveTimer(void);
static void applyCurrentModeToApplePPMCPU(void);
static void startFullPowerKeepAliveTimer(void);
static void stopFullPowerKeepAliveTimer(void);
static void forceCPUPerformanceLevelOnController(id controller);
static void clearSystemLowPowerBudgetsOnController(id controller);

static NSString *controllerKey(id controller, const char *name) {
return [NSString stringWithFormat:S("%p:%s"), controller, name];
}

static void rememberOriginalIntValue(id controller, const char *name, int value) {
if (!controller || g_restoringFullPower || !shouldApplyLowPowerLimit()) return;
NSString *key = controllerKey(controller, name);
if (!key) return;
os_unfair_lock_lock(&g_controllerLock);
if (!g_originalControllerValues) g_originalControllerValues = [NSMutableDictionary dictionary];
if (![g_originalControllerValues objectForKey:key]) {
[g_originalControllerValues setObject:[NSNumber numberWithInt:value] forKey:key];
}
os_unfair_lock_unlock(&g_controllerLock);
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

static BOOL fullPowerBootGuardActive(void) {
// 修复③：关闭开机启动保护测试，排除开机窗口期逻辑干扰
return NO;
}

static BOOL shouldApplyFullCPUProtection(void) {
return g_enabled && g_cpuProtection && isFullPowerMode() && !fullPowerBootGuardActive();
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

static int supportedCPUFrequencyAtOrBelowMHz(int requestedMHz) {
if (requestedMHz <= 0) return requestedMHz;
NSArray<NSNumber *> *frequencies = performanceClusterFrequenciesMHz();
if (frequencies.count == 0) return requestedMHz;

int selectedMHz = [frequencies[0] intValue];
for (NSNumber *frequency in frequencies) {
int candidateMHz = [frequency intValue];
if (candidateMHz > requestedMHz) break;
selectedMHz = candidateMHz;
}
return selectedMHz;
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
if (isLowPowerMode()) {
return supportedCPUFrequencyAtOrBelowMHz(kLowPowerRequestedFrequencyMHz);
}
return fullPowerFrequencyValue();
}

static int targetCPUPerformanceLevel(void) {
int targetMHz = targetCPUFrequencyMHz();
int hardwareMaxMHz = hardwareMaxFrequencyMHz();
if (targetMHz <= 0 || hardwareMaxMHz <= 0) {
return isLowPowerMode() ? 43 : kCPUPerformanceLevelMax;
}

int64_t scaled = ((int64_t)targetMHz * kCPUPerformanceLevelMax + hardwareMaxMHz / 2) / hardwareMaxMHz;
if (scaled < kCPUPerformanceLevelMin) scaled = kCPUPerformanceLevelMin;
if (scaled > kCPUPerformanceLevelMax) scaled = kCPUPerformanceLevelMax;
return (int)scaled;
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

// thermalmonitord 的 CPULevel/PowerZoneTarget 是 0~100 的性能百分比，不是 P-State 编号；
// CPULowPowerTarget/MaxCPUPowerTarget 才是 mW。锁频时把所有 CPU ceiling/floor 决策源固定到
// 同一个百分比，再由系统按最大功率换算后写入 ApplePPM，避免 MHz、百分比与 mW 混用。
static void forceCPUPerformanceLevelOnController(id controller) {
if (!controller || !g_enabled || !g_cpuProtection) return;
int targetLevel = targetCPUPerformanceLevel();

if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), targetLevel);
}
if ([controller respondsToSelector:@selector(setDVD1Level:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setDVD1Level:), targetLevel);
}
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), targetLevel, source);
}
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerFloor:fromDecisionSource:), targetLevel, source);
}
}
for (int contributor = 0; contributor < kCPUDVD1ContributorCount; contributor++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), targetLevel, contributor);
}
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), targetLevel);
}
}

// 系统内置 PowerSave 会套用设备热配置中的 PackageLowPowerTarget（A15 为 2000mW），
// 它会覆盖自定义 CPU 等级并把频率压到最低档。两种模式都关闭该状态，低功耗仅靠
// CPU level/ceiling/floor 实现，不限制 GPU，也不继承系统低功耗包预算。
static void clearSystemLowPowerBudgetsOnController(id controller) {
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
if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
}
}

// 仅设置低功耗钳制 setter，不触发 updateCPU/updatePackage。
// 供保活定时器与 updateCPU/updatePackage 钩子复用，避免递归。
static void forceLowPowerSettersOnController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
clearSystemLowPowerBudgetsOnController(controller);
forceCPUPerformanceLevelOnController(controller);
}

static void applyLowPowerLimitToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
@try {
g_applyingLowPower = YES;
forceLowPowerSettersOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
NSLog(@"[CPUthermal] 已主动下发低功耗 CPU 锁定: %dMHz level:%d controller:%@", targetCPUFrequencyMHz(), targetCPUPerformanceLevel(), controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 下发低功耗 CPU 限制失败: %@", exception);
} @finally {
g_applyingLowPower = NO;
}
}

static void applyLowPowerLimitsToTrackedControllers(void) {
if (!shouldApplyLowPowerLimit()) return;
@autoreleasepool {
NSArray *controllers = trackedPowerControllersSnapshot();
for (id controller in controllers) {
applyLowPowerLimitToController(controller);
}
}
}

static void restoreFullPowerToController(id controller) {
if (!controller || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
g_restoringFullPower = YES;
clearSystemLowPowerBudgetsOnController(controller);
forceCPUPerformanceLevelOnController(controller);
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
os_unfair_lock_lock(&g_controllerLock);
[g_originalControllerValues removeAllObjects];
os_unfair_lock_unlock(&g_controllerLock);
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
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
// CommonProduct 的 ceiling/floor 同样是 0~100 百分比，不是 mW。
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), targetCPUPerformanceLevel());
setCommonProductCeiling(@selector(setCPUPowerFloor:fromDecisionSource:), targetCPUPerformanceLevel());
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
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), targetCPUPerformanceLevel());
}
// 强制系统热压力为 Nominal 并重置热通知级别（与解除温控模式一致）
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 已主动套用自定义低功耗 CommonProduct 状态（系统 PowerSave 已关闭）");
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
stopFullPowerKeepAliveTimer();  // 退出满血时停止定时器
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleLowPowerApplyPulse();
startLowPowerKeepAliveTimer();  // 启动持久保持定时器
return;
}
if (isFullPowerMode()) {
stopLowPowerKeepAliveTimer();  // 退出低功耗时停止定时器
if (respectBootGuard && fullPowerBootGuardActive()) {
double elapsed = CFAbsoluteTimeGetCurrent() - g_processStartTime;
double remaining = kFullPowerBootGuardDuration - elapsed;
scheduleDeferredRuntimeApply(MAX(remaining, 0.1) + 0.1);
return;
}
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
scheduleFullPowerRecoveryPulse();
startFullPowerKeepAliveTimer();  // 启动满血保活定时器
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
runLowPowerApplyPulse(12);
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
// 修复：使用主队列确保所有 ObjC 调用线程安全
dispatch_async(dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(300);
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
// 修复：使用主队列保持线程安全 — 缩短间隔（0.1s），增加脉冲次数（300 次 ≈ 30s 覆盖），
// 压缩系统唤醒后重新评估功率目标的空窗期
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(remainingPulses - 1);
});
}

// ============================================================================
// 持久性低功耗保持定时器 — 定期重应用，防止决策树漂移和新控制器覆盖
//
// 修复：加入 ApplePPMCPU 实例强制重应用 + 消除定时器重建竞态
// ============================================================================
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

static void startLowPowerKeepAliveTimer(void) {
if (!g_enabled || !g_cpuProtection || !isLowPowerMode()) {
stopLowPowerKeepAliveTimer();
return;
}

// 修复：如果定时器已经在运行，不要销毁重建
// （唤醒脉冲期间 applyPowerModeToRuntime 会被高频调用，每秒 4 次销毁重建会造成 GCD 定时时序偏移/饥饿）
if (g_lowPowerKeepAliveTimer) {
return;
}

g_lowPowerKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
if (!g_lowPowerKeepAliveTimer) return;

dispatch_source_set_timer(g_lowPowerKeepAliveTimer,
dispatch_time(DISPATCH_TIME_NOW, 0),  // 立即触发首次，不留空窗期
(int64_t)(kLowPowerKeepAliveInterval * NSEC_PER_SEC),
0);  // leeway=0，最大限度缩短定时偏移，杜绝频率漂移窗口

dispatch_source_set_event_handler(g_lowPowerKeepAliveTimer, ^{
// 使用缓存状态（不读磁盘），低功耗保持期间无需重新 loadPrefs
// 模式切换由 onPowerModeChanged 通知 + 保活定时器停止/重建处理
if (!g_enabled || !g_cpuProtection || !isLowPowerMode()) {
stopLowPowerKeepAliveTimer();
return;
}

// 强制热压力 Nominal + 重置热通知级别
CPUthermalForceNominalCombined();
// 重新套用 CommonProduct 低功耗限制
applyLowPowerToCommonProduct();
// 强制设置所有已知控制器
applyLowPowerLimitsToTrackedControllers();
// 强制所有 ApplePPMCPU 实例保持当前模式目标。
applyCurrentModeToApplePPMCPU();
});

dispatch_resume(g_lowPowerKeepAliveTimer);
NSLog(@"[CPUthermal] 低功耗保持定时器已启动 (每 %.1fs 重应用 + 强制Nominal压力)", kLowPowerKeepAliveInterval);
}

static void stopLowPowerKeepAliveTimer(void) {
if (g_lowPowerKeepAliveTimer) {
dispatch_source_cancel(g_lowPowerKeepAliveTimer);
#if !OS_OBJECT_USE_OBJC
dispatch_release(g_lowPowerKeepAliveTimer);
#endif
g_lowPowerKeepAliveTimer = NULL;
NSLog(@"[CPUthermal] 低功耗保持定时器已停止");
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
dispatch_time(DISPATCH_TIME_NOW, 0),  // 立即触发首次，不留空窗期
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

static BOOL keyMatchesLowPowerLimit(NSString *key) {
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
if (!keyMatchesLowPowerLimit(key) || targetMHz <= 0) return NULL;

int64_t original = targetMHz;
if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
}

int64_t replacement = lockedFrequencyValue(original, targetMHz);
return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacement);
}

static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
if (!d) return;
g_enabled               = YES; // 始终启用，不依赖偏好设置
// g_cpuProtection 始终为 YES（硬编码），不依赖偏好设置
g_thermalBlockNotifPopup     = [d[S("thermalBlockNotifPopup")] ?: [NSNumber numberWithBool:YES] boolValue];
g_thermalPreventDimmingEnabled = [d[S("thermalPreventDimmingEnabled")] ?: [NSNumber numberWithBool:YES] boolValue];

// 从偏好读取频率配置，实现跨设备适配
NSNumber *prefFullMax = d[S("fullPowerMaxMHz")];
if (prefFullMax) {
g_fullPowerMaxMHz = [prefFullMax intValue];
}

// 温控锁定CPU频率值（对齐 insulation）：PSEditTextCell 存字符串，intValue 解析，空/非法为 0
g_cpuMinPowerValue = [d[S("cpuMinPowerValue")] intValue];
if (g_cpuMinPowerValue < 0) g_cpuMinPowerValue = 0;

NSString *mode = d[S("powerMode")] ?: S("fullPower");
os_unfair_lock_lock(&g_modeLock);
g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
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
if (g_cpuProtection && keyMatchesLowPowerLimit(ks)) {
CFTypeRef replacement = copyLockedFrequencyValueForKey(ks, value, targetCPUFrequencyMHz());
if (replacement) {
kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
CFRelease(replacement);
return ret;
}
}
return orig_IOServiceSetProperty(service, key, value);
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
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
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

// 自定义低功耗不启用系统 CPMS PowerSave，避免套用设备内置包功耗预算。
- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
if (g_restoringFullPower) {
%orig(enabled);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(NO);
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
// 低功耗模式: 阻止决策树运行，避免系统改写已锁定的 CPU 目标
if (shouldApplyLowPowerLimit()) {
// 强制热压力为 Nominal（与解除温控模式一致）
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 阻止决策树评估 (低功耗模式)");
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
if (shouldApplyLowPowerLimit()) {
return NO;
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
%orig(NO);
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
if (shouldApplyLowPowerLimit()) {
%orig(nil);
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
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
NSLog(@"[CPUthermal] 阻止 actionComponentControl");
return;
}
%orig;
}

// readReleaseRateForAllComponents — 全组件释放速率
- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
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
if (shouldApplyLowPowerLimit()) {
[res setCPULevel:targetCPUPerformanceLevel()];
[res updateCPU];
}
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(NO);
return;
}
%orig(enabled);
}

- (BOOL)powerSaveActive {
if (g_restoringFullPower) {
return %orig;
}
if (shouldApplyLowPowerLimit()) {
return NO;
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
%orig(NO);
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
%orig(0);
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
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPerformanceLevel());
return;
}
%orig(level);
}

- (void)setDVD1Level:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPerformanceLevel());
return;
}
%orig(level);
}

- (void)updateCPU {
if (g_restoringFullPower) {
%orig;
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
trackPowerController(self);
if (shouldApplyLowPowerLimit()) clearSystemLowPowerBudgetsOnController(self);
forceCPUPerformanceLevelOnController(self);
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
if (shouldApplyLowPowerLimit()) {
// 事件驱动钳制：系统每次更新前强制重新钳制 Package 功率目标
trackPowerController(self);
forceLowPowerSettersOnController(self);
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
// 自定义低功耗不使用系统 LPM CPU 功率目标，防止隐藏功率预算二次压频。
%orig(kUnrestrictedPowerLimitMW);
return;
}
if (shouldApplyFullCPUProtection()) {
// 对齐 insulation：满血抬到 65W（原直接 return 拦截会让内部状态不同步，导致降频回弹）
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
// powerSaveActive=NO 时原方法会把 PackageLowPowerTarget 恢复为 65000mW。
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
%orig(kUnrestrictedPowerLimitMW, legacy, propertyArg);
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
rememberOriginalIntValue(self, "CPUPowerCeiling", ceiling);
%orig(targetCPUPerformanceLevel(), source);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(targetCPUPerformanceLevel(), source);
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
rememberOriginalIntValue(self, "CPUDVD1Ceiling", ceiling);
%orig(targetCPUPerformanceLevel(), contributor);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(targetCPUPerformanceLevel(), contributor);
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
        %orig(targetCPUPerformanceLevel(), source);
        return;
    }
    if (shouldApplyFullCPUProtection()) {
        %orig(targetCPUPerformanceLevel(), source);
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
%orig(targetCPUPerformanceLevel());
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(targetCPUPerformanceLevel());
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

// ============================================================================
// FakeCPUZero 整合 — 额外 C 函数钩子（CPU/GPU/IOKit 读数篡改）
// 满血模式时生效，低功耗模式透传
// ============================================================================

/* ---- host_statistics 原始函数指针 ---- */
static kern_return_t (*orig_host_statistics)(host_t host, host_flavor_t flavor,
host_info_t info, mach_msg_type_number_t *count);
static kern_return_t (*orig_host_statistics64)(host_t host, host_flavor_t flavor,
host_info64_t info, mach_msg_type_number_t *count);
static kern_return_t (*orig_mach_task_info)(task_t task, task_flavor_t flavor,
task_info_t info, mach_msg_type_number_t *count);
static CFPropertyListRef (*orig_IORegistryEntryCreateCFProperty)(
io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options);

static NSDictionary* new_getConfigurationFor(NSString *key) {
NSDictionary *config = orig_getConfigurationFor(key);
if (!g_enabled || !config) return config;
if (g_thermalPreventDimmingEnabled) return patchThermalPlist(config);
return config;
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

static void onWakeRuntimeEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
loadPrefs();
if (g_enabled) {
applyPowerModeToRuntime(NO);
if (isLowPowerMode() && !g_lowPowerKeepAliveTimer) startLowPowerKeepAliveTimer();
scheduleWakeRuntimeApply();
}
NSLog(S("[CPUthermal] 收到唤醒/亮屏事件，准备恢复当前功率模式"));
};
if ([NSThread isMainThread]) block();
else dispatch_async(dispatch_get_main_queue(), block);
}

// ============================================================================
// FakeCPUZero 整合钩子函数实现
// ============================================================================

/* ---- host_statistics：满血模式时 CPU 占用显示 0% ---- */
static kern_return_t fake_host_statistics(host_t host, host_flavor_t flavor,
host_info_t info, mach_msg_type_number_t *count) {
kern_return_t ret = orig_host_statistics(host, flavor, info, count);

if (g_enabled && g_cpuProtection && isFullPowerMode()) {
if (ret == KERN_SUCCESS && flavor == HOST_CPU_LOAD_INFO) {
natural_t *cpu_info = (natural_t *)info;
cpu_info[CPU_STATE_USER]   = 0;
cpu_info[CPU_STATE_SYSTEM] = 0;
cpu_info[CPU_STATE_IDLE]   = 99999999;
// cpu_info[CPU_STATE_NICE] 保持不变
}
}

return ret;
}

/* ---- host_statistics64（同上） ---- */
static kern_return_t fake_host_statistics64(host_t host, host_flavor_t flavor,
host_info64_t info, mach_msg_type_number_t *count) {
kern_return_t ret = orig_host_statistics64(host, flavor, info, count);

if (g_enabled && g_cpuProtection && isFullPowerMode()) {
if (ret == KERN_SUCCESS && flavor == HOST_CPU_LOAD_INFO) {
natural_t *cpu_info = (natural_t *)info;
cpu_info[CPU_STATE_USER]   = 0;
cpu_info[CPU_STATE_SYSTEM] = 0;
cpu_info[CPU_STATE_IDLE]   = 99999999;
}
}

return ret;
}

/* ---- mach_task_info：满血模式时 GPU 能耗归零 ---- */
static kern_return_t fake_mach_task_info(task_t task, task_flavor_t flavor,
task_info_t info, mach_msg_type_number_t *count) {
kern_return_t ret = orig_mach_task_info(task, flavor, info, count);

if (g_enabled && g_cpuProtection && isFullPowerMode()) {
if (ret == KERN_SUCCESS && flavor == TASK_POWER_INFO) {
uint32_t *power_info = (uint32_t *)info;
power_info[5] = 0;   // offset 0x14 — GPU 利用率
power_info[7] = 0;   // offset 0x1c — GPU 统计
}
}

return ret;
}

/* ---- IORegistryEntryCreateCFProperty：篡改热管理 IOReg 读数 ---- */
// 满血模式时：返回应有的"低温/正常"值，使 thermalmonitord/powerd 认为无需降频
// 低功耗模式：透传，让系统正常读取温度
static CFPropertyListRef fake_IORegistryEntryCreateCFProperty(
io_registry_entry_t entry, CFStringRef key,
CFAllocatorRef allocator, IOOptionBits options) {

CFTypeRef result = orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);

if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) {
return result;
}

if (result == NULL) return NULL;

/* key 是 CFString → 直接替换单值 */
if (key != NULL && CFGetTypeID(key) == CFStringGetTypeID()) {
NSString *nsKey = (__bridge NSString *)key;

/* 温度类 → 返回 ~30°C（低温，不触发降频） */
if ([nsKey isEqualToString:@"Temperature"] ||
[nsKey isEqualToString:@"BatteryTemperature"] ||
[nsKey isEqualToString:@"TemperatureCelsius"]) {

CFRelease(result);
NSNumber *num = [NSNumber numberWithInt:30];
CFRetain((__bridge CFTypeRef)num);
return (__bridge CFPropertyListRef)num;
}

/* 节流/充电限制类 → 返回 0（无限制） */
if ([nsKey isEqualToString:@"NotChargingReason"] ||
[nsKey isEqualToString:@"ChargingDisabledReason"] ||
[nsKey isEqualToString:@"InhibitCharging"] ||
[nsKey isEqualToString:@"ThermalLevel"]) {

CFRelease(result);
NSNumber *num = [NSNumber numberWithInt:0];
CFRetain((__bridge CFTypeRef)num);
return (__bridge CFPropertyListRef)num;
}

return result;
}

/* result 是 CFDictionary → 批量修改 */
if (result != NULL && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
NSMutableDictionary *dict = [(__bridge NSDictionary *)result mutableCopy];
CFRelease(result);

if (dict == nil) return NULL;

if (dict[@"Temperature"])           dict[@"Temperature"] = @30;
if (dict[@"BatteryTemperature"])    dict[@"BatteryTemperature"] = @30;
if (dict[@"TemperatureCelsius"])    dict[@"TemperatureCelsius"] = @30;
if (dict[@"NotChargingReason"])     dict[@"NotChargingReason"] = @0;
if (dict[@"ChargingDisabledReason"]) dict[@"ChargingDisabledReason"] = @0;
if (dict[@"InhibitCharging"])       dict[@"InhibitCharging"] = @0;
if (dict[@"ThermalLevel"])          dict[@"ThermalLevel"] = @0;

CFRetain((__bridge CFTypeRef)dict);
return (__bridge CFPropertyListRef)dict;
}

return result;
}

// ============================================================================
// IOKit 电源状态通知 — 最可靠的系统唤醒检测
// ============================================================================
static IONotificationPortRef g_powerNotifyPort = NULL;
static io_object_t g_powerNotifier = 0;

static void onSystemPowerEvent(void *refcon, io_service_t service, natural_t messageType, void *messageArgument) {
if (messageType == kIOMessageSystemWillSleep) {
NSLog(@"[CPUthermal] IOKit 电源通知: 系统即将睡眠");
return;
}
if (messageType == kIOMessageSystemHasPoweredOn) {
dispatch_async(dispatch_get_main_queue(), ^{
loadPrefs();
if (g_enabled) {
// 立即同步应用一次，消除系统唤醒后的功率目标空窗期
applyPowerModeToRuntime(NO);
// 低功耗下确保保活定时器存活（防止长时间睡眠期间定时器异常丢失）
if (isLowPowerMode() && !g_lowPowerKeepAliveTimer) {
startLowPowerKeepAliveTimer();
}
scheduleWakeRuntimeApply();
}
NSLog(@"[CPUthermal] IOKit 电源通知: 系统已唤醒");
});
}
}

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
g_processStartTime = CFAbsoluteTimeGetCurrent();
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

// ========== FakeCPUZero 整合: host_statistics / host_statistics64 / mach_task_info / IORegistryEntryCreateCFProperty ==========
void *libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOLOAD);
if (libSystem) {
void *sym = NULL;
sym = dlsym(RTLD_DEFAULT, "host_statistics");
if (sym) {
MSHookFunction(sym, (void *)fake_host_statistics, (void **)&orig_host_statistics);
NSLog(@"[CPUthermal] host_statistics hook 已安装 (满血:CPU0%%)");
} else NSLog(@"[CPUthermal] 未找到 host_statistics (非致命)");

sym = dlsym(RTLD_DEFAULT, "host_statistics64");
if (sym) {
MSHookFunction(sym, (void *)fake_host_statistics64, (void **)&orig_host_statistics64);
NSLog(@"[CPUthermal] host_statistics64 hook 已安装 (满血:CPU0%%)");
} else NSLog(@"[CPUthermal] 未找到 host_statistics64 (非致命)");

sym = dlsym(RTLD_DEFAULT, "mach_task_info");
if (sym) {
MSHookFunction(sym, (void *)fake_mach_task_info, (void **)&orig_mach_task_info);
NSLog(@"[CPUthermal] mach_task_info hook 已安装 (满血:GPU归零)");
} else NSLog(@"[CPUthermal] 未找到 mach_task_info (非致命)");

sym = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
if (sym) {
MSHookFunction(sym, (void *)fake_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty);
NSLog(@"[CPUthermal] IORegistryEntryCreateCFProperty hook 已安装 (满血:低温读数)");
} else NSLog(@"[CPUthermal] 未找到 IORegistryEntryCreateCFProperty (非致命)");
}

// 强制系统热压力为 Nominal 并重置热通知级别
CPUthermalForceNominalCombined();

NSLog(@"[CPUthermal] 温控防护已激活 — 安全阀:已禁用 CPU性能:%d",
g_cpuProtection);

// 注意: 配置仅在进程启动时加载一次
// 修改设置后需重启 thermalmonitord 才生效

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

// 注册 IOKit 电源状态回调
io_service_t rootDomain = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMrootDomain"));
if (rootDomain) {
g_powerNotifyPort = IONotificationPortCreate(kIOMasterPortDefault);
if (g_powerNotifyPort) {
CFRunLoopAddSource(CFRunLoopGetMain(),
IONotificationPortGetRunLoopSource(g_powerNotifyPort),
kCFRunLoopDefaultMode);
IOServiceAddInterestNotification(g_powerNotifyPort,
rootDomain,
kIOGeneralInterest,
onSystemPowerEvent,
NULL,
&g_powerNotifier);
NSLog(@"[CPUthermal] IOKit 电源状态监听已注册");
}
IOObjectRelease(rootDomain);
}

// 修复③：进程启动即应用当前功率模式。
// 长时间锁屏后 thermalmonitord 可能被系统重启，若仅依赖 CommonProduct init 时机，
// 低功耗锁定存在空窗期。此处立即应用并启动保活定时器兜底。
applyCurrentPowerModeToRuntime();
NSLog(@"[CPUthermal] 启动完成，当前功率模式:%@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
}
