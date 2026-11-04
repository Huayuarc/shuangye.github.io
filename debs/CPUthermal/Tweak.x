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
#include <spawn.h>
#include <sys/wait.h>
#include <CPUthermalPaths.h>
#include <CPUthermalCompat.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <os/lock.h>
#import <os/log.h>
#import <mach/host_info.h>
#import <mach/task_info.h>

// 本仓库的 GitHub CI 不定义 APELIN_BUILD_ID（该宏由 Apelin 构建注入），
// 这里给出可直接编译的默认标记，避免 CI 因未定义标识符失败。
#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "isolation.49"
#endif

// The public SDK marks these private iOS IOKit entry points unavailable even though
// thermalmonitord exports and uses them. Keep the runtime ABI without referencing
// the unavailable declarations directly.
#define kIOMasterPortDefault MACH_PORT_NULL
extern kern_return_t CPUthermalIORegistryEntrySetCFProperty(io_registry_entry_t, CFStringRef, CFTypeRef) __asm("_IORegistryEntrySetCFProperty");

static os_log_t CPUthermalRuntimeLog(void) {
static os_log_t logger;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{ logger = os_log_create("com.huayuarc.cputhermal", "runtime"); });
return logger;
}

// ============================================================================
// ObjC 类声明（thermalmonitord 内部类，class-dump 获取）
// ============================================================================
@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)arg1 service:(uintptr_t)arg2;
@end

@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)tryTakeAction;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
- (void)setThermalState:(int)state; // 主动调用仍按运行时 encoding 校验，不信任声明。
- (void)setHiPFeatureEnabled:(BOOL)enabled;
- (int)dieTempFilteredMaxAverage;
- (int)getHighestSkinTemp;
- (BOOL)shouldEnforceLightThermalPressure;
- (unsigned long long)getPotentialForcedThermalLevel:(unsigned long long)component;
- (BOOL)getPotentialForcedThermalPressureLevel;
// isolation.49：以下均为离线核对（tools/objcdump.py）确认存在的真实 selector。
- (unsigned long long)componentThermalStatusLevel;
- (long long)thermalPressureLevel;
- (BOOL)mitigationsFullyReleased;
- (void)evaluteMitigationMaxLoadingIndex;
- (void)handleMCSThermalPressure;
- (void)emitThermalTrendNotifications;
- (void)emitThermalMitigationNotifications;
- (void)updateDisplayDriver:(BOOL)state;
- (void)sendMaxTempToDisplayDriver:(int)temperature;
- (void)clearLoadingIndexOverrides;
- (void)clearControlEffortOverrides;
@end

// ============================================================================
// ThermalManager —— isolation.49 按 tools/objcdump.py 对 /rootfs/usr/libexec/thermalmonitord
// 的离线核对重写。真实 ThermalManager 只有 33 个方法（配置读取、产品创建、系统负载、
// 校准与 canary），旧版声明的 evaluateDecisionTree / actionComponentControl /
// readReleaseRateForAllComponents / getReleaseRateForComponent: / findComponent: /
// initWithComponentControllers:hotspotControllers:decisionTreeTable: /
// updateThermal*Notification: / shouldEnforceLightThermalPressure /
// getPotentialForcedThermalLevel: / setCPMSMitigationState: 一个都不在它身上：
// 决策树那几个属于 TableDrivenDecisionTree，通知那几个属于 NotificationManager，
// getPotentialForcedThermalLevel: 属于 CommonProduct，setCPMSMitigationState: 属于
// ComponentControl/BackLightCC。全部改到真实宿主上接管。
@interface ThermalManager : NSObject
- (id)initWithConfig:(id)config;                        // @24@0:8^{__CFDictionary=}16
- (void)createNewProduct:(id)runloop;                   // v24@0:8^{__CFRunLoop=}16
- (id)getConfigurationFor:(NSString *)key;              // ^v24@0:8^{__CFString=}16
- (void)hintComponentControlTakeAction;                 // v16@0:8
- (void)probeAllSupervisorControlLoadingIndex;          // v16@0:8
- (void)updateSystemLoad:(BOOL)load;                    // v20@0:8B16
- (void)updateSystemPowerState:(BOOL)state;             // v20@0:8B16
- (BOOL)isDeviceApplicable;                             // B16@0:8
- (BOOL)getPotentialForcedThermalPressureLevel;         // B16@0:8
- (int)desiredLoopInterval;                             // i16@0:8
@end

// 决策树本体：真实类名 TableDrivenDecisionTree（8 个方法），
// evaluateDecisionTree/actionComponentControl/readReleaseRateForAllComponents 都是 v16@0:8，
// getReleaseRateForComponent: 是 i20@0:8i16（整数，不是 float/double），findCC: 是 @20@0:8i16。
@interface TableDrivenDecisionTree : NSObject
- (id)initWithComponentControllers:(id)components hotspotControllers:(id)hotspots decisionTreeTable:(id)table;
- (int)getMTypeFromComponent:(int)component;            // i20@0:8i16
- (void)actionComponentControl;                         // v16@0:8
- (int)getReleaseRateForComponent:(int)component;       // i20@0:8i16
- (void)readReleaseRateForAllComponents;                // v16@0:8
- (void)evaluateDecisionTree;                           // v16@0:8
- (id)findCC:(int)component;                            // @20@0:8i16
- (id)initDecisionTable:(id)table;                      // v24@0:8^{__CFDictionary=}16
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
- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setMaxPackagePower:(int)power;
- (int)CPULevel;
- (void)setCPULevel:(int)level;
- (void)setDVD1Level:(int)level;
- (BOOL)powerSaveActive;
- (void)setPowerSaveToken:(int)token;
// isolation.49：按真实 encoding 补充（i36@0:8 I16 ^{__CFString=}20 i28 B32 / v32@0:8 ^{__CFString=}16 i24 B28）。
// 注意 MitigationController 上并不存在 setCPUMitigationLevel: 与 setPowerSaveActive:，
// 旧版那两个钩子从未安装；低功耗预算改由 setCPULowPowerTarget: / setMaxCPUPowerTarget: /
// setCPUPowerZoneTarget: / setCPUPowerCeiling: 这条真实链路落地。
- (int)setServiceProperty:(unsigned int)service key:(id)key value:(int)value scaleToFixedPoint:(BOOL)scale;
- (void)setDieTempControllerProperty:(id)property level:(int)level scaleToFixedPoint:(BOOL)scale;
- (void)setPackagePowerBudgetDirect:(int)budget withDetails:(unsigned long long)details;
- (void)setPackagePowerZoneTarget;
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

// A15/iOS 16 在全局 CPMS 关闭时，部分 ObjC setter 只更新 thermalmonitord 缓存，
// 不会提交到 ApplePPM/AppleCLPC。直接写 CPU 专用属性，避免启动 Display/DCP 缓解。
static kern_return_t CPUthermalSetCPUPropertyOnService(const char *serviceName, CFStringRef key, int32_t value) {
if (!serviceName || !key) return KERN_INVALID_ARGUMENT;
CFMutableDictionaryRef matching = IOServiceMatching(serviceName);
if (!matching) return KERN_FAILURE;
io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
if (!service) {
os_log_error(CPUthermalRuntimeLog(), "service missing: %{public}s", serviceName);
return KERN_NOT_FOUND;
}
CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
kern_return_t result = number ? CPUthermalIORegistryEntrySetCFProperty(service, key, number) : KERN_RESOURCE_SHORTAGE;
CFTypeRef readback = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
int32_t actual = INT32_MIN;
BOOL readable = readback && CFGetTypeID(readback) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)readback, kCFNumberSInt32Type, &actual);
os_log(CPUthermalRuntimeLog(), "hardware set service=%{public}s key=%{public}@ value=%d kr=%d readback=%d readable=%d", serviceName, key, value, result, actual, readable);
if (readback) CFRelease(readback);
if (number) CFRelease(number);
IOObjectRelease(service);
return result;
}

