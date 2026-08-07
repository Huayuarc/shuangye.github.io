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
#import <CPUthermalFrequency.h>
#import <CPUthermalPowerCurve.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <os/lock.h>
#import <mach/host_info.h>
#import <mach/task_info.h>
#import <sys/sysctl.h>

extern kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *entryID);

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

// 低功耗模式期望目标（MHz）；运行时会按设备真实性能核 P-State 选择最近档位。
static int g_lowPowerRequestedFrequencyMHz = kCPUthermalDefaultLowPowerLockMHz;

// 解除温控模式 CPU 目标频率（MHz）— 优先读取用户输入，未配置时使用设备硬件上限
static int g_fullPowerMaxMHz = 0;

// 65000 是 thermalmonitord CPU/package mW 功率预算的无限制哨兵值。
static const int kUnrestrictedPowerLimitMW = 65000;
static const int kMaximumCPUPowerCurveTarget = 100;
static const int kCPUDecisionSourceCount = 6;
static const int kCPUDVD1ContributorCount = 4;

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;
static __thread BOOL g_restoringFullPower = NO;
static BOOL g_fullPowerRecoveryPulseScheduled = NO;
static BOOL g_lowPowerApplyPulseScheduled = NO;
static BOOL g_wakeRuntimeApplyScheduled = NO;
static BOOL g_systemSleeping = NO;
static uint64_t g_wakeRuntimeApplyGeneration = 0;
static int g_displayStatusNotifyToken = -1;
static int g_lockStateNotifyToken = -1;
static BOOL g_displayIsOff = NO;
static BOOL g_deviceLocked = NO;

// 持久性低功耗保持定时器
static dispatch_source_t g_lowPowerKeepAliveTimer = NULL;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护g_powerMode
static const double kLowPowerKeepAliveInterval = 1.0;
static NSHashTable *g_applePPMInstances = nil;           // 追踪 ApplePPMCPU 实例（弱引用，防止僵尸实例泄漏）

