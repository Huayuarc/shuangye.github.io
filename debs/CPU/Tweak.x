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
- (void)updateThermalNotification:(id)notification;
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
// 热路径优化：小写关键字缓存一次，避免每次 IOServiceSetProperty 调用都重复分配 NSString
static BOOL isNetworkThrottleProperty(CFStringRef keyRef) {
    if (!keyRef || !g_enabled || !g_blockNetworkThermalThrottle) return NO;
    NSString *key = (__bridge NSString *)keyRef;
    NSString *lowerKey = [key lowercaseString];

    static NSArray<NSString *> *lowerThrottleKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *keys = [NSMutableArray array];
        for (int i = 0; networkThrottleKeys[i]; i++) {
            [keys addObject:[[NSString stringWithUTF8String:networkThrottleKeys[i]] lowercaseString]];
        }
        lowerThrottleKeys = [keys copy];
    });

    for (NSString *k in lowerThrottleKeys) {
        if ([lowerKey containsString:k]) {
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

// 低功耗模式 CPU 频率锁定值（MHz）— 通过 loadPrefs() 从偏好读取，可跨设备配置
static int64_t g_lowPowerMinMHz = 600;
static int64_t g_lowPowerMaxMHz = 1380;

// 满血模式 CPU 最大频率（MHz）— 0 = 未配置（满血锁频跳过）
static int g_fullPowerMaxMHz = 0;

// 满血模式功率目标下限（mW）：65W（原依赖外部常量，改为本地定义）
#define kUnrestrictedPowerLimitMW 65000

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static BOOL g_restoringFullPower = NO;
static BOOL g_applyingLowPower = NO;
static NSMutableDictionary *g_originalControllerValues = nil;
static BOOL g_fullPowerRecoveryPulseScheduled = NO;
static BOOL g_lowPowerApplyPulseScheduled = NO;
static BOOL g_wakeRuntimeApplyScheduled = NO;

// 持久性低功耗保持定时器
static dispatch_source_t g_lowPowerKeepAliveTimer = NULL;
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护g_powerMode
// 线程安全：保护跨线程共享的可变集合（g_mitigationControllers / g_originalControllerValues / g_applePPMInstances）。
// thermalmonitord 工作线程的 hook 会写这些集合，主队列保活定时器会读/枚举它们，
// NSHashTable/NSMutableDictionary 非线程安全，并发读写会导致 EXC_BAD_ACCESS(SIGSEGV)。
static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static const double kLowPowerKeepAliveInterval = 0.3;  // 每0.3s秒重应用一次，缩短周期防止频率漂移
static NSHashTable *g_applePPMInstances = nil;           // 追踪 ApplePPMCPU 实例（弱引用，防止僵尸实例泄漏）

// 满血模式保活定时器 — 每 1.0 秒重应用一次，防止系统温控恢复
static dispatch_source_t g_fullPowerKeepAliveTimer = NULL;
static const double kFullPowerKeepAliveInterval = 1.0;

// 温度计警告 & 防暗屏（由设置面板控制）
static BOOL g_thermalBlockNotifPopup = YES;
static BOOL g_thermalPreventDimmingEnabled = YES;

static BOOL shouldApplyLowPowerLimit(void);
static int lowPowerTargetValue(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(void);
static void scheduleLowPowerApplyPulse(void);
static void runLowPowerApplyPulse(int remainingPulses);
static void scheduleFullPowerRecoveryPulse(void);
static void runFullPowerRecoveryPulse(int remainingPulses);
static void scheduleWakeRuntimeApply(void);
static void runWakeRuntimeApplyPulse(int remainingPulses);
static void startLowPowerKeepAliveTimer(void);
static void stopLowPowerKeepAliveTimer(void);
static void setKeepAliveInterval(double interval);
static void applyLowPowerToApplePPMCPU(void);
static void startFullPowerKeepAliveTimer(void);
static void stopFullPowerKeepAliveTimer(void);
// 前向声明：满血 IORegistry 写入使用，实体定义在下方 IOKit 钩子区
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef);

static NSString *controllerKey(id controller, const char *name) {
return [NSString stringWithFormat:S("%p:%s"), controller, name];
}

static void rememberOriginalIntValue(id controller, const char *name, int value) {
if (!controller || g_restoringFullPower || !shouldApplyLowPowerLimit()) return;
if (value <= lowPowerTargetValue()) return;
os_unfair_lock_lock(&g_stateLock);
if (!g_originalControllerValues) g_originalControllerValues = [NSMutableDictionary dictionary];
NSString *key = controllerKey(controller, name);
if (!key || [g_originalControllerValues objectForKey:key]) {
os_unfair_lock_unlock(&g_stateLock);
return;
}
[g_originalControllerValues setObject:[NSNumber numberWithInt:value] forKey:key];
os_unfair_lock_unlock(&g_stateLock);
}

static int rememberedOriginalIntValue(id controller, const char *name, int fallback) {
os_unfair_lock_lock(&g_stateLock);
NSNumber *value = [g_originalControllerValues objectForKey:controllerKey(controller, name)];
os_unfair_lock_unlock(&g_stateLock);
return value ? [value intValue] : fallback;
}

// 节流版强制热压力 Nominal：限制 notify 风暴。
// tryTakeAction/决策树每轮热循环都会调用 CPUthermalForceNominalCombined（内部 notify_post 系统热通知），
// 过量通知会重入 thermalmonitord 并饿死主线程（曾出现 unresponsive com.apple.main-thread）。
// 满血模式每秒至多一次即可维持压力 Nominal，不影响频率锁定（频率由 setCPULevel/功率目标/IORegistry 写入保证）。
static void CPUthermalForceNominalThrottled(void) {
static CFAbsoluteTime lastPost = 0;
CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
if (lastPost != 0 && (now - lastPost) < 1.0) return;
lastPost = now;
CPUthermalForceNominalCombined();
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
return g_enabled && g_cpuProtection && isFullPowerMode();
}

static BOOL shouldApplyLowPowerLimit(void) {
return g_enabled && g_cpuProtection && isLowPowerMode();
}

static int lowPowerTargetValue(void) {
return (int)g_lowPowerMaxMHz;
}

static int fullPowerFrequencyValue(void) {
// 仅使用偏好自定义值；未配置（<=0）时满血锁频跳过
if (g_fullPowerMaxMHz > 0) return g_fullPowerMaxMHz;
NSLog(@"[CPUthermal] 警告: 未配置 fullPowerMaxMHz，满血锁频将跳过");
return 0;
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
os_unfair_lock_lock(&g_stateLock);
if (!g_mitigationControllers) g_mitigationControllers = [NSHashTable weakObjectsHashTable];
[g_mitigationControllers addObject:controller];
os_unfair_lock_unlock(&g_stateLock);
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

// 满血功率目标：
// 取「历史记录的最大功率目标」与 65W 的较大值，绝不返回低于 65W 的目标。
static int fullPowerTargetForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "MaxCPUPowerTarget", 0);
if (remembered > lowPowerTargetValue()) return MAX(remembered, kUnrestrictedPowerLimitMW);

int maxPower = intIvarValue(controller, "_maxCPUPower", 0);
if (maxPower > lowPowerTargetValue()) return MAX(maxPower, kUnrestrictedPowerLimitMW);

int realTarget = intIvarValue(controller, "_currentRealCPUPowerTarget", 0);
if (realTarget > lowPowerTargetValue()) return MAX(realTarget, kUnrestrictedPowerLimitMW);

return kUnrestrictedPowerLimitMW;
}

static int fullPowerCeilingForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "CPUPowerCeiling", 0);
return MAX(remembered, kUnrestrictedPowerLimitMW);
}