static void CPUthermalApplyDirectCPUHardwareLimits(BOOL lowPower) {
// AppleCLPC 动态功率目标使用 Q24 瓦特；-1.0 是系统原生“不限制”哨兵。
const int32_t unrestrictedQ24 = (int32_t)0xff000000;
const int32_t lowPowerQ24 = (int32_t)(2.5 * 16777216.0);
const int32_t target = lowPower ? lowPowerQ24 : unrestrictedQ24;
CPUthermalSetCPUPropertyOnService("AppleCLPC", CFSTR("`pkg-low-power-target"), target);
CPUthermalSetCPUPropertyOnService("AppleCLPC", CFSTR("`pkg-avg-therm-power-target"), target);
}

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;      // 配置与 CommonProduct
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_runtimeLock = OS_UNFAIR_LOCK_INIT;    // 有限模式应用任务
static __thread BOOL g_restoringFullPower = NO;
static __thread BOOL g_reassertingSharedBudgets = NO;
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
static void forceCPUPerformanceLevelOnController(id controller);
static void applyFullPowerBudgetsOnController(id controller);
static void applyLowPowerToCommonProduct(void);
static void applyLowPowerPerformancePreferenceToController(id controller);
static void applyLowPowerLimitsToTrackedControllers(void);
static void restoreNativeRuntimeAfterDisable(void);
static void restoreFullPowerToTrackedControllers(void);
static void correctNominalStateIfNeeded(void);
static void switchToLowPowerForSleep(const char *source);
static void restoreUserModeAfterWake(const char *source);
static void registerScreenWakeObservers(void);
static void CPUthermalCaptureExistingBacklightMaximum(void);
static NSUInteger CPUthermalRaiseExistingBacklightLimits(void);
static void CPUthermalScheduleBacklightRecovery(void);
static void applyFullPowerToCommonProduct(void);

static void runtimeConfigSnapshot(BOOL *enabled, BOOL *cpuProtection, BOOL *blockNetwork, BOOL *blockPopup) {
os_unfair_lock_lock(&g_stateLock);
if (enabled) *enabled = g_enabled;
if (cpuProtection) *cpuProtection = g_cpuProtection;
if (blockNetwork) *blockNetwork = g_blockNetworkThermalThrottle;
if (blockPopup) *blockPopup = g_thermalBlockNotifPopup;
os_unfair_lock_unlock(&g_stateLock);
}

static BOOL runtimeEnabled(void) {
BOOL enabled = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL);
return enabled;
}

static BOOL runtimeProtectionEnabled(void) {
BOOL enabled = NO;
BOOL cpuProtection = NO;
runtimeConfigSnapshot(&enabled, &cpuProtection, NULL, NULL);
return enabled && cpuProtection;
}

static BOOL networkThrottleBlockingEnabled(void) {
BOOL enabled = NO;
BOOL blockNetwork = NO;
runtimeConfigSnapshot(&enabled, NULL, &blockNetwork, NULL);
return enabled && blockNetwork && isFullPowerMode();
}

static BOOL thermalPopupBlockingEnabled(void) {
BOOL enabled = NO;
BOOL blockPopup = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, &blockPopup);
return enabled && blockPopup;
}

static BOOL thermalDimmingPreventionEnabled(void) {
// 防温控暗屏恒开：不再依赖任何偏好开关（面板已移除该项）。
BOOL enabled = NO;
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL);
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

static BOOL shouldRestoreNativePerformance(void) {
return shouldApplyFullCPUProtection();
}

static BOOL shouldApplyLowPowerLimit(void) {
// 低功耗运行方式：与解除温控同一总开关，按当前模式判定（此前恒为 NO 导致切档无效果）。
return runtimeProtectionEnabled() && isLowPowerMode();
}

static BOOL shouldForceNominalThermalPressure(void) {
return runtimeProtectionEnabled();
}