// 绕过本地频率 Hook，直接向 CPU 治理服务重写低功耗频率上限。
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

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
static int targetCPUPowerCurveTarget(void);
static int hardwareMaxFrequencyMHz(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(void);
static void scheduleLowPowerApplyPulse(void);
static void runLowPowerApplyPulse(int remainingPulses);
static void scheduleFullPowerRecoveryPulse(void);
static void runFullPowerRecoveryPulse(int remainingPulses);
static void scheduleWakeRuntimeApply(void);
static void cancelWakeRuntimeApply(void);
static void runWakeRuntimeApplyPulse(int remainingPulses, uint64_t generation);
static void handleRuntimeDisplayOffEvent(void);
static void handleRuntimeLockEvent(void);
static void handleRuntimeSleepEvent(NSString *reason);
static void handleRuntimeWakeEvent(NSString *reason);
static void registerRuntimePowerStateNotifications(void);
static void startLowPowerKeepAliveTimer(void);
static void stopLowPowerKeepAliveTimer(void);
static void applyCurrentModeToApplePPMCPU(void);
static void startFullPowerKeepAliveTimer(void);
static void stopFullPowerKeepAliveTimer(void);
static void reapplyTrackedCPUFrequencyTargets(void);
static void discoverCPUFrequencyTargetsFromServices(void);
static void forceCPUPowerCurveTargetOnController(id controller);
static void applyCurrentModeBudgetsOnController(id controller);
static void activateLowPowerStateOnController(id controller);

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

typedef struct {
NSUInteger stride;
NSUInteger frequencyOffset;
NSUInteger frequencyWidth;
NSUInteger voltageOffset;
NSUInteger voltageWidth;
} CPUthermalPowerStateLayout;

// 从 PMGR 的 voltage-states* 中识别真实性能核 P-State 与电压曲线。
// 同时兼容 8/12/16 字节记录、32/64 位频率，以及 Hz/kHz/MHz 和多种电压缩放单位。
static NSArray<NSArray<NSNumber *> *> *performanceClusterPowerStates(void) {
static NSArray<NSArray<NSNumber *> *> *s_powerStates = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
io_registry_entry_t pmgr = copyPMGRDeviceTreeEntry();
if (pmgr == MACH_PORT_NULL) {
s_powerStates = [NSArray array];
return;
}

CFMutableDictionaryRef propertiesRef = NULL;
kern_return_t result = IORegistryEntryCreateCFProperties(pmgr, &propertiesRef, kCFAllocatorDefault, 0);
IOObjectRelease(pmgr);
if (result != KERN_SUCCESS || !propertiesRef) {
s_powerStates = [NSArray array];
return;
}

NSDictionary *properties = CFBridgingRelease(propertiesRef);
NSArray<NSArray<NSNumber *> *> *bestTable = nil;
NSString *bestKey = nil;
int bestMaxMHz = 0;
NSUInteger bestCount = 0;
NSUInteger bestStride = 0;
NSUInteger bestFrequencyWidth = 0;
BOOL bestHasVoltageCurve = NO;

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
const CPUthermalPowerStateLayout layouts[] = {
{8, 0, 4, 4, 4},
{12, 0, 4, 4, 4},
{16, 0, 4, 4, 4},
{16, 0, 8, 8, 4}
};
for (NSUInteger layoutIndex = 0; layoutIndex < sizeof(layouts) / sizeof(layouts[0]); layoutIndex++) {
CPUthermalPowerStateLayout layout = layouts[layoutIndex];
if ((data.length % layout.stride) != 0 || data.length < layout.stride * 3) continue;
if (layout.frequencyOffset + layout.frequencyWidth > layout.stride ||
layout.voltageOffset + layout.voltageWidth > layout.stride) continue;

NSMutableArray<NSArray<NSNumber *> *> *candidate = [NSMutableArray array];
int previousMHz = 0;
BOOL monotonic = YES;
NSUInteger recordCount = data.length / layout.stride;
NSUInteger validFrequencyCount = 0;
for (NSUInteger offset = 0; offset + layout.stride <= data.length; offset += layout.stride) {
uint64_t rawFrequency = CPUthermalReadLittleEndianUnsigned(
bytes + offset + layout.frequencyOffset, layout.frequencyWidth);
uint64_t rawVoltage = CPUthermalReadLittleEndianUnsigned(
bytes + offset + layout.voltageOffset, layout.voltageWidth);
int frequencyMHz = CPUthermalFrequencyMHzFromRaw(rawFrequency);
if (frequencyMHz < kCPUthermalMinimumCPUFrequencyMHz ||
frequencyMHz > kCPUthermalMaximumCPUFrequencyMHz) continue;

validFrequencyCount++;
uint32_t voltageMillivolts = CPUthermalVoltageMillivoltsFromRaw(rawVoltage);
if (previousMHz > 0 && frequencyMHz < previousMHz) {
monotonic = NO;
break;
}
if (frequencyMHz == previousMHz && candidate.count > 0) {
NSArray<NSNumber *> *lastState = candidate.lastObject;
if (voltageMillivolts > [lastState[1] unsignedIntValue]) {
candidate[candidate.count - 1] = @[
[NSNumber numberWithInt:frequencyMHz],
[NSNumber numberWithUnsignedInt:voltageMillivolts]
];
}
continue;
}

[candidate addObject:@[
[NSNumber numberWithInt:frequencyMHz],
[NSNumber numberWithUnsignedInt:voltageMillivolts]
]];
previousMHz = frequencyMHz;
}

if (!monotonic || candidate.count < 3 || validFrequencyCount * 100 < recordCount * 60) continue;
int candidateMinMHz = [candidate.firstObject[0] intValue];
int candidateMaxMHz = [candidate.lastObject[0] intValue];
if (candidateMaxMHz - candidateMinMHz < 200) continue;
BOOL candidateHasVoltageCurve = YES;
for (NSArray<NSNumber *> *state in candidate) {
if ([state[1] unsignedIntValue] == 0) {
candidateHasVoltageCurve = NO;
break;
}
}
BOOL candidateIsSRAM = [lowerKey hasSuffix:S("-sram")];
BOOL bestIsSRAM = bestKey && [[bestKey lowercaseString] hasSuffix:S("-sram")];
BOOL isBetterCandidate = !bestTable || candidateMaxMHz > bestMaxMHz;
if (candidateMaxMHz == bestMaxMHz) {
if (candidateIsSRAM != bestIsSRAM) isBetterCandidate = candidateIsSRAM;
else if (candidateHasVoltageCurve != bestHasVoltageCurve) isBetterCandidate = candidateHasVoltageCurve;
else if (candidate.count != bestCount) isBetterCandidate = candidate.count > bestCount;
else isBetterCandidate = layout.frequencyWidth < bestFrequencyWidth;
}
if (isBetterCandidate) {
bestMaxMHz = candidateMaxMHz;
bestCount = candidate.count;
bestTable = [candidate copy];
bestKey = key;
bestStride = layout.stride;
bestFrequencyWidth = layout.frequencyWidth;
bestHasVoltageCurve = candidateHasVoltageCurve;
}
}
}

s_powerStates = bestTable ?: [NSArray array];
if (s_powerStates.count > 0) {
NSMutableArray<NSNumber *> *frequencies = [NSMutableArray arrayWithCapacity:s_powerStates.count];
for (NSArray<NSNumber *> *state in s_powerStates) [frequencies addObject:state[0]];
NSLog(S("[CPUthermal] 已识别性能核 P-State 表 %@ stride:%lu freqBits:%lu curve:%@ %@ MHz"),
bestKey, (unsigned long)bestStride, (unsigned long)(bestFrequencyWidth * 8),
bestHasVoltageCurve ? S("fV²") : S("线性"), frequencies);
} else {
NSLog(S("[CPUthermal] 未能从 PMGR 识别性能核 P-State 功率曲线，将使用线性回退"));
}
});
return s_powerStates;
}

static NSArray<NSNumber *> *performanceClusterFrequenciesMHz(void) {
static NSArray<NSNumber *> *s_frequencies = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
NSArray<NSArray<NSNumber *> *> *states = performanceClusterPowerStates();
NSMutableArray<NSNumber *> *frequencies = [NSMutableArray arrayWithCapacity:states.count];
for (NSArray<NSNumber *> *state in states) [frequencies addObject:state[0]];
s_frequencies = [frequencies copy];
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
(configuredMHz < kCPUthermalMinimumCPUFrequencyMHz || configuredMHz > kCPUthermalMaximumCPUFrequencyMHz)) {
configuredMHz = 0;
}
if (configuredMHz <= 0) configuredMHz = hardwareMaxMHz;
if (hardwareMaxMHz > 0 && configuredMHz > hardwareMaxMHz) configuredMHz = hardwareMaxMHz;
return nearestSupportedCPUFrequencyMHz(configuredMHz);
}