// 满血功率下限 — 关键修复：原实现返回 0 / 历史值，系统仍可随时把功率压到该值以下导致降频。
// 满血 floor 抬到 65W，热管理想降频也被 floor 顶住。
static int fullPowerFloorForController(id controller) {
return kUnrestrictedPowerLimitMW;
}

static int fullPowerZoneTargetForController(id controller) {
int remembered = rememberedOriginalIntValue(controller, "CPUPowerZoneTarget", 0);
return MAX(remembered, kUnrestrictedPowerLimitMW);
}

// 仅设置低功耗钳制 setter，不触发 updateCPU/updatePackage。
// 供保活定时器与 updateCPU/updatePackage 钩子复用，避免递归。
// 核心 = setPowerSaveActive:YES + setCPULevel:2 + updateCPU。
// 关键修复：原先把 MHz 频率值（如 1380）传给 mW 功率 setter（setCPULowPowerTarget:/
// setMaxCPUPowerTarget:/setCPUPowerCeiling:/setCPUPowerZoneTarget:）属单位不匹配，
// 数值异常会被系统忽略/钳制，这正是「低功耗频率无法锁定」的根因之一。
// 现在低功耗不再往功率 setter 塞频率值，改由 CPULevel:2 档位直接锁频。
static void forceLowPowerSettersOnController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 1);
}
// CPULevel:2 = 低功耗性能档（比原 1 更受限），这是锁频的核心手段
if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), 2);
}
// 通知包域进入低功耗预算（系统原语义，保持原有调用）
if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
}
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
NSLog(@"[CPUthermal] 已主动下发低功耗 CPU 限制: %lld-%lldMHz controller:%@", g_lowPowerMinMHz, g_lowPowerMaxMHz, controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 下发低功耗 CPU 限制失败: %@", exception);
} @finally {
g_applyingLowPower = NO;
}
}