static void correctNominalStateIfNeeded(void) {
if (!shouldForceNominalThermalPressure()) return;
CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
os_unfair_lock_lock(&g_nominalLock);
BOOL shouldCorrect = (now - g_lastNominalCorrection) >= 1.0;
if (shouldCorrect) g_lastNominalCorrection = now;
os_unfair_lock_unlock(&g_nominalLock);
if (shouldCorrect) CPUthermalForceNominalPressure();
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
// applyPowerModeToRuntime() 已启动统一的亮度恢复事务；这里不再额外叠加三轮
// IORegistry 全树扫描，避免解锁后与前台触控争抢 CPU/IOKit。
// 解锁/亮屏后系统会重新评估性能等级：低功耗模式下必须立刻重申锁频，
// 否则界面仍是低功耗但频率会回到最高。
if (isLowPowerMode()) {
CPUthermalApplySimulatedThermalLevel();
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
CPUthermalApplyDirectCPUHardwareLimits(YES);
// 解锁后 powerd/CLPC 会在短时间内重建 CPU 预算；补一组有界重申，
// 使运行态重新匹配持久化的 lowPower，而不是只让面板保持 lowPower。
scheduleLowPowerApplyPulse();
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
    if (token <= 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK || state == 0 || !shouldForceNominalThermalPressure()) return;
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&g_thermalResetLock);
    BOOL allowed=(now-g_lastThermalReset)>=5.0;
    if(allowed)g_lastThermalReset=now;
    os_unfair_lock_unlock(&g_thermalResetLock);
    if (!allowed) return;
    CPUthermalForceNominalPressure();
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
return kFullPowerCPULevel;   // fullPower 使用 Level 0（无 mitigation）；Floor=100 仅为用户态预算请求，不保证实际频率
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

static void sendTwoIntegerArguments(id object, SEL selector, intptr_t firstValue, uintptr_t secondValue) {
if (!object || !selector || ![object respondsToSelector:selector]) return;
Method method = class_getInstanceMethod(object_getClass(object), selector);
if (!method || method_getNumberOfArguments(method) != 4) return;
char result[32] = {0};
method_getReturnType(method, result, sizeof(result));
if (strcmp(result, "v") != 0 || methodArgumentTypeCode(object, selector, 0) != '@' ||
    methodArgumentTypeCode(object, selector, 1) != ':') return;
char type0[32] = {0}, type1[32] = {0}, firstEncoding[32] = {0}, secondEncoding[32] = {0};
method_getArgumentType(method, 0, type0, sizeof(type0));
method_getArgumentType(method, 1, type1, sizeof(type1));
method_getArgumentType(method, 2, firstEncoding, sizeof(firstEncoding));
method_getArgumentType(method, 3, secondEncoding, sizeof(secondEncoding));
if (strcmp(type0, "@") || strcmp(type1, ":")) return;
if (strlen(firstEncoding) != 1 || strlen(secondEncoding) != 1) return;
char firstType = firstEncoding[0];
char secondType = secondEncoding[0];
if (!strchr("iIqQ", firstType) || !strchr("iIqQ", secondType)) return;
if (firstType == 'i' && secondType == 'i') {
((void (*)(id, SEL, int, int))objc_msgSend)(object, selector, (int)firstValue, (int)secondValue);
return;
}
if (firstType == 'i' && secondType == 'I') {
((void (*)(id, SEL, int, uint32_t))objc_msgSend)(object, selector, (int)firstValue, (uint32_t)secondValue);
return;
}
if (firstType == 'i' && secondType == 'q') {
((void (*)(id, SEL, int, int64_t))objc_msgSend)(object, selector, (int)firstValue, (int64_t)secondValue);
return;
}
if (firstType == 'i' && secondType == 'Q') {
((void (*)(id, SEL, int, uint64_t))objc_msgSend)(object, selector, (int)firstValue, (uint64_t)secondValue);
return;
}
if (firstType == 'I' && secondType == 'i') {
((void (*)(id, SEL, uint32_t, int))objc_msgSend)(object, selector, (uint32_t)firstValue, (int)secondValue);
return;
}
if (firstType == 'I' && secondType == 'I') {
((void (*)(id, SEL, uint32_t, uint32_t))objc_msgSend)(object, selector, (uint32_t)firstValue, (uint32_t)secondValue);
return;
}
if (firstType == 'I' && secondType == 'q') {
((void (*)(id, SEL, uint32_t, int64_t))objc_msgSend)(object, selector, (uint32_t)firstValue, (int64_t)secondValue);
return;
}
if (firstType == 'I' && secondType == 'Q') {
((void (*)(id, SEL, uint32_t, uint64_t))objc_msgSend)(object, selector, (uint32_t)firstValue, (uint64_t)secondValue);
return;
}
if (firstType == 'q' && secondType == 'i') {
((void (*)(id, SEL, int64_t, int))objc_msgSend)(object, selector, (int64_t)firstValue, (int)secondValue);
return;
}
if (firstType == 'q' && secondType == 'I') {
((void (*)(id, SEL, int64_t, uint32_t))objc_msgSend)(object, selector, (int64_t)firstValue, (uint32_t)secondValue);
return;
}
if (firstType == 'q' && secondType == 'q') {
((void (*)(id, SEL, int64_t, int64_t))objc_msgSend)(object, selector, (int64_t)firstValue, (int64_t)secondValue);
return;
}
if (firstType == 'q' && secondType == 'Q') {
((void (*)(id, SEL, int64_t, uint64_t))objc_msgSend)(object, selector, (int64_t)firstValue, (uint64_t)secondValue);
return;
}
if (firstType == 'Q' && secondType == 'i') {
((void (*)(id, SEL, uint64_t, int))objc_msgSend)(object, selector, (uint64_t)firstValue, (int)secondValue);
return;
}
if (firstType == 'Q' && secondType == 'I') {
((void (*)(id, SEL, uint64_t, uint32_t))objc_msgSend)(object, selector, (uint64_t)firstValue, (uint32_t)secondValue);
return;
}
if (firstType == 'Q' && secondType == 'q') {
((void (*)(id, SEL, uint64_t, int64_t))objc_msgSend)(object, selector, (uint64_t)firstValue, (int64_t)secondValue);
return;
}
if (firstType == 'Q' && secondType == 'Q') {
((void (*)(id, SEL, uint64_t, uint64_t))objc_msgSend)(object, selector, (uint64_t)firstValue, (uint64_t)secondValue);
return;
}
// 未识别 ABI 不发送；floor setter 的百分比语义沿用现工程，不猜新 SoC 接口。
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

// 只清 floor，不写 CPU Level、全局 PowerSave 或显示状态。sources 沿用源码假定的 0..5。
static void setRequestedFloors(id object, BOOL includeCPU, int value) {
if (!object) return;
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
if (includeCPU) sendTwoIntegerArguments(object, @selector(setCPUPowerFloor:fromDecisionSource:), value, (uintptr_t)source);
sendTwoIntegerArguments(object, @selector(setGPUPowerFloor:fromDecisionSource:), value, (uintptr_t)source);
sendTwoIntegerArguments(object, @selector(setPackagePowerFloor:fromDecisionSource:), value, (uintptr_t)source);
}
}

// 事件重申只写 GPU/共享 Package 预算；thread-local 避免 setter 内部 update 递归。
static void reassertSharedFullPowerBudgets(id object) {
if (!object || !shouldApplyFullCPUProtection() || g_reassertingSharedBudgets) return;
g_reassertingSharedBudgets = YES;
@try {
for (int source = 0; source < kCPUDecisionSourceCount; source++) {
sendTwoIntegerArguments(object, @selector(setGPUPowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent, (uintptr_t)source);
sendTwoIntegerArguments(object, @selector(setGPUPowerFloor:fromDecisionSource:), kUnrestrictedPerformancePercent, (uintptr_t)source);
sendTwoIntegerArguments(object, @selector(setPackagePowerCeiling:fromDecisionSource:), kUnrestrictedPerformancePercent, (uintptr_t)source);
sendTwoIntegerArguments(object, @selector(setPackagePowerFloor:fromDecisionSource:), kUnrestrictedPerformancePercent, (uintptr_t)source);
}
} @finally {
g_reassertingSharedBudgets = NO;
}
}

static void applyExplicitLowPowerBudgets(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
setRequestedFloors(controller, NO, 0);
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

// 低功耗重申只覆盖 CPU Level/预算；power-save 只允许在主动 updateCPU 事务内短暂使用，
// 禁止长期保持 YES，避免联动 Display/DCP 降低亮度。
static void reassertLowPowerStateWithoutUpdate(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
if (g_reassertingLowPower) return;   // 已在重断言中：hook 回调直接放行，杜绝递归
g_reassertingLowPower = YES;
@try {
trackPowerController(controller);
if ([controller respondsToSelector:@selector(setCPULevel:)])
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kLowPowerCPULevel);
// 注意：此处绝不能再 msgSend updateCPU —— 它会回到 updateCPU 钩子形成无限递归（栈溢出崩溃）
if ([controller respondsToSelector:@selector(setCPULevel:)])
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kLowPowerCPULevel);
applyExplicitLowPowerBudgets(controller);
} @finally {
g_reassertingLowPower = NO;
}
}

// 低功耗只通过 thermalmonitord 已核实的 CPU level 与预算接口落地。
static void applyLowPowerPerformancePreferenceToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
trackPowerController(controller);
applyExplicitLowPowerBudgets(controller);
forceCPUPerformanceLevelOnController(controller);
if ([controller respondsToSelector:@selector(updateCPU)])
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
// updateCPU 可能按缓存重写状态，返回后再次固定 Level 与预算。
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
if (!controller || !shouldApplyFullCPUProtection()) return;
if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), NO);
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
sendTwoIntegerArguments(controller, @selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPerformancePercent, (uintptr_t)source);
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
reassertSharedFullPowerBudgets(controller);
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
if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kFullPowerCPULevel);
}
// 禁用时 CPU/GPU/Package 所有已有 sources 的请求 floor 清零。
setRequestedFloors(controller, YES, 0);
if ([controller respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
}
if ([controller respondsToSelector:@selector(updateGPU)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateGPU));
}
if ([controller respondsToSelector:@selector(updatePackage)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
}
setRequestedFloors(controller, YES, 0);
}
} @catch (__unused NSException *exception) {
} @finally {
g_restoringFullPower = NO;
}
}
}