static int targetCPUFrequencyMHz(void) {
if (isLowPowerMode()) {
int requestedMHz = CPUthermalNormalizedLowPowerLockMHz(g_lowPowerRequestedFrequencyMHz);
int hardwareMaxMHz = hardwareMaxFrequencyMHz();
if (hardwareMaxMHz > 0 && requestedMHz > hardwareMaxMHz) requestedMHz = hardwareMaxMHz;
return nearestSupportedCPUFrequencyMHz(requestedMHz);
}
return fullPowerFrequencyValue();
}

// MitigationController 的 CPULevel/ceiling/floor/PowerZoneTarget 共用 0~100
// 功率曲线单位。按目标 P-State 的 f×V² 相对设备最大 P-State 归一化；当电压
// 不可用时退化为频率比例，避免再把 MHz、mW 或 0/2 档位写入该链路。
static int targetCPUPowerCurveTarget(void) {
int targetMHz = targetCPUFrequencyMHz();
if (targetMHz <= 0) return kMaximumCPUPowerCurveTarget;

NSArray<NSArray<NSNumber *> *> *states = performanceClusterPowerStates();
if (states.count > 0) {
NSArray<NSNumber *> *targetState = states[0];
int bestDistance = abs([targetState[0] intValue] - targetMHz);
BOOL hasVoltageCurve = YES;
uint64_t maximumPowerMetric = 0;

for (NSArray<NSNumber *> *state in states) {
int frequencyMHz = [state[0] intValue];
uint32_t voltageMillivolts = [state[1] unsignedIntValue];
int distance = abs(frequencyMHz - targetMHz);
if (distance < bestDistance ||
(distance == bestDistance && frequencyMHz > [targetState[0] intValue])) {
targetState = state;
bestDistance = distance;
}

if (voltageMillivolts < 400 || voltageMillivolts > 2000) {
hasVoltageCurve = NO;
continue;
}
uint64_t powerMetric = (uint64_t)frequencyMHz * voltageMillivolts * voltageMillivolts;
if (powerMetric > maximumPowerMetric) maximumPowerMetric = powerMetric;
}

if (hasVoltageCurve && maximumPowerMetric > 0) {
uint64_t targetVoltage = [targetState[1] unsignedIntValue];
uint64_t targetPowerMetric = (uint64_t)[targetState[0] intValue] * targetVoltage * targetVoltage;
int powerTarget = (int)((targetPowerMetric * kMaximumCPUPowerCurveTarget + maximumPowerMetric / 2) /
maximumPowerMetric);
if (powerTarget < 1) powerTarget = 1;
if (powerTarget > kMaximumCPUPowerCurveTarget) powerTarget = kMaximumCPUPowerCurveTarget;
return powerTarget;
}
}

int maximumMHz = hardwareMaxFrequencyMHz();
if (maximumMHz <= 0) return kMaximumCPUPowerCurveTarget;
int powerTarget = (targetMHz * kMaximumCPUPowerCurveTarget + maximumMHz / 2) / maximumMHz;
if (powerTarget < 1) powerTarget = 1;
if (powerTarget > kMaximumCPUPowerCurveTarget) powerTarget = kMaximumCPUPowerCurveTarget;
return powerTarget;
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

// CPULevel、CPU ceiling/floor 与 PowerZoneTarget 使用同一 0~100 功率曲线单位；
// CPULowPowerTarget/MaxCPUPowerTarget 才是 mW。所有 level 路径必须使用同一个动态目标。
static void forceCPUPowerCurveTargetOnController(id controller) {
if (!controller || !g_enabled || !g_cpuProtection) return;
int powerCurveTarget = targetCPUPowerCurveTarget();

if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), powerCurveTarget);
}
if ([controller respondsToSelector:@selector(setDVD1Level:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setDVD1Level:), powerCurveTarget);
}
}

// updateCPU 会异步从 6 项 ceiling/floor 计算 max(minCeiling, maxFloor)，并直接覆盖
// CPULevel。这里必须预先把整张列表写成同一功率曲线目标，不能写 mW 哨兵值。
static void applyCurrentModeBudgetsOnController(id controller) {
if (!controller || !g_enabled || !g_cpuProtection) return;
int powerCurveTarget = targetCPUPowerCurveTarget();
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
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), powerCurveTarget, source);
}
if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerFloor:fromDecisionSource:), powerCurveTarget, source);
}
}
for (int contributor = 0; contributor < kCPUDVD1ContributorCount; contributor++) {
if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)]) {
((void (*)(id, SEL, int, int))objc_msgSend)(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), powerCurveTarget, contributor);
}
}
if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), powerCurveTarget);
}
forceCPUPowerCurveTargetOnController(controller);
}

static void activateLowPowerStateOnController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
applyCurrentModeBudgetsOnController(controller);
}