static void applyLowPowerLimitsToTrackedControllers(void) {
if (!shouldApplyLowPowerLimit()) return;
@autoreleasepool {
// 只在锁内取快照，循环在锁外执行，避免 objc_msgSend 回调 hook 时重入死锁
NSArray *controllers;
os_unfair_lock_lock(&g_stateLock);
controllers = [g_mitigationControllers allObjects];
os_unfair_lock_unlock(&g_stateLock);
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
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), kUnrestrictedPowerLimitMW);
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
// 满血路径：GPU / Package 功率 setter 也抬到 65W，
// 防止 GPU/包域热管理压低功率后间接拖累 CPU 频率（「高频率可能降频」的次要路径）
if ([controller respondsToSelector:@selector(setGPUPowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW, 0);
}
if ([controller respondsToSelector:@selector(setGPUPowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setGPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW, 0);
}
if ([controller respondsToSelector:@selector(setGPUPowerZoneTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setGPUPowerZoneTarget:), kUnrestrictedPowerLimitMW);
}
if ([controller respondsToSelector:@selector(setMaxGraphicsDrivePowerTarget:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setMaxGraphicsDrivePowerTarget:), kUnrestrictedPowerLimitMW);
}
if ([controller respondsToSelector:@selector(setMaxPackagePower:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setMaxPackagePower:), kUnrestrictedPowerLimitMW);
}
if ([controller respondsToSelector:@selector(setPackagePowerCeiling:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setPackagePowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW, 0);
}
if ([controller respondsToSelector:@selector(setPackagePowerFloor:fromDecisionSource:)]) {
((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(controller, @selector(setPackagePowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW, 0);
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
// 只在锁内取快照/清空，循环在锁外执行，避免 objc_msgSend 回调 hook 时重入死锁
NSArray *controllers;
os_unfair_lock_lock(&g_stateLock);
controllers = [g_mitigationControllers allObjects];
os_unfair_lock_unlock(&g_stateLock);
for (id controller in controllers) {
restoreFullPowerToController(controller);
}
os_unfair_lock_lock(&g_stateLock);
[g_originalControllerValues removeAllObjects];
os_unfair_lock_unlock(&g_stateLock);
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
// 满血 ceiling/floor 全部抬到 65W（原 ceiling=0 含义是「0 mW 上限」，
// 语义错误且被系统忽略/钳制；floor 未抬升则系统可随时降频）。
setCommonProductCeiling(@selector(setCPUPowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW);
setCommonProductCeiling(@selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW);
setCommonProductCeiling(@selector(setGPUPowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW);
setCommonProductCeiling(@selector(setGPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW);
setCommonProductCeiling(@selector(setPackagePowerCeiling:fromDecisionSource:), kUnrestrictedPowerLimitMW);
setCommonProductCeiling(@selector(setPackagePowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW);
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
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), 2);  // 低功耗档位 2（原 1 约束不足，锁不住频）
}
// 低功耗不再往 mW 功率 setter 写 40（单位不匹配、数值异常会被系统忽略），
// 由 setCPULevel:2 + setPowerSaveActive:YES 决定低功耗功率预算。
// 强制系统热压力为 Nominal 并重置热通知级别（与解除温控模式一致）
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 已主动套用低功耗 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用低功耗 CommonProduct 状态失败: %@", exception);
}
}

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime();
}

static void applyPowerModeToRuntime(void) {
if (!g_enabled || !g_cpuProtection) return;
if (isLowPowerMode()) {
stopFullPowerKeepAliveTimer();  // 退出满血时停止定时器
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyLowPowerToApplePPMCPU();  // 修复：初始应用也强制 ApplePPMCPU
scheduleLowPowerApplyPulse();
startLowPowerKeepAliveTimer();  // 启动持久保持定时器
return;
}
if (isFullPowerMode()) {
stopLowPowerKeepAliveTimer();  // 退出低功耗时停止定时器
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
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
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyLowPowerToApplePPMCPU();  // 修复：脉冲中也强制
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
// 30s 连续高频重套用会饿死 thermalmonitord 主线程（曾触发 watchdog），
// 5s 覆盖已足够 —— 1s 保活定时器在唤醒后持续兜底重应用。
dispatch_async(dispatch_get_main_queue(), ^{
runWakeRuntimeApplyPulse(50);
});
}

static void runWakeRuntimeApplyPulse(int remainingPulses) {
if (remainingPulses <= 0 || !g_enabled || !g_cpuProtection) {
g_wakeRuntimeApplyScheduled = NO;
return;
}
loadPrefs();
applyPowerModeToRuntime();
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
// 持久性低功耗保持定时器 — 每 0.3 秒重应用一次，防止决策树漂移和新控制器覆盖
//
// 修复：加入 ApplePPMCPU 实例强制重应用 + 消除定时器重建竞态
// ============================================================================
static void applyLowPowerToApplePPMCPU(void) {
if (!shouldApplyLowPowerLimit() || !g_applePPMInstances) return;
// 锁内取快照，循环在锁外执行，避免 objc_msgSend 回调 hook 时重入死锁
NSArray *ppms;
os_unfair_lock_lock(&g_stateLock);
ppms = [g_applePPMInstances allObjects];
os_unfair_lock_unlock(&g_stateLock);
for (id ppm in ppms) {
if (!ppm) continue;
if ([ppm respondsToSelector:@selector(setCPULevel:)]) {
// 低功耗：传 2（更受限档），激活低功耗调度，避免 0 跑满血
((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), 2);
}
if ([ppm respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(ppm, @selector(updateCPU));
}
}
}

// ============================================================================
// 低功耗 IORegistry 参数写入 — "无脑写" 强化锁频
//
// 每几个 keep-alive 周期（≈3 秒）把低功耗频率/功率目标直接写进功率服务，
// 即使 thermalmonitord 内部的 setCPULevel:2 下发通道被系统覆盖，
// 内核侧也能从 IORegistry 持续读到低功耗上限。
// 跨设备按类名匹配（见 CPUthermalPaths.h），属性写失败忽略（防御式）。
// ============================================================================
static int lowPowerPowerBudgetMW(void) {
    // 用频率立方比缩放 65W 满功率预算，近似得到目标频率可维持的功率包络
    // 满血最高频率未知时返回 0，调用方跳过功率预算写入（不猜测，防止锁错）
    int full = fullPowerFrequencyValue();
    if (full <= 0) return 0;
    double ratio = (double)g_lowPowerMaxMHz / (double)full;
    double budget = kUnrestrictedPowerLimitMW * ratio * ratio * ratio;
    return (int)MAX(budget, 1000.0);
}

static void writeLowPowerIORegistryParams(void) {
    if (!shouldApplyLowPowerLimit()) return;

    // 防刷机制：至少间隔 3 秒才写一次 IORegistry，降低锁屏下的 IOKit 负载。
    // 改用绝对时间而非周期计数——锁屏/亮屏会动态改变保活定时器周期，周期计数会失真
    static CFAbsoluteTime lastWrite = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastWrite != 0 && (now - lastWrite) < 3.0) return;
    lastWrite = now;

    int freq = (int)g_lowPowerMaxMHz;
    int powerMW = lowPowerPowerBudgetMW();

    // 满血最高频率未知时功率预算为 0：仅写频率上限，不写功率预算，避免误导内核
    CFNumberRef freqNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &freq);
    CFNumberRef powerNum = (powerMW > 0) ? CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &powerMW) : NULL;
    if (!freqNum) return;

    CFStringRef freqKey = CFSTR("MaxOperatingFrequency");
    CFStringRef cpuLPKey = CFSTR("CPULowPowerTarget");
    CFStringRef pkgLPKey = CFSTR("PackageLowPowerTarget");
    CFStringRef cpuMaxKey = CFSTR("CPUMaxPower");

    for (int i = 0; kCPUthermalLowPowerServiceClasses[i]; i++) {
        io_iterator_t iter = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
            IOServiceMatching(kCPUthermalLowPowerServiceClasses[i]), &iter);
        if (kr != KERN_SUCCESS || !iter) continue;

        io_service_t service;
        while ((service = IOIteratorNext(iter))) {
            if (!service) continue;
            IORegistryEntrySetCFProperty(service, freqKey, freqNum);
            if (powerNum) {
                IORegistryEntrySetCFProperty(service, cpuLPKey, powerNum);
                IORegistryEntrySetCFProperty(service, pkgLPKey, powerNum);
                IORegistryEntrySetCFProperty(service, cpuMaxKey, powerNum);
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    }

    CFRelease(freqNum);
    if (powerNum) CFRelease(powerNum);

    NSLog(@"[CPUthermal] IORegistry 低功耗参数写入: 频率上限=%dMHz 功率预算=%dmW", freq, powerMW);
}

// ============================================================================
// 满血模式 IORegistry 参数写入 — "暴力"拉升频率地板，强制锁频
//
// 与低功耗逻辑保持一致，每 3 个 keep-alive 周期写一次（≈每 3 秒），避免内核通信过载。
// 关键：必须调用 orig_IOServiceSetProperty，不能用 IORegistryEntrySetCFProperty，
// 否则会被本文件的 hooked_IOServiceSetProperty 吞掉！
// ============================================================================
static void writeFullPowerIORegistryParams(void) {
    if (!shouldApplyFullCPUProtection()) return;

    static int writeCounter = 0;
    if (++writeCounter < 2) return;
    writeCounter = 0;

    // 获取设备最高频率（机型查表优先，回退运行时 IORegistry 检测）
    int maxFreq = fullPowerFrequencyValue();
    if (maxFreq <= 0) {
        // 无法确定设备最高频率时不做锁频，防止把频率锁到超过设备真实上限
        NSLog(@"[CPUthermal] 满血锁频跳过: 未能确定设备最高频率");
        return;
    }

    CFNumberRef freqNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &maxFreq);
    if (!freqNum) return;

    // 核心 Key：同时锁定最低频率和最高频率
    CFStringRef minFreqKey = CFSTR("MinOperatingFrequency");
    CFStringRef maxFreqKey = CFSTR("MaxOperatingFrequency");
    // 同时拉满底层功率预算下限
    CFStringRef minPowerKey = CFSTR("CPUMinPower");

    int maxPowerMW = kUnrestrictedPowerLimitMW; // 65W
    CFNumberRef powerNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &maxPowerMW);

    for (int i = 0; kCPUthermalLowPowerServiceClasses[i]; i++) {
        io_iterator_t iter = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
            IOServiceMatching(kCPUthermalLowPowerServiceClasses[i]), &iter);
        if (kr != KERN_SUCCESS || !iter) continue;

        io_service_t service;
        while ((service = IOIteratorNext(iter))) {
            if (!service) continue;

            // 关键修复：必须调用 orig_IOServiceSetProperty，不能用 IORegistryEntrySetCFProperty，
            // 否则会被本文件的 hooked_IOServiceSetProperty 吞掉！
            orig_IOServiceSetProperty(service, minFreqKey, freqNum);
            orig_IOServiceSetProperty(service, maxFreqKey, freqNum);

            if (powerNum) {
                orig_IOServiceSetProperty(service, minPowerKey, powerNum);
            }

            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    }

    CFRelease(freqNum);
    if (powerNum) CFRelease(powerNum);

    NSLog(@"[CPUthermal] IORegistry 满血强制锁频已写入: 最低频率=%dMHz", maxFreq);
}

// 动态调整低功耗保活定时器周期：锁屏放缓（省电、降低 IOKit 负载），亮屏恢复高频压制。
// 定时器未运行时静默忽略（低功耗下由 applyPowerModeToRuntime 负责启动）。
static void setKeepAliveInterval(double interval) {
    if (!g_lowPowerKeepAliveTimer) return;
    dispatch_source_set_timer(g_lowPowerKeepAliveTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (int64_t)(interval * NSEC_PER_SEC),
                              0);
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
// 修复：强制所有 ApplePPMCPU 实例 P-State 钳制到受限档（1）
applyLowPowerToApplePPMCPU();
// 强化：每 3 秒"无脑写"一次低功耗 IORegistry 参数（频率上限/功率预算）
// 跨设备按类名匹配功率服务，防止系统/驱动在两轮套用之间把频率提回高位
writeLowPowerIORegistryParams();
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
// 满血模式保活定时器 — 每 1.0 秒重应用一次，防止系统温控恢复
// ============================================================================
static void startFullPowerKeepAliveTimer(void) {
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) {
stopFullPowerKeepAliveTimer();
return;
}

// 修复：如果定时器已经在运行，不要销毁重建
// （唤醒脉冲期间 applyPowerModeToRuntime 会被高频调用，每次销毁重建会造成 GCD 定时器饥饿）
if (g_fullPowerKeepAliveTimer) {
return;
}

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
// 新增：向 IOKit 持续注入满血最低频率锁定指令
writeFullPowerIORegistryParams();
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
if (mhz < g_lowPowerMinMHz) mhz = g_lowPowerMinMHz;
if (mhz > g_lowPowerMaxMHz) mhz = g_lowPowerMaxMHz;
return frequencyValueFromMHz(mhz, value);
}

static CFTypeRef copyLowPowerFrequencyValueForKey(NSString *key, CFTypeRef originalValue) {
if (!keyMatchesLowPowerLimit(key)) return NULL;
NSString *lower = [key lowercaseString];
BOOL isMinKey = [key localizedCaseInsensitiveContainsString:S("min")] ||
[key localizedCaseInsensitiveContainsString:S("floor")];
BOOL isFrequencyKey = [lower containsString:S("freq")] ||
[lower containsString:S("frequency")];

int64_t original = g_lowPowerMaxMHz;
if (originalValue && CFGetTypeID(originalValue) == CFNumberGetTypeID()) {
CFNumberGetValue((CFNumberRef)originalValue, kCFNumberSInt64Type, &original);
} else if (isMinKey && isFrequencyKey) {
original = g_lowPowerMinMHz;
}

int64_t replacement = isMinKey && isFrequencyKey
? frequencyValueFromMHz(g_lowPowerMinMHz, original)
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

int64_t original = originalNumber ? [originalNumber longLongValue] : g_lowPowerMaxMHz;
int64_t replacement = (isMinKey && isFrequencyKey)
? frequencyValueFromMHz(g_lowPowerMinMHz, original)
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

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
if (!d) return;
g_enabled               = YES; // 始终启用，不依赖偏好设置
// g_cpuProtection 始终为 YES（硬编码），不依赖偏好设置
g_thermalBlockNotifPopup     = [d[S("thermalBlockNotifPopup")] ?: [NSNumber numberWithBool:YES] boolValue];
g_thermalPreventDimmingEnabled = [d[S("thermalPreventDimmingEnabled")] ?: [NSNumber numberWithBool:YES] boolValue];

// 从偏好读取频率配置，实现跨设备适配
NSNumber *prefLowMin = d[S("lowPowerMinMHz")];
NSNumber *prefLowMax = d[S("lowPowerMaxMHz")];
NSNumber *prefFullMax = d[S("fullPowerMaxMHz")];
if (prefLowMin) g_lowPowerMinMHz = [prefLowMin longLongValue];
if (prefLowMax) g_lowPowerMaxMHz = [prefLowMax longLongValue];
if (prefFullMax && [prefFullMax intValue] > 0) {
    // 偏好自定义有效频率（>0）优先；未配置时满血锁频跳过
    g_fullPowerMaxMHz = [prefFullMax intValue];
}

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

static BOOL isThermalConnection(io_connect_t conn) {
os_unfair_lock_lock(&g_connLock);
BOOL result = NO;
for (int i = 0; i < g_connCount; i++) {
if (g_conns[i].conn == conn) {
result = g_conns[i].isThermal;
break;
}
}
os_unfair_lock_unlock(&g_connLock);
return result;
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

// --- IOConnectCallMethod — 拦截温度读取 + 降频操作 ---
%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
if (!g_enabled || !isThermalConnection(connection)) {
return %orig;
}

if (g_restoringFullPower) {
return %orig;
}

// 仅满血模式: 阻止温控降频指令（低功耗模式放行，让 setCPULevel:2 的降频指令能到达内核）
if (shouldApplyFullCPUProtection() && SELECTOR_IS_MITIGATION(selector)) {
NSLog(@"[CPUthermal] IOKit 拦截: selector=0x%x %@", selector, isLowPowerMode() ? S("低功耗") : S("解除温控"));
return KERN_SUCCESS;
}
return %orig;
}

// 修复：拦截 IOConnectCallAsyncMethod — 异步降频指令路径
%hookf(kern_return_t, IOConnectCallAsyncMethod, mach_port_t connection, uint32_t selector, mach_port_t wakePort, mach_port_t *asyncRef, uint32_t asyncRefCnt, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
if (!g_enabled || !isThermalConnection(connection)) {
return %orig;
}
if (g_restoringFullPower) {
return %orig;
}
if (shouldApplyFullCPUProtection() && SELECTOR_IS_MITIGATION(selector)) {
NSLog(@"[CPUthermal] IOKit 异步拦截: selector=0x%x %@", selector, isLowPowerMode() ? S("低功耗") : S("解除温控"));
return KERN_SUCCESS;
}
return %orig;
}

// 修复②：拦截 IOConnectCallStructMethod — 结构体调用路径（部分内核驱动走此接口下发功率/频率目标）
%hookf(kern_return_t, IOConnectCallStructMethod, mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
if (!g_enabled || !isThermalConnection(connection)) {
return %orig;
}
if (g_restoringFullPower) {
return %orig;
}
if (shouldApplyFullCPUProtection() && SELECTOR_IS_MITIGATION(selector)) {
NSLog(@"[CPUthermal] IOKit 结构体调用拦截: selector=0x%x %@", selector, isLowPowerMode() ? S("低功耗") : S("解除温控"));
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

// 崩溃防护：key 为 NULL 时直接透传，避免后续 (__bridge NSString *) 与 containsString 崩溃
if (!key) {
return orig_IOServiceSetProperty(service, key, value);
}

// ===================== 新增：拦截Wi‑Fi/蜂窝基带射频温控限流 =====================
if (isNetworkThrottleProperty(key)) {
NSLog(@"[CPUthermal] 已屏蔽网络射频热节流指令: %@", (__bridge NSString *)key);
return KERN_SUCCESS; // 直接丢弃指令，不写入驱动，取消限流
}
// ==========================================================================

NSString *ks = (__bridge NSString *)key;

// ===================== 统一 cpuKeys 关键词匹配 =====================
// 合并原 freqWriteKeys + cpuKeys 两套独立逻辑，消除重复判断冲突
if (g_cpuProtection) {
    if (g_restoringFullPower) {
        return orig_IOServiceSetProperty(service, key, value);
    }
    static NSArray *cpuKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 精简 cpuKeys 数组：统一匹配温控/频率/性能相关属性
        cpuKeys = @[
            S("cpu"),
            S("freq"),
            S("frequency"),
            S("performance"),
            S("throttle"),
            S("mitigation")
        ];
    });
    for (NSString *k in cpuKeys) {
        if ([ks containsString:k]) {
            if (isFullPowerMode()) {
                return KERN_SUCCESS;
            }
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
// ================================================================
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
// 修复：跳主队列执行功率套用，避免初始化线程与主队列保活定时器并发创建/销毁 GCD 定时器
dispatch_async(dispatch_get_main_queue(), ^{
applyCurrentPowerModeToRuntime();
});
NSLog(@"[CPUthermal] CommonProduct init, 已重置热状态为 nominal, 功率模式:%@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
return res;
}

- (void)tryTakeAction {
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
// 强制热压力为 Nominal（正常温度）— 节流：tryTakeAction 每轮热循环都调用，限制 notify 风暴
CPUthermalForceNominalThrottled();
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

// 低功耗模式：强制 CPMS 启用，防止外部代码关闭 CPMS 约束
- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (g_restoringFullPower) {
        %orig(enabled);
        return;
    }
    if (shouldApplyLowPowerLimit()) {
        %orig(YES);  // 低功耗必须保持 CPMS 启用
        return;
    }
    if (shouldApplyFullCPUProtection()) {
        %orig(NO);   // 满血模式关闭 CPMS
        return;
    }
    %orig(enabled);
}

// 低功耗模式：强制 CPU 性能级别，防止外部代码篡改
// 低功耗档位 2（更受限，稳定锁频）、满血档位 0（全速）
- (void)setCPULevel:(int)level {
    if (g_restoringFullPower) {
        %orig(level);
        return;
    }
    if (shouldApplyLowPowerLimit()) {
        %orig(2);  // 低功耗：性能级别 2（原 1 锁不住频）
        return;
    }
    if (shouldApplyFullCPUProtection()) {
        %orig(0);  // 满血：性能级别 0（全速）
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
//   - setHiPFeatureEnabled/setPackageLowPowerTarget: 不 hook (IOKit 层已拦截)
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — 这是 thermalmonitord 判断"要不要降频"的核心
- (void)evaluateDecisionTree {
// 全功率模式: 阻止决策树运行，避免温控降频
if (shouldApplyFullCPUProtection()) {
CPUthermalForceNominalThrottled();
NSLog(@"[CPUthermal] 阻止决策树评估 (全功率模式)");
return;
}
// 低功耗模式: 阻止决策树运行，避免系统改写已锁定的 CPU 目标
if (shouldApplyLowPowerLimit()) {
// 强制热压力为 Nominal（与解除温控模式一致）
CPUthermalForceNominalThrottled();
NSLog(@"[CPUthermal] 阻止决策树评估 (低功耗模式)");
return;
}
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

// 获取组件释放速率 — 可以降低不放 0
- (float)getReleaseRateForComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
NSLog(@"[CPUthermal] 彻底拦截释放速率: %@ -> 0.0", component);
return 0.0;  // 彻底归零
}
return %orig(component);
}

%end

// --- ThermalControl: hook 控制力度计算 ---
%hook ThermalControl

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
if (res) {
trackPowerController(res);
// 修复：跳主队列执行功率套用，避免 fast-loop 线程与主队列保活定时器并发操作 GCD 定时器
dispatch_async(dispatch_get_main_queue(), ^{
applyCurrentPowerModeToRuntime();
});
}
return res;
}

- (id)initWithParams:(id)params {
id res = %orig(params);
if (res) {
trackPowerController(res);
// 修复：跳主队列执行功率套用，避免初始化线程与主队列保活定时器并发操作 GCD 定时器
dispatch_async(dispatch_get_main_queue(), ^{
applyCurrentPowerModeToRuntime();
});
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

// --- ApplePPMCPU: 低功耗时限制 CPU P-state 档位 ---
%hook ApplePPMCPU

// 修复：追踪实例，确保 keep-alive 能强制重应用（弱引用防止僵尸实例泄漏）
- (id)init {
id res = %orig;
if (res) {
os_unfair_lock_lock(&g_stateLock);
if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
[g_applePPMInstances addObject:res];
os_unfair_lock_unlock(&g_stateLock);
if (shouldApplyLowPowerLimit()) {
[res setCPULevel:2];  // 低功耗档位 2（非 0，避免跑满血）
[res updateCPU];
}
}
return res;
}

- (void)setCPULevel:(int)level {
// 修复：每次调用都自注册实例，确保唤醒后重建的实例不被漏追踪
if (self) {
os_unfair_lock_lock(&g_stateLock);
if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
[g_applePPMInstances addObject:self];
os_unfair_lock_unlock(&g_stateLock);
}
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
// 修复：低功耗模式钳制到受限档 2（而非 0 满血），激活低功耗调度
%orig(2);
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
%orig;  // 放行，让 setCPULevel(0) 真正生效到硬件
return;
}
if (shouldApplyLowPowerLimit()) {
// 事件驱动钳制：系统每次更新 P-state 前，强制钳制到受限档 2，
// 不再依赖保活定时器时序（消除长时间睡眠唤醒后的空窗期）
if (self && [self respondsToSelector:@selector(setCPULevel:)]) {
[self setCPULevel:2];
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
// 修复：跳主队列执行功率套用，避免 fast-loop 线程与主队列保活定时器并发操作 GCD 定时器
dispatch_async(dispatch_get_main_queue(), ^{
applyCurrentPowerModeToRuntime();
});
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

// MitigationController 是 CPU 性能档位的核心对象，
// 低功耗强制档位 2（稳定锁频），满血强制档位 0（全速）。
- (void)setCPULevel:(int)level {
if (g_restoringFullPower) {
%orig(level);
return;
}
if (shouldApplyLowPowerLimit()) {
%orig(2);  // 低功耗：性能级别 2（原 1 锁不住频）
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);  // 满血：性能级别 0（全速）
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
// 事件驱动钳制：系统每次更新前强制重新钳制功率目标，
// 消除对保活定时器时序的依赖（长时间睡眠唤醒后的空窗期）
trackPowerController(self);
forceLowPowerSettersOnController(self);
%orig;
return;
}
if (shouldApplyFullCPUProtection()) {
%orig;  // 放行，让 setMaxCPUPowerTarget 设置的高功率目标写入硬件
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
// 低功耗不强制 mW 值，原样放行并记录最大值，
// 由 setCPULevel:2 负责锁频；原 %orig(1380) 属 MHz 传 mW 单位错误。
rememberOriginalIntValue(self, "CPULowPowerTarget", target);
%orig(target);
return;
}
if (shouldApplyFullCPUProtection()) {
// 满血抬到 65W（原直接 return 拦截会让内部状态不同步，导致降频回弹）
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
// 修复②：记录原始值后原样放行（仅记录最大目标、不篡改），
// 低功耗由 setCPULevel:2 锁频；原 %orig((int)g_lowPowerMaxMHz) 属 MHz 传 mW 单位错误。
rememberOriginalIntValue(self, "MaxCPUPowerTarget", target);
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
if (shouldApplyLowPowerLimit()) {
// 低功耗不强制 ceiling（原 40 mW 数值异常），记录后原样放行，由 setCPULevel:2 锁频
rememberOriginalIntValue(self, "CPUPowerCeiling", ceiling);
%orig(ceiling, source);
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
// 低功耗 floor 原样放行，由 setCPULevel:2 锁频
rememberOriginalIntValue(self, "CPUPowerFloor", floor);
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
if (shouldApplyLowPowerLimit()) {
// 低功耗不强制 zone target（原传 MHz 属单位错误），记录后原样放行，由 setCPULevel:2 锁频
rememberOriginalIntValue(self, "CPUPowerZoneTarget", target);
%orig(target);
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

if (isLowPowerMode()) {
@autoreleasepool {
NSMutableDictionary *modified = [config mutableCopy];
if (!modified) return config;
NSDictionary *patched = patchedLowPowerConfigObject(modified, key);
NSMutableDictionary *lowPowerConfig = [patched mutableCopy];
NSMutableDictionary *powerSaveParams = [[lowPowerConfig objectForKey:S("powerSaveParams")] mutableCopy];
if (powerSaveParams) {
[powerSaveParams setObject:[NSNumber numberWithInt:lowPowerTargetValue()] forKey:S("PackageLowPowerTarget")];
[powerSaveParams setObject:[NSNumber numberWithInt:lowPowerTargetValue()] forKey:S("CPULowPowerTarget")];
[lowPowerConfig setObject:powerSaveParams forKey:S("powerSaveParams")];
}
NSLog(@"[CPUthermal] 已应用低功耗配置: %@ target:%d (%lld-%lldMHz)", key, lowPowerTargetValue(), g_lowPowerMinMHz, g_lowPowerMaxMHz);
return [lowPowerConfig copy];
}
}

// 解除温控模式：注入最大功率配置，移除热限制
if (isFullPowerMode()) {
@autoreleasepool {
NSMutableDictionary *modified = [config mutableCopy];
if (modified) {
// 移除/提高 CPU 功率上限
modified[S("CPUMaxPower")] = @100;
modified[S("PackageMaxPower")] = @100;
// 仅在能确定设备最高频率时注入，避免 0 值被系统误读
int fullPowerFreq = fullPowerFrequencyValue();
if (fullPowerFreq > 0) {
modified[S("MaxOperatingFrequency")] = [NSNumber numberWithInt:fullPowerFreq];
}
// 清除所有功率限制参数
NSMutableDictionary *powerSaveParams = [[modified objectForKey:S("powerSaveParams")] mutableCopy];
if (powerSaveParams) {
[powerSaveParams removeObjectForKey:S("PackageLowPowerTarget")];
[powerSaveParams removeObjectForKey:S("CPULowPowerTarget")];
modified[S("powerSaveParams")] = powerSaveParams;
}
// 清除背光热限制
NSMutableDictionary *backlight = [[modified objectForKey:S("backlightComponentControl")] mutableCopy];
if (backlight) {
backlight[S("maxThermalPower")] = @INT32_MAX;
modified[S("backlightComponentControl")] = backlight;
}
NSLog(@"[CPUthermal] 已应用满血热配置: %@", key);
return [modified copy];
}
}
return config;
}
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
loadPrefs();
applyPowerModeToRuntime();
NSLog(@"[CPUthermal] 功率模式已切换: %@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}

static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
loadPrefs();
if (g_enabled) {
applyPowerModeToRuntime();
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
// 锁屏/亮屏状态监听（1.x 适配）— 动态区分锁屏与解锁
//
// 锁屏：放缓保活定时器至 5 秒（省电、降低 IOKit 负载）并低频锁定一次；
// 亮屏/解锁：恢复 0.3 秒高频压制，抵消系统在亮屏后"自主恢复高频"的行为，
// 并追加 0.5s / 1.5s 二次补刀应对系统的持续调频。
// 保留 scheduleWakeRuntimeApply() 双保险，覆盖系统唤醒后的整个重置窗口。
// ============================================================================
static BOOL isDeviceScreenLocked(void) {
    uint64_t state = 0;
    int token;
    // 监听系统锁屏状态 key
    notify_register_check("com.apple.springboard.lockstate", &token);
    notify_get_state(token, &state);
    notify_cancel(token);
    return (state != 0); // 1 代表锁屏/黑屏，0 代表解锁/亮屏
}

static void screenStateChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    if (!g_enabled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        loadPrefs();
        // 现有双保险：无论低功耗/满血，状态变化都先安排脉冲覆盖
        scheduleWakeRuntimeApply();

        // 低功耗下才需要锁屏放缓 / 亮屏恢复高频压制
        if (!isLowPowerMode()) return;

        BOOL locked = isDeviceScreenLocked();

        if (locked) {
            // ==================== 1. 锁屏动作 ====================
            NSLog(@"[CPUthermal] 检测到锁屏，进行低频锁定并放缓定时器");

            // 锁屏瞬间锁定一次
            applyPowerModeToRuntime();

            // 将保活定时器放缓至 5.0 秒，防死锁并省电
            setKeepAliveInterval(5.0);

            // 1 秒后延时补刀一次（应对锁屏动画完成后的系统 P-State 重置）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_enabled && isLowPowerMode()) {
                    applyLowPowerToCommonProduct();
                    applyLowPowerLimitsToTrackedControllers();
                }
            });

        } else {
            // ==================== 2. 亮屏 / 解锁动作 ====================
            NSLog(@"[CPUthermal] 检测到亮屏/解锁，恢复高频压制防止频率回升");

            // 亮屏瞬间立即强行锁定一次
            applyPowerModeToRuntime();

            // 恢复高频定时器，抵消亮屏后系统的"自主恢复高频"行为
            setKeepAliveInterval(kLowPowerKeepAliveInterval);

            // 针对亮屏后系统的持续调频，触发 0.5 秒和 1.5 秒的二次补刀
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_enabled && isLowPowerMode()) {
                    applyPowerModeToRuntime();
                }
            });

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (g_enabled && isLowPowerMode()) {
                    applyPowerModeToRuntime();
                }
            });
        }
    });
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
                applyPowerModeToRuntime();
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
	CFNotificationCenterAddObserver(c, NULL, screenStateChanged,
	(__bridge CFStringRef)S("com.apple.springboard.lockstate"),
	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(c, NULL, screenStateChanged,
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