static void applyLowPowerToCommonProduct(void) {
// CommonProduct does not own CPU level or budget setters on iOS 16.
}

static void applyFullPowerToCommonProduct(void) {
if (!shouldApplyFullCPUProtection() || !commonProductSnapshot()) return;
CPUthermalForceNominalPressure();
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
// 严格 CPU-only：热压力固定 Nominal，不调用亮度、热模拟、GPU、Package 或全局 CPMS 路径。
CPUthermalForceNominalPressure();
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
CPUthermalApplyDirectCPUHardwareLimits(YES);
scheduleLowPowerApplyPulse();
startLowPowerRescheduleTimer();
return;
}
if (isFullPowerMode()) {
// 模式切换严格不触碰亮度、Display/DCP 或热模拟；只恢复 CPU 专用限制。
CPUthermalForceNominalPressure();
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
CPUthermalApplyDirectCPUHardwareLimits(NO);
scheduleFullPowerRecoveryPulse();
stopLowPowerRescheduleTimer();
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
CPUthermalApplyDirectCPUHardwareLimits(NO);
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
// 覆盖解锁后约 2.5 秒的 CLPC 重建窗口；6 次足够，避免旧版 12 次批量 setter 造成后台争用。
runLowPowerApplyPulse(6);
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
CPUthermalApplyDirectCPUHardwareLimits(YES);
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
        applyLowPowerToCommonProduct();applyLowPowerLimitsToTrackedControllers();CPUthermalApplyDirectCPUHardwareLimits(YES);
    });
    dispatch_resume(timer);
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
    // 现在亮度恢复完全交给核心内“只抬不压”通道（isolation.9：原独立显示模块已移除，
    // BLNitsCap/brightness-nits 等限制键的恢复并入 CPUthermal 核心），不再由本函数向 CoreBrightness 提交任何亮度。
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
    "BLNitsCap","brightness-nits",NULL};

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
// 除“当前上限”外，优先读取面板原生最大亮度（滑块最大值）。
    // 控制中心/CallAssist 显示的“滑块最大值 1060”正是这类键，它不受温控压低影响，
    // 是唯一能在上限已被压暗时仍能拿到真实面板上限的来源。
    NSArray *keys = @[@"DisplayBrightnessMax", @"BrightnessMax", @"SliderMax",
                       @"MaxBrightness", @"BrightnessMaxNits",
                       @"DisplayBrightness", @"DisplayBrightnessLimit", @"BrightnessLimit"];
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
                        CPUthermalIORegistryEntrySetCFProperty(entry, key, (__bridge CFTypeRef)writeValue);
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
    os_unfair_lock_lock(&g_brightnessRecommitLock);
    if (!thermalDimmingPreventionEnabled() || g_backlightRecoveryScheduled) {
        os_unfair_lock_unlock(&g_brightnessRecommitLock);
        return;
    }
    g_backlightRecoveryScheduled = YES;
    os_unfair_lock_unlock(&g_brightnessRecommitLock);
    CPUthermalStartBacklightAuditTimer();
    // 只保留两次低优先级确认；写入 hook 已处理实时限制，避免七轮全树扫描拖慢前台交互。
    const double delays[] = {0.50, 3.00};
    for (NSUInteger i=0;i<sizeof(delays)/sizeof(delays[0]);i++) {
        BOOL finalAttempt=(i+1==sizeof(delays)/sizeof(delays[0]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delays[i]*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            CPUthermalRestoreExistingBacklightLimit();
            if(finalAttempt){
                os_unfair_lock_lock(&g_brightnessRecommitLock);
                g_backlightRecoveryScheduled=NO;
                g_userBrightnessBeforeModeChange=nil;
                os_unfair_lock_unlock(&g_brightnessRecommitLock);
            }
        });
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
// isolation.9：原独立显示模块（已移除）独占的 BLNitsCap 16.16 上限与 brightness-nits
// 键并入核心（仅注入 thermalmonitord）。0 值仍视为关机/关闭指令，不做替换。
if ([lower isEqualToString:S("blnitscap")] ||
    [lower isEqualToString:S("brightness-nits")]) return YES;
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
// isolation.9 只升不降：先算出候选上限，再与原值比较；只有原值确实低于候选时才替换。
// 核心无法拦截其它进程写入，因此绝不能把别人写入的更高值压回上限（那等于自己制造降亮度）。
double candidate = 0.0;
id replacement = nil;
if ([originalValue isKindOfClass:[NSString class]]) {
    double v = [(NSString *)originalValue doubleValue];
    if (v <= 0.0) return nil;                  // 0 = 关机/关闭指令，绝不替换
    candidate = (v > kCPUthermalFixedPointScale)
        ? [(NSNumber *)maximum doubleValue] * kCPUthermalFixedPointScale
        : [(NSNumber *)maximum doubleValue];
    replacement = (v > kCPUthermalFixedPointScale)
        ? [NSString stringWithFormat:@"%.0f", candidate]
        : [(NSNumber *)maximum stringValue];
} else if ([originalValue isKindOfClass:[NSNumber class]]) {
    double v = [(NSNumber *)originalValue doubleValue];
    if (v <= 0.0) return nil;
    candidate = (v > kCPUthermalFixedPointScale)
        ? [(NSNumber *)maximum doubleValue] * kCPUthermalFixedPointScale
        : [(NSNumber *)maximum doubleValue];
    replacement = @(candidate);
} else return nil;                              // 其它类型（CFData 等）不做替换
double original = [originalValue doubleValue];
if (original + 0.5 >= candidate) return nil;    // 已不低于上限：不写，避免反向压暗
return replacement;
}

// ---------------------------------------------------------------------------
// isolation.49 — 背光上限（cap）识别与“只升不降”的运行时学习
//
// thermalmonitord 最终把热暗屏落成两条写入：
//   1) BackLightCC  setBrightnessKey:value:                    （BrightnessSystemClient 键值）
//   2) MitigationController setServiceProperty:key:value:...   （IOKit 属性）
// 两条路的键名和单位都不同（nits / 16.16 定点 / millinits 都出现过），所以按“键”
// 分别记住见过的最大值：只允许把更低的上限抬回同一个键已见过的最大值，
// 绝不凭空造一个更大的数（单位不明会把亮度写爆）。value<=0 一律视为
// 关机/关闭指令，原样放行，与 isolation.9 的策略保持一致。
// ---------------------------------------------------------------------------
static os_unfair_lock g_backlightCapLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *g_backlightCapMaximum = nil;

static NSString *CPUthermalKeyDescription(id key) {
if (!key) return nil;
if ([key isKindOfClass:[NSString class]]) return (NSString *)key;
@try {
id description = [key description];
return [description isKindOfClass:[NSString class]] ? (NSString *)description : nil;
} @catch (__unused NSException *exception) {
return nil;
}
}