// 仅设置低功耗钳制 setter，不触发 updateCPU/updatePackage。
// 供保活定时器与 updateCPU/updatePackage 钩子复用，避免递归。
static void forceLowPowerSettersOnController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
activateLowPowerStateOnController(controller);
}

static void applyLowPowerLimitToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
@try {
forceLowPowerSettersOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 下发低功耗 CPU 限制失败: %@", exception);
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
applyCurrentModeBudgetsOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
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

static void applyCurrentModeToCommonProduct(void) {
if (!g_commonProduct || !g_enabled || !g_cpuProtection) return;
@try {
g_restoringFullPower = YES;
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), targetCPUPowerCurveTarget());
}
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), targetCPUPowerCurveTarget());
setCommonProductCeiling(@selector(setCPUPowerFloor:fromDecisionSource:), targetCPUPowerCurveTarget());
if ([g_commonProduct respondsToSelector:@selector(setThermalState:)]) {
((void (*)(id, SEL, id))objc_msgSend)(g_commonProduct, @selector(setThermalState:), [NSNumber numberWithInt:0]);
}
CPUthermalForceNominalCombined();
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用当前 CommonProduct 状态失败: %@", exception);
} @finally {
g_restoringFullPower = NO;
}
}

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime();
}

static void applyPowerModeToRuntime(void) {
if (!g_enabled || !g_cpuProtection) return;
applyCurrentModeToCommonProduct();
if (isLowPowerMode()) {
stopFullPowerKeepAliveTimer();  // 退出满血时停止定时器
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
scheduleLowPowerApplyPulse();
startLowPowerKeepAliveTimer();  // 启动持久保持定时器
return;
}
if (isFullPowerMode()) {
stopLowPowerKeepAliveTimer();  // 退出低功耗时停止定时器
restoreFullPowerToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
scheduleFullPowerRecoveryPulse();
startFullPowerKeepAliveTimer();  // 启动满血保活定时器
}
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
applyCurrentModeToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
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
applyCurrentModeToCommonProduct();
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

static void scheduleWakeRuntimeApply(void) {
if (!g_enabled || !g_cpuProtection || g_systemSleeping) return;
uint64_t generation = ++g_wakeRuntimeApplyGeneration;
g_wakeRuntimeApplyScheduled = YES;
dispatch_async(dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(20, generation);
});
}

static void cancelWakeRuntimeApply(void) {
++g_wakeRuntimeApplyGeneration;
g_wakeRuntimeApplyScheduled = NO;
}

static void runWakeRuntimeApplyPulse(int remainingPulses, uint64_t generation) {
if (generation != g_wakeRuntimeApplyGeneration) return;
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection || g_systemSleeping) {
g_wakeRuntimeApplyScheduled = NO;
return;
}
loadPrefs();
applyPowerModeToRuntime();
reapplyTrackedCPUFrequencyTargets();
if (remainingPulses <= 1) {
g_wakeRuntimeApplyScheduled = NO;
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(remainingPulses - 1, generation);
});
}

static void handleRuntimeDisplayOffEvent(void) {
g_displayIsOff = YES;
cancelWakeRuntimeApply();
if (shouldApplyLowPowerLimit()) {
applyCurrentModeToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
scheduleLowPowerApplyPulse();
}
NSLog(@"[CPUthermal] 屏幕已熄灭，已重应用低功耗锁频");
}

static void handleRuntimeLockEvent(void) {
g_deviceLocked = YES;
cancelWakeRuntimeApply();
if (shouldApplyLowPowerLimit()) {
applyCurrentModeToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
scheduleLowPowerApplyPulse();
}
NSLog(@"[CPUthermal] 设备已锁定，已重应用低功耗锁频");
}

static void handleRuntimeSleepEvent(NSString *reason) {
if (g_systemSleeping) return;

g_displayIsOff = YES;

if (shouldApplyLowPowerLimit()) {
applyCurrentModeToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
}

g_systemSleeping = YES;
cancelWakeRuntimeApply();
stopFullPowerKeepAliveTimer();
NSLog(S("[CPUthermal] 收到系统休眠事件，唤醒后将立即恢复当前锁频: %@"), reason ?: S("unknown"));
}

static void handleRuntimeWakeEvent(NSString *reason) {
g_systemSleeping = NO;
if ([reason isEqualToString:S("display-on")]) g_displayIsOff = NO;
if ([reason isEqualToString:S("device-unlocked")]) {
g_deviceLocked = NO;
g_displayIsOff = NO;
}
// 1. 优先读取内存中的全局状态，若为低功耗模式，唤醒瞬间立即先施加锁定
if (isLowPowerMode()) {
applyCurrentModeToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
}

loadPrefs(); // 2. 再加载偏好设置

// 低功耗定时器跨休眠保留，dispatch_walltime 会在恢复执行后按墙上时间补触发。
if (isFullPowerMode()) stopFullPowerKeepAliveTimer();
applyPowerModeToRuntime();
reapplyTrackedCPUFrequencyTargets();
scheduleWakeRuntimeApply();
NSLog(S("[CPUthermal] 收到唤醒事件，已重应用当前功率模式: %@"), reason ?: S("unknown"));
}

static void registerRuntimePowerStateNotifications(void) {
dispatch_queue_t queue = dispatch_get_main_queue();

if (g_displayStatusNotifyToken < 0) {
uint32_t status = notify_register_dispatch("com.apple.iokit.hid.displayStatus",
&g_displayStatusNotifyToken,
queue,
^(int token) {
uint64_t state = 0;
if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) {
handleRuntimeWakeEvent(S("displayStatus-unknown"));
return;
}
g_displayIsOff = (state == 0);
if (!g_displayIsOff) handleRuntimeWakeEvent(S("display-on"));
else handleRuntimeDisplayOffEvent();
});
if (status != NOTIFY_STATUS_OK) {
g_displayStatusNotifyToken = -1;
} else {
uint64_t initialState = 0;
if (notify_get_state(g_displayStatusNotifyToken, &initialState) == NOTIFY_STATUS_OK) {
g_displayIsOff = (initialState == 0);
}
}
}

if (g_lockStateNotifyToken < 0) {
uint32_t status = notify_register_dispatch("com.apple.springboard.lockstate",
&g_lockStateNotifyToken,
queue,
^(int token) {
uint64_t state = 0;
if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return;
g_deviceLocked = (state != 0);
if (g_deviceLocked) handleRuntimeLockEvent();
else handleRuntimeWakeEvent(S("device-unlocked"));
});
if (status != NOTIFY_STATUS_OK) {
g_lockStateNotifyToken = -1;
} else {
uint64_t initialState = 0;
if (notify_get_state(g_lockStateNotifyToken, &initialState) == NOTIFY_STATUS_OK) {
g_deviceLocked = (initialState != 0);
}
}
}

}

// ============================================================================
// 持久性低功耗保持定时器 — 定期重应用，防止决策树漂移和新控制器覆盖
//
// ApplePPMCPU 实例和 IOKit 目标会一起重应用；系统睡眠期间不持有防睡眠断言。
// ============================================================================
static void applyCurrentModeToApplePPMCPU(void) {
if (!g_enabled || !g_cpuProtection) return;
NSArray *instances = trackedApplePPMInstancesSnapshot();
for (id ppm in instances) {
if (!ppm) continue;
if ([ppm respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), targetCPUPowerCurveTarget());
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

if (g_lowPowerKeepAliveTimer) return;

g_lowPowerKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
if (!g_lowPowerKeepAliveTimer) return;

dispatch_source_set_timer(g_lowPowerKeepAliveTimer,
dispatch_walltime(NULL, 0),
(uint64_t)(kLowPowerKeepAliveInterval * NSEC_PER_SEC),
0);

dispatch_source_set_event_handler(g_lowPowerKeepAliveTimer, ^{
if (!g_enabled || !g_cpuProtection || !isLowPowerMode()) {
stopLowPowerKeepAliveTimer();
return;
}

CPUthermalForceNominalCombined();
applyCurrentModeToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyCurrentModeToApplePPMCPU();
reapplyTrackedCPUFrequencyTargets();
});

dispatch_resume(g_lowPowerKeepAliveTimer);
NSLog(@"[CPUthermal] 低功耗保持定时器已启动 (每 %.1fs)", kLowPowerKeepAliveInterval);
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
// 满血模式保活定时器 — 每 1 秒重应用一次，防止系统温控恢复
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
applyCurrentModeToCommonProduct();
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

static const char *g_cpuControlServiceClasses[] = {
"AppleCLPC",
"ApplePPMCPMS",
"ApplePPMEntityCLPC",
"AppleARMCPU",
"AppleARMPerformanceController",
"ApplePPMCPU",
NULL
};

static BOOL entryIsCPUControlService(io_registry_entry_t entry) {
if (entry == MACH_PORT_NULL) return NO;
for (int index = 0; g_cpuControlServiceClasses[index]; index++) {
if (IOObjectConformsTo(entry, g_cpuControlServiceClasses[index])) return YES;
}

io_name_t name = {0};
if (IORegistryEntryGetName(entry, name) != KERN_SUCCESS) return NO;
NSString *lowerName = [[NSString stringWithUTF8String:name] lowercaseString];
if ([lowerName containsString:S("gpu")] || [lowerName containsString:S("ane")]) return NO;
return [lowerName containsString:S("cpu")] ||
[lowerName containsString:S("clpc")] ||
[lowerName containsString:S("ppm")];
}

static BOOL keyLooksLikeFrequencyProperty(NSString *key) {
if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
NSString *lower = [key lowercaseString];
if ([lower containsString:S("gpu")] ||
[lower containsString:S("ane")] ||
[lower containsString:S("display")] ||
[lower containsString:S("memory")] ||
[lower containsString:S("dram")] ||
[lower containsString:S("fabric")] ||
[lower containsString:S("latency")]) {
return NO;
}
return [lower containsString:S("freq")] || [lower containsString:S("clock")];
}

static BOOL keyExplicitlyTargetsCPU(NSString *key) {
NSString *lower = [key lowercaseString];
return [lower containsString:S("cpu")] ||
[lower containsString:S("processor")] ||
[lower containsString:S("cluster")] ||
[lower containsString:S("clpc")] ||
[lower containsString:S("ppm")];
}

static BOOL entryAndKeyTargetCPUFrequency(io_registry_entry_t entry, NSString *key) {
if (!keyLooksLikeFrequencyProperty(key)) return NO;
return keyExplicitlyTargetsCPU(key) || entryIsCPUControlService(entry);
}

static int64_t frequencyMHzFromValue(int64_t value) {
int64_t magnitude = llabs(value);
if (magnitude >= 100000000LL) return magnitude / 1000000LL;
if (magnitude >= 100000LL) return magnitude / 1000LL;
return magnitude;
}

static BOOL frequencyValueLooksPlausible(int64_t value) {
int64_t mhz = frequencyMHzFromValue(value);
return mhz >= 100 && mhz <= 10000;
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

static CFTypeRef copyLockedFrequencyValueForEntry(io_registry_entry_t entry, NSString *key, CFTypeRef originalValue, int64_t targetMHz) {
if (!entryAndKeyTargetCPUFrequency(entry, key) || targetMHz <= 0) return NULL;

int64_t original = targetMHz;
if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
}
if (!frequencyValueLooksPlausible(original)) return NULL;

int64_t replacement = lockedFrequencyValue(original, targetMHz);
return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacement);
}

static CFDictionaryRef copyLockedFrequencyProperties(io_registry_entry_t entry, CFTypeRef properties, int64_t targetMHz) {
if (!properties || CFGetTypeID(properties) != CFDictionaryGetTypeID() || targetMHz <= 0) return NULL;
NSDictionary *source = (__bridge NSDictionary *)properties;
NSMutableDictionary *locked = [source mutableCopy];
BOOL changed = NO;
for (id rawKey in source) {
if (![rawKey isKindOfClass:[NSString class]]) continue;
CFTypeRef replacement = copyLockedFrequencyValueForEntry(entry, rawKey, (__bridge CFTypeRef)source[rawKey], targetMHz);
if (!replacement) continue;
locked[rawKey] = CFBridgingRelease(replacement);
changed = YES;
}
return changed ? CFBridgingRetain(locked) : NULL;
}

#define MAX_TRACKED_CPU_FREQUENCY_TARGETS 96

typedef struct {
io_registry_entry_t entry;
uint64_t registryEntryID;
CFStringRef key;
int64_t sampleValue;
} CPUFrequencyTarget;

static CPUFrequencyTarget g_cpuFrequencyTargets[MAX_TRACKED_CPU_FREQUENCY_TARGETS];
static int g_cpuFrequencyTargetCount = 0;
static os_unfair_lock g_cpuFrequencyTargetLock = OS_UNFAIR_LOCK_INIT;

static uint64_t registryEntryIDForEntry(io_registry_entry_t entry) {
uint64_t entryID = 0;
if (entry != MACH_PORT_NULL) {
IORegistryEntryGetRegistryEntryID(entry, &entryID);
}
return entryID;
}

static void trackCPUFrequencyTarget(io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
if (entry == MACH_PORT_NULL || !key || !value || CFGetTypeID(value) != CFNumberGetTypeID()) return;
NSString *keyString = (__bridge NSString *)key;
if (!entryAndKeyTargetCPUFrequency(entry, keyString)) return;

int64_t sampleValue = 0;
if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &sampleValue)) return;
if (!frequencyValueLooksPlausible(sampleValue)) return;
uint64_t entryID = registryEntryIDForEntry(entry);