static BOOL CPUthermalKeyIsBacklightCap(NSString *key) {
if (!key.length) return NO;
if (keyIsDisplayLifecycleProperty(key)) return NO;   // 熄屏/唤醒等状态键不是亮度上限
NSString *lower = [key lowercaseString];
BOOL mentionsBrightness = [lower containsString:S("brightness")] ||
                          [lower containsString:S("backlight")] ||
                          [lower containsString:S("nits")] ||
                          [lower containsString:S("luminance")];
if (!mentionsBrightness) return NO;
return [lower containsString:S("cap")] ||
       [lower containsString:S("ceiling")] ||
       [lower containsString:S("limit")] ||
       [lower containsString:S("max")] ||
       [lower containsString:S("weak")];
}

// 记住这个键见过的最大上限；返回应当写入的值（>= value）。
static int CPUthermalRaiseBacklightCapValue(NSString *key, int value) {
if (!key.length || value <= 0) return value;
os_unfair_lock_lock(&g_backlightCapLock);
if (!g_backlightCapMaximum) g_backlightCapMaximum = [[NSMutableDictionary alloc] init];
NSNumber *known = g_backlightCapMaximum[key];
int maximum = known ? [known intValue] : 0;
if (value > maximum) {
maximum = value;
g_backlightCapMaximum[key] = @(value);
}
os_unfair_lock_unlock(&g_backlightCapLock);
return maximum > value ? maximum : value;
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
// 屏蔽高温温度计警告：随面板开关 blockThermalPopup（键缺失=NO，默认关闭）；
// 经 com.huayuarc.cputhermal/settingsChanged 通知即时重载生效。
id blockPopupValue = d[S("blockThermalPopup")];
BOOL blockPopup = blockPopupValue ? [blockPopupValue boolValue] : NO;
// 防温控暗屏：**恒开**（面板已移除开关）。此前该键缺失/为 false 时整套防降亮度保护
// 会静默失效，实测表现为高温照常降亮度且写入拦截零命中。
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
os_log(CPUthermalRuntimeLog(), "isolation.49 prefs mode=%{public}s path=%{public}s", userMode == CPUthermalPowerModeLow ? "lowPower" : "fullPower", CPUthermalCurrentPrefPath().UTF8String ?: "(null)");
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
static NSDictionary *patchThermalPlist(NSDictionary *dict);

%hook CommonProduct

// 温度 getter 保留原生：未确认返回 ABI 和单位，禁止 int/float 位模式伪装。
//
// isolation.49：setServiceProperty:key:value:scaleToFixedPoint: 与
// shouldEnforceLightThermalPressure 已从 CommonProduct 移除 —— 离线核对确认这两个
// selector 分别只属于 MitigationController 和 SupervisorControl（三个类都是根类，
// 没有继承关系），挂在 CommonProduct 上从未安装成功。真实位置已各自接管。

// 强制热级别 / 热压力级别：两种运行模式均固定 Nominal。
// 真实 encoding Q24@0:8Q16 / B16@0:8 —— 旧版按 int 返回会丢掉高 32 位并让调用方
// 把 BOOL 当成 int 读，等级值不可信。
- (unsigned long long)getPotentialForcedThermalLevel:(unsigned long long)component {
if (shouldForceNominalThermalPressure()) return 0;
return %orig(component);
}

- (BOOL)getPotentialForcedThermalPressureLevel {
if (shouldForceNominalThermalPressure()) return NO;
return %orig;
}

// @24@0:8@16 —— 参数是对象，不是 uintptr_t。
- (id)initProduct:(id)arg1 {
id res = %orig(arg1);
if (res && runtimeEnabled()) {
setCommonProduct((CommonProduct *)res);
// 不再调用 putDeviceInThermalSimulationMode:（私有 API、字符串参数语义不明，
// 曾使守护进入被压低的模拟热档，进而把 CPU 频率压低且不随卸载恢复）
dispatch_async(CPUthermalEngineQueue(), ^{ applyCurrentPowerModeToRuntime(); });

}
return res;
}

- (void)tryTakeAction {
if (shouldForceNominalThermalPressure()) {
// 强制热压力为 Nominal（最多每秒校正一次，避免快循环广播）
correctNominalStateIfNeeded();
// 阻止所有热缓解动作
return;
}
%orig;
}

- (void)simulateLightThermalPressure {
if (shouldForceNominalThermalPressure()) {
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
// 真实名字是 setIsCPMSMitigationEnabled:（v20@0:8B16）；旧版钩的 setCPMSMitigationsEnabled:
// 在 CommonProduct 上并不存在，从未生效（真正的那个在 MitigationController，已单独接管）。
- (void)setIsCPMSMitigationEnabled:(BOOL)enabled {
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

- (BOOL)isCPMSMitigationEnabled {
if (shouldApplyFullCPUProtection()) return NO;
return %orig;
}

// ---------------------------------------------------------------------------
// isolation.49 — CommonProduct 自己真实存在的缓解调度入口。
//
// 旧版把 setCPULevel:/setCPUPowerCeiling:/setCPUPowerFloor:/setGPUPowerCeiling:/
// setPackagePowerCeiling: 挂在了 CommonProduct 上；离线核对确认这五个 selector 只属于
// MitigationController（两者都是根类，无继承），所以那五个钩子从未安装过 —— 这正是
// “模式切了解除温控，实际还是掉频掉亮度”的原因之一。真实位置在 %hook MitigationController
// 里按 v24@0:8i16i20 接管，这里改为掐断 CommonProduct 的调度层本身。
// ---------------------------------------------------------------------------

// 评估各组件允许的最大缓解档：解除温控下根本不跑这次评估。
- (void)evaluteMitigationMaxLoadingIndex {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

// 主动探测所有 SupervisorControl 的 LI（会触发新一轮缓解下发）。
- (void)probeAllSupervisorControlLoadingIndex {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

// i20@0:8I16 —— 某组件当前允许的最大缓解档。
- (int)getCurrentMaxLIForComponent:(unsigned int)component {
if (shouldApplyFullCPUProtection()) return 0;
return %orig(component);
}

// i16@0:8
- (int)maxControlEffort {
if (shouldApplyFullCPUProtection()) return 0;
return %orig;
}

// B16@0:8 —— 让所有读它的一方都认为缓解已全部释放。
- (BOOL)mitigationsFullyReleased {
if (shouldApplyFullCPUProtection()) return YES;
return %orig;
}

// v20@0:8B16
- (void)updateAllThermalLoad:(BOOL)load {
if (shouldApplyFullCPUProtection()) return;
%orig(load);
}

// 热状态与热压力等级的对外读数：固定 Nominal（0）。
// 注意 updateMaxLIFor:: / updateControlEffortFor:: 这两个“空关键字”selector 不用 Logos 挂，
// 它们的下游（ComponentControl setMaxLoadingIndex:、PidComponent setControlEffort:、
// SupervisorControl maxLIForComponent:）已经全部接管，效果等价。
- (void)setThermalState:(int)state {
if (shouldForceNominalThermalPressure()) { %orig(0); return; }
%orig(state);
}

- (int)thermalState {
if (shouldForceNominalThermalPressure()) return 0;
return %orig;
}

// q16@0:8
- (long long)thermalPressureLevel {
if (shouldForceNominalThermalPressure()) return 0;
return %orig;
}

// Q16@0:8 / v24@0:8Q16
- (unsigned long long)componentThermalStatusLevel {
if (shouldForceNominalThermalPressure()) return 0;
return %orig;
}

- (void)setComponentThermalStatusLevel:(unsigned long long)level {
if (shouldForceNominalThermalPressure()) { %orig(0); return; }
%orig(level);
}

// 热压力处理与对外通知：不再产生任何“正在缓解”的信号。
- (void)handleMCSThermalPressure {
if (shouldForceNominalThermalPressure()) return;
%orig;
}

- (void)emitThermalMitigationNotifications {
if (shouldForceNominalThermalPressure()) return;
%orig;
}

- (void)emitThermalTrendNotifications {
if (shouldForceNominalThermalPressure()) return;
%orig;
}

// ---------------------------------------------------------------------------
// 显示驱动侧的热数据通道：thermalmonitord 会把最高温度和 2D 温度网格送给显示驱动，
// 面板据此自行压暗。这条路与 BackLightCC 并行，是“配置改干净了还是掉亮度”的另一半原因。
// ---------------------------------------------------------------------------
- (BOOL)isSendingMaxTempToDisplayDriverEnabled {
if (thermalDimmingPreventionEnabled()) return NO;
return %orig;
}

- (void)enableSendingMaxTempToDisplayDriver {
if (thermalDimmingPreventionEnabled()) return;
%orig;
}

// v20@0:8B16
- (void)updateDisplayDriver:(BOOL)update {
if (thermalDimmingPreventionEnabled()) return;
%orig(update);
}

// v20@0:8i16
- (void)sendMaxTempToDisplayDriver:(int)maxTemp {
if (thermalDimmingPreventionEnabled()) return;
%orig(maxTemp);
}

// v24@0:8^i16
- (void)send2DGridTempsToDisplayDriver:(int *)gridTemps {
if (thermalDimmingPreventionEnabled()) return;
%orig(gridTemps);
}

// ContextualClamp（上下文亮度钳制）刷新：防暗屏时不重算钳制值。
- (void)updateContextualClamp {
if (thermalDimmingPreventionEnabled()) return;
%orig;
}

%end

// --- HidSensors: HID 温度事件处理（屏蔽高温温度计警告）---
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(uintptr_t)arg2 {
// 告警屏蔽开启时不转发温度事件。
if (thermalPopupBlockingEnabled()) {
if (shouldApplyFullCPUProtection()) correctNominalStateIfNeeded();
return;
}
%orig(arg1, arg2);
}

%end

// ============================================================================
// ObjC 类钩子（第2层: ThermalManager 决策层）
//
// 冲突避免说明:
//   - 温度 getter 的单位与返回 ABI 尚未完整确认，全部保持原生；解除温控在已核验的
//     decision tree、SupervisorControl、ComponentControl 与 MitigationController 下游收敛。
//   - thermalSensorValuesMaxFromIndexSet: 与 copyDieTempSensorIndexSetForFourthChar:sensors:
//     返回值 ABI 在版本间存在 float/int 差异，不安装猜测式 hook。
//   - putDeviceInThermalSimulationMode: 不 hook (CPUthermal 自已调用会递归)
//   - setCPMSMitigationState: 直接在决策层拦截，避免进入 CPMS 写路径
//   - setServiceProperty:key:value:scaleToFixedPoint: 仅丢弃热相关键，普通属性照常写入
// ============================================================================

// ThermalManager 只接管已核实属于它的配置与调度入口。
%hook ThermalManager

- (id)getConfigurationFor:(NSString *)key {
id config = %orig(key);
if (!thermalDimmingPreventionEnabled()) return config;
@try { return patchThermalPlist(config); }
@catch (__unused NSException *exception) { return config; }
}

- (void)hintComponentControlTakeAction {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (void)probeAllSupervisorControlLoadingIndex {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (BOOL)getPotentialForcedThermalPressureLevel {
if (shouldForceNominalThermalPressure()) return NO;
return %orig;
}

%end

// 判断服务属性键是否属于热管理通道；只有热相关键才在解除温控下被丢弃，其余照常写入。
static BOOL CPUthermalIsThermalServiceKey(NSString *key) {
if (![key isKindOfClass:[NSString class]]) return NO;
NSString *k = [key lowercaseString];
for (NSString *token in @[@"thermal", @"temperature", @"die", @"skin", @"pressure", @"throttle", @"mitigation", @"cpms", @"hippocket", @"pocket", @"powerzone", @"p-state", @"pstate"]) {
if ([k containsString:token]) return YES;
}
return NO;
}

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
if (shouldApplyLowPowerLimit()) return YES;
return %orig;
}

- (void)setPowerSaveToken:(int)token {
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
// 高频更新只追踪实例并执行原逻辑；各 ceiling/floor setter hook 已逐次校正目标，
// 不再在每次 update 后额外批量写 24 个预算，减少 thermalmonitord 锁竞争。
trackPowerController(self);
%orig;
}

- (void)updatePackage {
trackPowerController(self);
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
// 解除温控模式维持 100% 性能下限，覆盖切档前残留的低功耗 floor。
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

// ---------------------------------------------------------------------------
// isolation.49 — MitigationController 上真实存在、此前没有 hook 的 GPU/Package 上限
//
// 旧版只有 CPU 的 ceiling/floor 有 hook，GPU 与 Package 的 ceiling 完全没拦：
// thermalmonitord 每个 tick 走 updateGPU/updatePackage 时会把热档算出来的
// GPU/Package 功率上限重新写下去，于是“解除温控”只在切档那一瞬间生效，
// 一两秒后 GPU 又被压回热缓解档 —— 这就是持续掉频卡顿的来源。
// GPU/Package floor 使用已核实的 v24@0:8i16i20 ABI。
// ---------------------------------------------------------------------------

- (void)setGPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) { %orig(ceiling, source); return; }
if (shouldApplyLowPowerLimit()) { %orig(ceiling, source); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPerformancePercent, source); return; }
%orig(ceiling, source);
}

- (void)setGPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) { %orig(floor, source); return; }
if (shouldApplyLowPowerLimit()) { %orig(floor, source); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPerformancePercent, source); return; }
%orig(floor, source);
}

- (void)setPackagePowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) { %orig(ceiling, source); return; }
if (shouldApplyLowPowerLimit()) { %orig(ceiling, source); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPerformancePercent, source); return; }
%orig(ceiling, source);
}

- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
if (g_restoringFullPower) { %orig(floor, source); return; }
if (shouldApplyLowPowerLimit()) { %orig(floor, source); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPerformancePercent, source); return; }
%orig(floor, source);
}

- (void)setGPUPowerZoneTarget:(int)target {
if (g_restoringFullPower || shouldApplyLowPowerLimit()) { %orig(target); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPerformancePercent); return; }
%orig(target);
}

- (void)setSGXLevel:(int)level {
if (g_restoringFullPower || shouldApplyLowPowerLimit()) { %orig(level); return; }
if (shouldApplyFullCPUProtection()) { %orig(0); return; }
%orig(level);
}

// Package/Graphics 的绝对功率上限（mW）：解除温控时放开到不限制值。
- (void)setMaxPackagePower:(int)power {
if (g_restoringFullPower || shouldApplyLowPowerLimit()) { %orig(power); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW); return; }
%orig(power);
}

- (void)setMaxGraphicsDrivePowerTarget:(int)target {
if (g_restoringFullPower || shouldApplyLowPowerLimit()) { %orig(target); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW); return; }
%orig(target);
}

// 真实 encoding：v28@0:8 i16 Q20 —— details 是 64 位整数，不是对象指针。
- (void)setPackagePowerBudgetDirect:(int)budget withDetails:(unsigned long long)details {
if (g_restoringFullPower || shouldApplyLowPowerLimit()) { %orig(budget, details); return; }
if (shouldApplyFullCPUProtection()) { %orig(kUnrestrictedPowerLimitMW, details); return; }
%orig(budget, details);
}