os_unfair_lock_lock(&g_cpuFrequencyTargetLock);
for (int index = 0; index < g_cpuFrequencyTargetCount; index++) {
CPUFrequencyTarget *target = &g_cpuFrequencyTargets[index];
BOOL sameEntry = entryID != 0
? target->registryEntryID == entryID
: target->entry == entry;
if (sameEntry && CFEqual(target->key, key)) {
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
BOOL sameEntry = entryID != 0
? target->registryEntryID == entryID
: target->entry == entry;
if (sameEntry && CFEqual(target->key, keyCopy)) {
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
target->registryEntryID = entryID;
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

static void removeTrackedCPUFrequencyTarget(uint64_t entryID, io_registry_entry_t entry, CFStringRef key) {
io_registry_entry_t entryToRelease = MACH_PORT_NULL;
CFStringRef keyToRelease = NULL;

os_unfair_lock_lock(&g_cpuFrequencyTargetLock);
for (int index = 0; index < g_cpuFrequencyTargetCount; index++) {
CPUFrequencyTarget *target = &g_cpuFrequencyTargets[index];
BOOL sameEntry = entryID != 0
? target->registryEntryID == entryID
: target->entry == entry;
if (!sameEntry || !CFEqual(target->key, key)) continue;

entryToRelease = target->entry;
keyToRelease = target->key;
for (int moveIndex = index; moveIndex + 1 < g_cpuFrequencyTargetCount; moveIndex++) {
g_cpuFrequencyTargets[moveIndex] = g_cpuFrequencyTargets[moveIndex + 1];
}
g_cpuFrequencyTargetCount--;
memset(&g_cpuFrequencyTargets[g_cpuFrequencyTargetCount], 0, sizeof(CPUFrequencyTarget));
break;
}
os_unfair_lock_unlock(&g_cpuFrequencyTargetLock);

if (keyToRelease) CFRelease(keyToRelease);
if (entryToRelease != MACH_PORT_NULL) IOObjectRelease(entryToRelease);
}

static void trackCPUFrequencyProperties(io_registry_entry_t entry, CFTypeRef properties) {
if (entry == MACH_PORT_NULL || !properties || CFGetTypeID(properties) != CFDictionaryGetTypeID()) return;
NSDictionary *dictionary = (__bridge NSDictionary *)properties;
for (id rawKey in dictionary) {
if (![rawKey isKindOfClass:[NSString class]]) continue;
trackCPUFrequencyTarget(entry, (__bridge CFStringRef)rawKey, (__bridge CFTypeRef)dictionary[rawKey]);
}
}

static CFStringRef maxOperatingFrequencyPropertyName(void) {
static CFStringRef propertyName = NULL;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
propertyName = CFStringCreateWithCString(kCFAllocatorDefault,
"MaxOperatingFrequency",
kCFStringEncodingUTF8);
});
return propertyName;
}

static int applyCPUFrequencyLimitToServices(int targetMHz) {
if (targetMHz <= 0) return 0;

CFStringRef frequencyKey = maxOperatingFrequencyPropertyName();
CFNumberRef targetNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &targetMHz);
if (!frequencyKey || !targetNumber) {
if (targetNumber) CFRelease(targetNumber);
return 0;
}

uint64_t visitedEntryIDs[32] = {0};
int visitedEntryCount = 0;
int successfulWrites = 0;

for (int classIndex = 0; g_cpuControlServiceClasses[classIndex]; classIndex++) {
io_iterator_t iterator = MACH_PORT_NULL;
CFMutableDictionaryRef matching = IOServiceMatching(g_cpuControlServiceClasses[classIndex]);
if (!matching || IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) {
continue;
}

io_service_t service = MACH_PORT_NULL;
while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
uint64_t entryID = registryEntryIDForEntry(service);
BOOL alreadyVisited = NO;
for (int index = 0; index < visitedEntryCount; index++) {
if (entryID != 0 && visitedEntryIDs[index] == entryID) {
alreadyVisited = YES;
break;
}
}
if (alreadyVisited) {
IOObjectRelease(service);
continue;
}
if (entryID != 0 && visitedEntryCount < (int)(sizeof(visitedEntryIDs) / sizeof(visitedEntryIDs[0]))) {
visitedEntryIDs[visitedEntryCount++] = entryID;
}

kern_return_t result = orig_IOServiceSetProperty
? orig_IOServiceSetProperty(service, frequencyKey, targetNumber)
: IORegistryEntrySetCFProperty(service, frequencyKey, targetNumber);
if (result == KERN_SUCCESS) {
successfulWrites++;
trackCPUFrequencyTarget(service, frequencyKey, targetNumber);
}
IOObjectRelease(service);
}
IOObjectRelease(iterator);
}

CFRelease(targetNumber);
return successfulWrites;
}

static void discoverCPUFrequencyTargetsFromServices(void) {
for (int classIndex = 0; g_cpuControlServiceClasses[classIndex]; classIndex++) {
io_iterator_t iterator = MACH_PORT_NULL;
CFMutableDictionaryRef matching = IOServiceMatching(g_cpuControlServiceClasses[classIndex]);
if (!matching || IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) {
continue;
}

io_service_t service = MACH_PORT_NULL;
while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
CFMutableDictionaryRef properties = NULL;
if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
trackCPUFrequencyProperties(service, properties);
CFRelease(properties);
}
IOObjectRelease(service);
}
IOObjectRelease(iterator);
}
}

static void reapplyTrackedCPUFrequencyTargets(void) {
if (!g_enabled || !g_cpuProtection) return;
int targetMHz = targetCPUFrequencyMHz();
if (targetMHz <= 0) return;

int directServiceWrites = applyCPUFrequencyLimitToServices(targetMHz);
discoverCPUFrequencyTargetsFromServices();

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

int successfulWrites = 0;
for (int index = 0; index < snapshotCount; index++) {
int64_t replacementValue = lockedFrequencyValue(snapshot[index].sampleValue, targetMHz);
CFNumberRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &replacementValue);
if (replacement) {
kern_return_t result = orig_IOServiceSetProperty
? orig_IOServiceSetProperty(snapshot[index].entry, snapshot[index].key, replacement)
: KERN_FAILURE;
if (result != KERN_SUCCESS) {
result = IORegistryEntrySetCFProperty(snapshot[index].entry, snapshot[index].key, replacement);
}
if (result == KERN_SUCCESS) successfulWrites++;
else removeTrackedCPUFrequencyTarget(snapshot[index].registryEntryID,
snapshot[index].entry,
snapshot[index].key);
CFRelease(replacement);
}
CFRelease(snapshot[index].key);
IOObjectRelease(snapshot[index].entry);
}