// 内核 IOKit 属性写入。真实实现在 MitigationController（i36@0:8 I16 ^{__CFString=}20 i28 B32）；
// 旧版挂在 CommonProduct / ThermalControl / ComponentControl 上，这三个类都没有这个
// selector，钩子一律空转，热相关的 throttle 键照样被写进内核。
- (int)setServiceProperty:(unsigned int)service key:(id)key value:(int)value scaleToFixedPoint:(BOOL)scale {
if (shouldApplyFullCPUProtection() && CPUthermalIsThermalServiceKey(CPUthermalKeyDescription(key))) {
return 0;
}
if (thermalDimmingPreventionEnabled()) {
NSString *keyString = CPUthermalKeyDescription(key);
if (CPUthermalKeyIsBacklightCap(keyString)) {
int raised = CPUthermalRaiseBacklightCapValue(keyString, value);
if (raised != value) {
os_log(CPUthermalRuntimeLog(), "service backlight cap raised key=%{public}s %d -> %d", keyString.UTF8String ?: "?", value, raised);
return %orig(service, key, raised, scale);
}
}
}
return %orig(service, key, value, scale);
}

// 真实 encoding：v32@0:8 ^{__CFString=}16 i24 B28 —— 第一个参数是 CFString 属性名。
- (void)setDieTempControllerProperty:(id)property level:(int)level scaleToFixedPoint:(BOOL)scale {
if (shouldApplyFullCPUProtection() && CPUthermalIsThermalServiceKey(CPUthermalKeyDescription(property))) return;
%orig(property, level, scale);
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
    // getConfigurationFor: 可能直接返回 backlightComponentControl 子字典。
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
runtimeConfigSnapshot(&enabled, NULL, NULL, NULL);
if (enabled) applyPowerModeToRuntime(NO);
else if (wasEnabled) restoreNativeRuntimeAfterDisable();
// 设置仅应用运行时状态，不自动终止 thermalmonitord。

};
dispatch_async(CPUthermalEngineQueue(), block);
}

// ============================================================================
// 真实类名补充 — iOS 16 thermalmonitord 热压链（按 0xash DeviceMonitor 引擎
// 解出的类名表：LifetimeServoController / ArcController / CommonProduct /
// MitigationController / PackagePowerCC / TableDrivenDecisionTree /
// NotificationManager / SupervisorControl / ComponentControl / XPidComponent）
// 处理器名不同版本存在差异，这里对真实类名再挂一层，双保险。
// ============================================================================
// isolation.49：以下声明全部按 tools/objcdump.py 对 /rootfs/usr/libexec/thermalmonitord
// 的离线核对结果书写，encoding 逐条注明；不再照抄其它插件的猜测。
@interface NotificationManager : NSObject
// v24@0:8Q16
- (void)updateThermalNotification:(unsigned long long)notification;
// q28@0:8Q16B24 —— 返回热压力等级（long long），旧版声明成 void 会让调用方读到 x0 残值
- (long long)updateThermalPressureLevelNotification:(unsigned long long)notification shouldForceThermalPressure:(BOOL)force;
// v24@0:8Q16
- (void)setThermalPressureLevelNotification:(unsigned long long)notification;
// v20@0:8C16
- (void)updateThermalMitigationNotification:(unsigned char)notification;
// v24@0:8C16C20
- (void)updatetimeToMitigateNotification:(unsigned char)notification AndReasonCode:(unsigned char)reasonCode;
@end

@interface SupervisorControl : NSObject
// v24@0:8f16f20 —— 返回 void、两个 float；旧声明的 double 返回 + uintptr_t 参数完全不符，
// 所以运行时 ABI 安装器的 f/d 条目在本机一条都装不上。这里不再挂它，
// 改为直接接管下面这几个真正决定“允许缓解多少”的入口。
- (void)calculateControlEffort:(float)effort trigger:(float)trigger;
// C20@0:8i16
- (unsigned char)maxLIForComponent:(int)component;
// C24@0:8i16i20
- (unsigned char)releaseMaxLIForComponent:(int)component releaseRate:(int)releaseRate;
// B20@0:8i16
- (BOOL)shouldForceThermalLevelForThreshold:(int)threshold;
// B16@0:8
- (BOOL)shouldEnforceLightThermalPressure;
@end

@interface ComponentControl : NSObject
// v24@0:8^{__CFDictionary=}16
- (void)updatePowerParameters:(id)params;
// v24@0:8I16I20
- (void)setMaxLoadingIndex:(unsigned int)maxIndex releaseIndex:(unsigned int)releaseIndex;
// v20@0:8I16 / I16@0:8
- (void)setMaxLoadingIndex:(unsigned int)maxIndex;
- (unsigned int)maxLoadingIndex;
// B16@0:8
- (BOOL)shouldDoCPMSActions;
- (void)setCPMSMitigationState:(BOOL)state;
- (void)defaultAction;
- (void)defaultCPMSAction;
- (void)resetCPMSMitigationState;
@end

// 热暗屏的唯一执行者：brightnessLevels 表 + _maxLICeiling 决定背光档位，
// 最后由 setBrightnessKey:value: 写进 BrightnessSystemClient。
@interface BackLightCC : NSObject
// v28@0:8@16i24
- (void)setBrightnessKey:(id)key value:(int)value;
// B16@0:8
- (BOOL)shouldSuppressMitigations;
// v20@0:8i16
- (void)setMaxLICeiling:(int)ceiling;
- (void)setMaxLICeilingSoft:(int)ceiling;
// v24@0:8^{__CFArray=}16
- (void)initBrightnessTable:(id)table;
- (void)defaultAction;
- (void)defaultCPMSAction;
@end

// 把缓解数组下发给内核 CPMS 的最后一站。
@interface CPMSHelper : NSObject
- (void)publishDetailedMitigationArrayToCPMS;
// v24@0:8I16i20
- (void)addToCPMSMitigationArray:(unsigned int)mitigation forComponent:(int)component;
// v32@0:8I16Q20i28
- (void)addToCPMSMitigationArray:(unsigned int)mitigation withDetails:(unsigned long long)details forComponent:(int)component;
@end

// 真实 owner 上直接安装已核实 ABI 的 hook。
%hook TableDrivenDecisionTree