static int lastLoggedTargetMHz = 0;
static int lastLoggedDirectServiceCount = -1;
static int lastLoggedTrackedTargetCount = -1;
if (lastLoggedTargetMHz != targetMHz ||
lastLoggedDirectServiceCount != directServiceWrites ||
lastLoggedTrackedTargetCount != successfulWrites) {
lastLoggedTargetMHz = targetMHz;
lastLoggedDirectServiceCount = directServiceWrites;
lastLoggedTrackedTargetCount = successfulWrites;
NSLog(S("[CPUthermal] CPU 频率目标已重应用: 模式=%@ 目标=%dMHz 服务=%d 属性=%d"),
isLowPowerMode() ? S("低功耗") : S("解除温控"),
targetMHz, directServiceWrites, successfulWrites);
}
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

        g_lowPowerRequestedFrequencyMHz = CPUthermalNormalizedLowPowerLockMHz(
            [d[S("lowPowerLockMHz")] intValue]);

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
// IOKit 层钩子
// ============================================================================

// --- IOServiceSetProperty — 拦截 CPU 频率与网络热节流属性 ---

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

// ===================== 新增：拦截Wi‑Fi/蜂窝基带射频温控限流 =====================
if (isNetworkThrottleProperty(key)) {
return KERN_SUCCESS; // 直接丢弃指令，不写入驱动，取消限流
}

NSString *ks = (__bridge NSString *)key;

// 仅改写真正的 CPU frequency 字段。CPU power/level 字段必须原样放行，
// 否则会把 MitigationController 刚计算出的锁定目标一起吞掉。
if (g_cpuProtection && entryAndKeyTargetCPUFrequency(service, ks)) {
trackCPUFrequencyTarget(service, key, value);
CFTypeRef replacement = copyLockedFrequencyValueForEntry(service, ks, value, targetCPUFrequencyMHz());
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
if (g_cpuProtection && entryAndKeyTargetCPUFrequency(entry, keyString)) {
trackCPUFrequencyTarget(entry, key, value);
CFTypeRef replacement = copyLockedFrequencyValueForEntry(entry, keyString, value, targetCPUFrequencyMHz());
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
CFDictionaryRef replacement = copyLockedFrequencyProperties(entry, properties, targetCPUFrequencyMHz());
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(NO);
return;
}
%orig(enabled);
}

// 强制 CPU 功率曲线目标，防止外部代码写回其他单位。
- (void)setCPULevel:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPowerCurveTarget());
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
[res setCPULevel:targetCPUPowerCurveTarget()];
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
%orig(targetCPUPowerCurveTarget());
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
[self setCPULevel:targetCPUPowerCurveTarget()];
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
return NO;
}
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
if (g_restoringFullPower) {
%orig(active);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig;
}

// 统一锁到当前模式的 CPU 功率曲线目标，防止系统覆盖。
- (void)setCPULevel:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPowerCurveTarget());
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
%orig(targetCPUPowerCurveTarget());
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
applyCurrentModeBudgetsOnController(self);
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
trackPowerController(self);
applyCurrentModeBudgetsOnController(self);
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
    if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
        %orig(kUnrestrictedPowerLimitMW);
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
[self setPowerSaveActive:NO];
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
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
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPowerCurveTarget(), source);
return;
}
%orig;
}

- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(int)contributor {
if (g_restoringFullPower) {
%orig(ceiling, contributor);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPowerCurveTarget(), contributor);
return;
}
%orig;
}

- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) {
%orig(floor, source);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPowerCurveTarget(), source);
return;
}
%orig;
}

- (void)setCPUPowerZoneTarget:(int)target {
if (g_restoringFullPower) {
%orig(target);
return;
}
if (shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()) {
%orig(targetCPUPowerCurveTarget());
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
applyPowerModeToRuntime();
NSLog(S("[CPUthermal] 功率模式已切换: %@ target:%dMHz powerCurve:%d"),
isLowPowerMode() ? S("低功耗") : S("解除温控"),
targetCPUFrequencyMHz(), targetCPUPowerCurveTarget());
};
if ([NSThread isMainThread]) block();
else dispatch_async(dispatch_get_main_queue(), block);
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
loadPrefs();
if (g_enabled) applyPowerModeToRuntime();
NSLog(S("[CPUthermal] 设置已重载 enabled:%d CPU:%d 弹窗:%d 防暗屏:%d target:%dMHz powerCurve:%d"),
g_enabled, g_cpuProtection, g_thermalBlockNotifPopup, g_thermalPreventDimmingEnabled,
targetCPUFrequencyMHz(), targetCPUPowerCurveTarget());
};
if ([NSThread isMainThread]) block();
else dispatch_async(dispatch_get_main_queue(), block);
}

static void onWakeRuntimeEvent(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
dispatch_block_t block = ^{
handleRuntimeWakeEvent((__bridge NSString *)name);
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
dispatch_async(dispatch_get_main_queue(), ^{
handleRuntimeSleepEvent(S("IOKit-system-will-sleep"));
});
return;
}
if (messageType == kIOMessageSystemWillPowerOn || messageType == kIOMessageSystemHasPoweredOn) {
dispatch_async(dispatch_get_main_queue(), ^{
handleRuntimeWakeEvent(messageType == kIOMessageSystemWillPowerOn
? S("IOKit-system-will-power-on")
: S("IOKit-system-has-powered-on"));
});
}
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
(__bridge CFStringRef)S("com.apple.system.awake"),
NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

// displayStatus/lockstate 是双向状态通知，必须读取 notify state 区分熄屏与亮屏；
// 不能再把锁屏事件误当唤醒，否则深睡期间恢复任务会卡在“已调度”状态。
registerRuntimePowerStateNotifications();

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