- (void)evaluateDecisionTree {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (void)actionComponentControl {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (int)getReleaseRateForComponent:(int)component {
if (shouldApplyFullCPUProtection()) return 0;
return %orig(component);
}

%end

%hook NotificationManager

// 强制 Nominal 时明确返回 0（= 无热压力）。旧版返回 void，调用方拿到的是 x0 残值。
- (long long)updateThermalPressureLevelNotification:(unsigned long long)notification shouldForceThermalPressure:(BOOL)force {
if (shouldForceNominalThermalPressure()) return 0;
return %orig(notification, force);
}

- (void)updateThermalNotification:(unsigned long long)notification {
if (shouldForceNominalThermalPressure()) return;
%orig(notification);
}

- (void)setThermalPressureLevelNotification:(unsigned long long)notification {
if (shouldForceNominalThermalPressure()) { %orig(0); return; }
%orig(notification);
}

- (void)updateThermalMitigationNotification:(unsigned char)notification {
if (shouldForceNominalThermalPressure()) return;
%orig(notification);
}

- (void)updatetimeToMitigateNotification:(unsigned char)notification AndReasonCode:(unsigned char)reasonCode {
if (shouldForceNominalThermalPressure()) return;
%orig(notification, reasonCode);
}

%end

%hook SupervisorControl

- (void)calculateControlEffort:(float)effort trigger:(float)trigger {
if (shouldApplyFullCPUProtection()) { %orig(0.0f, 0.0f); return; }
%orig(effort, trigger);
}

// 每个组件“最多允许缓解到第几档”：解除温控下一律 0（= 不缓解）。
- (unsigned char)maxLIForComponent:(int)component {
if (shouldApplyFullCPUProtection()) return 0;
return %orig(component);
}

- (unsigned char)releaseMaxLIForComponent:(int)component releaseRate:(int)releaseRate {
if (shouldApplyFullCPUProtection()) return 0;
return %orig(component, releaseRate);
}

- (BOOL)shouldForceThermalLevelForThreshold:(int)threshold {
if (shouldForceNominalThermalPressure()) return NO;
return %orig(threshold);
}

- (BOOL)shouldEnforceLightThermalPressure {
if (shouldForceNominalThermalPressure()) return NO;
return %orig;
}

%end

%hook ComponentControl

// isolation.41 崩溃修复的语义保留：解除温控下不重写原生参数。
// isolation.49：参数真实类型是 CFDictionary，不是 uintptr_t。
- (void)updatePowerParameters:(id)params {
if (shouldApplyFullCPUProtection()) return;
%orig(params);
}

// 组件允许的最大缓解档位（Loading Index）——CPU/GPU/背光共用的总闸，0 = 无缓解。
- (void)setMaxLoadingIndex:(unsigned int)maxIndex releaseIndex:(unsigned int)releaseIndex {
if (shouldApplyFullCPUProtection()) { %orig(0, 0); return; }
%orig(maxIndex, releaseIndex);
}

- (void)setMaxLoadingIndex:(unsigned int)maxIndex {
if (shouldApplyFullCPUProtection()) { %orig(0); return; }
%orig(maxIndex);
}

- (unsigned int)maxLoadingIndex {
if (shouldApplyFullCPUProtection()) return 0;
return %orig;
}

// CPMS（内核功率缓解）动作：解除温控下不执行。
- (BOOL)shouldDoCPMSActions {
if (shouldApplyFullCPUProtection()) return NO;
return %orig;
}

- (void)setCPMSMitigationState:(BOOL)state {
if (shouldApplyFullCPUProtection()) { %orig(NO); return; }
%orig(state);
}

// isolation.49：updatePackage / setPackageLowPowerTarget / setServiceProperty:... 已从
// ComponentControl 移除 —— 离线核对确认这三个 selector 属于 MitigationController，
// ComponentControl 根本没有，旧钩子只是往不存在的 selector 上注册了空实现.

%end

// ============================================================================
// isolation.49 — BackLightCC：热暗屏真正的执行者
//
// 旧版一个 BackLightCC 的 hook 都没有：所有“防暗屏”都停留在改配置 plist 和
// 拦 IOKit 键上，而 thermalmonitord 在 iOS 16 上是走
//   SupervisorControl 决策 -> ComponentControl/BackLightCC 的 LI 上限
//   -> brightnessLevels 表查档 -> setBrightnessKey:value: 写 BrightnessSystemClient
// 这条链，配置改得再干净也拦不住运行时的降档。这里把这条链的三个关节全部接管。
// ============================================================================
%hook BackLightCC

// LI 上限：0 = 不允许任何缓解档，与 SupervisorControl/ComponentControl 的已核验路径一致。
- (void)setMaxLICeiling:(int)ceiling {
if (thermalDimmingPreventionEnabled()) { %orig(0); return; }
%orig(ceiling);
}

- (void)setMaxLICeilingSoft:(int)ceiling {
if (thermalDimmingPreventionEnabled()) { %orig(0); return; }
%orig(ceiling);
}

// 原生自带的“是否抑制缓解”判断，直接接管。
- (BOOL)shouldSuppressMitigations {
if (thermalDimmingPreventionEnabled()) return YES;
return %orig;
}

// 最终落地的那一次写入。只升不降：cap 类键低于同键已见过的最大值时抬回去；
// value<=0（关机/关闭指令）与非 cap 键一律原样放行，绝不自己造更大的数。
- (void)setBrightnessKey:(id)key value:(int)value {
if (!thermalDimmingPreventionEnabled()) { %orig(key, value); return; }
NSString *keyString = CPUthermalKeyDescription(key);
if (!CPUthermalKeyIsBacklightCap(keyString)) { %orig(key, value); return; }
int raised = CPUthermalRaiseBacklightCapValue(keyString, value);
if (raised == value) { %orig(key, value); return; }
os_log(CPUthermalRuntimeLog(), "backlight cap raised key=%{public}s %d -> %d", keyString.UTF8String ?: "?", value, raised);
%orig(key, raised);
}

%end

// 缓解数组下发内核前的最后一站：解除温控下不组装、不下发。
%hook CPMSHelper

- (void)publishDetailedMitigationArrayToCPMS {
if (shouldApplyFullCPUProtection()) return;
%orig;
}

- (void)addToCPMSMitigationArray:(unsigned int)mitigation forComponent:(int)component {
if (shouldApplyFullCPUProtection()) return;
%orig(mitigation, component);
}

- (void)addToCPMSMitigationArray:(unsigned int)mitigation withDetails:(unsigned long long)details forComponent:(int)component {
if (shouldApplyFullCPUProtection()) return;
%orig(mitigation, details, component);
}

%end

// ============================================================================
// %ctor — 构造函数（配置仅在进程启动时加载一次）
// ============================================================================
%ctor {
@autoreleasepool {
// Legacy thermal probe hooks are intentionally absent.

cleanupRemovedFeaturePrefs();
// isolation.15：启动时修复偏好文件属主/权限（best-effort）——模块以 root 写入后属主会变成
// root:wheel，导致设置面板（mobile）读不到、进而以空字典覆盖抹掉其它键；这里补一次修复。
CPUthermalFixPrefOwnership(CPUthermalCurrentPrefPath());
loadPrefs();
os_log(CPUthermalRuntimeLog(), "ApelinLoaded %{public}s CPUthermal isolation.49 mode=%{public}s", APELIN_BUILD_ID, isLowPowerMode() ? "lowPower" : "fullPower");

// 确保 IOKit 已加载
void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
if (iokit) {
kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) = (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))dlsym(iokit, "IOServiceSetProperty");
if (ptr) {
MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
}
}

// 两种运行模式均保持 Nominal 热压力；CPU 低功耗由独立 PPM/CLPC 限制实现。
CPUthermalForceNominalPressure();




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

registerThermalLevelResetObservers();
registerScreenWakeObservers();
applyCurrentPowerModeToRuntime();

}
}
