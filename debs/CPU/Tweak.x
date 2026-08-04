#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <stdint.h>
#import <string.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#import <CPUthermalPressure.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <os/lock.h>

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
@end

@interface ThermalManager : NSObject
- (void)evaluateDecisionTree;
- (void)updateThermalNotification:(id)notification;
- (float)getReleaseRateForComponent:(id)component;
@end

@interface ThermalControl : NSObject
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface MitigationController : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (void)updateCPU;
- (void)setPackageLowPowerTarget;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
- (void)setCPULevel:(int)level;
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

// 低功耗模式 CPU 性能档位（默认 2，A15 上实测最接近 1380-1428MHz）。
// 可通过偏好 lowPowerCPULevel 覆盖（设置面板未暴露，可在 prefs 中手写）。
static int g_lowPowerCPULevel = 2;

static CommonProduct *g_commonProduct = nil;
static NSHashTable *g_mitigationControllers = nil;  // 弱引用，防止僵尸实例泄漏
static NSHashTable *g_applePPMInstances = nil;      // 追踪 ApplePPMCPU 实例（弱引用）
static os_unfair_lock g_modeLock = OS_UNFAIR_LOCK_INIT;  // 线程安全：保护 g_powerMode

// 温度计警告 & 防暗屏（由设置面板控制）
static BOOL g_thermalBlockNotifPopup = YES;
static BOOL g_thermalPreventDimmingEnabled = YES;
// 温控锁定CPU频率值（对齐 insulation）：用户自定义值，>0 时写入 backlight max/minThermalPower
static int g_cpuMinPowerValue = 0;

static BOOL shouldApplyLowPowerLimit(void);
static void loadPrefs(void);
static void applyCurrentPowerModeToRuntime(void);
static void applyPowerModeToRuntime(void);

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

// 判断某方法的第 index 个参数是否为对象类型（@）
static BOOL methodArgumentTypeIsObject(id object, SEL selector, unsigned int index) {
if (!object || !selector) return NO;
Method method = class_getInstanceMethod(object_getClass(object), selector);
if (!method) return NO;
char type[32] = {0};
method_getArgumentType(method, index, type, sizeof(type));
return type[0] == '@';
}

// 兼容 ThermalControl(setPowerSaveToken:id) 与 MitigationController(setPowerSaveToken:int) 的签名差异
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
if (!g_mitigationControllers) g_mitigationControllers = [NSHashTable weakObjectsHashTable];
[g_mitigationControllers addObject:controller];
}

// 低功耗钳制 setter（不触发 updateCPU/updatePackage，供事件驱动钩子复用，避免递归）
// 对齐 insulation 的 lowPower 路径：setPowerSaveActive:YES + setCPULevel:2。
// 关键修复：不再往 mW 功率 setter 塞 MHz 数值（原 1380/2500 单位错误），
// 改由 CPULevel 档位直接锁频（用户已确认此方案）。
static void forceLowPowerSettersOnController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 1);
}
if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), g_lowPowerCPULevel);
}
if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)]) {
((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
}
}

static void applyLowPowerLimitToController(id controller) {
if (!controller || !shouldApplyLowPowerLimit()) return;
@try {
forceLowPowerSettersOnController(controller);
NSLog(@"[CPUthermal] 已下发低功耗限制 (CPULevel:%d) controller:%@", g_lowPowerCPULevel, controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 下发低功耗限制失败: %@", exception);
}
}

static void applyLowPowerLimitsToTrackedControllers(void) {
if (!shouldApplyLowPowerLimit()) return;
@autoreleasepool {
NSArray *controllers = [g_mitigationControllers allObjects];
for (id controller in controllers) {
applyLowPowerLimitToController(controller);
}
}
}

// 满血恢复：仅关闭省电模式 + CPU 全速档位 0。
// 关键修复：删除原先 65000mW 全套功率写入 —— 那是「切回低功耗仍卡高频」的直接根因。
// 满血由 putDeviceInThermalSimulationMode:@"nominal" + 阻塞热动作（insulation 方案）实现，
// 不再需要把功率 setter 抬到 65W，因此切换模式时也不存在需要拆除的残留状态。
static void restoreFullPowerToController(id controller) {
if (!controller || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
}
if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
sendSetPowerSaveToken(controller, 0);
}
if ([controller respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), 0);
}
NSLog(@"[CPUthermal] 已恢复解除温控状态 controller:%@", controller);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 恢复解除温控状态失败: %@", exception);
}
}

static void restoreFullPowerToTrackedControllers(void) {
if (!g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@autoreleasepool {
NSArray *controllers = [g_mitigationControllers allObjects];
for (id controller in controllers) {
restoreFullPowerToController(controller);
}
}
}

// 满血：对齐 insulation —— putDeviceInThermalSimulationMode:@"nominal"（系统下一决策周期主动撤销节流）
// + 关闭 CPMS 缓解 + CPU 全速档 0 + 强制热压力 Nominal。
static void applyFullPowerToCommonProduct(void) {
if (!g_commonProduct || !g_enabled || !g_cpuProtection || !isFullPowerMode()) return;
@try {
if ([g_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
[g_commonProduct putDeviceInThermalSimulationMode:S("nominal")];
}
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), NO);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), 0);
}
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 已套用解除温控 CommonProduct 状态");
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用解除温控 CommonProduct 状态失败: %@", exception);
}
}

// 低功耗：CPMS 缓解开启 + CPULevel 档位锁定。
// 关键修复：不再调用 CPUthermalForceNominalCombined() —— 低功耗却强制热压力 Nominal 与省电意图自相矛盾，
// 系统会倾向升频，把一切押在不可靠的档位约束上。
static void applyLowPowerToCommonProduct(void) {
if (!g_commonProduct || !shouldApplyLowPowerLimit()) return;
@try {
if ([g_commonProduct respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) {
((void (*)(id, SEL, BOOL))objc_msgSend)(g_commonProduct, @selector(setCPMSMitigationsEnabled:), YES);
}
if ([g_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(g_commonProduct, @selector(setCPULevel:), g_lowPowerCPULevel);
}
NSLog(@"[CPUthermal] 已套用低功耗 CommonProduct 状态 (CPULevel:%d)", g_lowPowerCPULevel);
} @catch (NSException *exception) {
NSLog(@"[CPUthermal] 套用低功耗 CommonProduct 状态失败: %@", exception);
}
}

// 事件驱动：系统每次更新 P-state 前，强制所有 ApplePPMCPU 实例到低功耗档位
static void applyLowPowerToApplePPMCPU(void) {
if (!shouldApplyLowPowerLimit() || !g_applePPMInstances) return;
for (id ppm in g_applePPMInstances) {
if (!ppm) continue;
if ([ppm respondsToSelector:@selector(setCPULevel:)]) {
((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), g_lowPowerCPULevel);
}
if ([ppm respondsToSelector:@selector(updateCPU)]) {
((void (*)(id, SEL))objc_msgSend)(ppm, @selector(updateCPU));
}
}
}

static void applyCurrentPowerModeToRuntime(void) {
applyPowerModeToRuntime();
}

// 应用当前功率模式。
// 模式切换 = 写 prefs + 重启 thermalmonitord（新进程无残留状态），因此这里无需
// 启动/停止任何定时器，也不存在需要拆除的 65000mW 等残留功率状态。
static void applyPowerModeToRuntime(void) {
if (!g_enabled || !g_cpuProtection) return;
if (isLowPowerMode()) {
applyLowPowerToCommonProduct();
applyLowPowerLimitsToTrackedControllers();
applyLowPowerToApplePPMCPU();
return;
}
if (isFullPowerMode()) {
applyFullPowerToCommonProduct();
restoreFullPowerToTrackedControllers();
}
}

static NSDictionary *readPrefsDictionary(void) {
return CPUthermalReadPrefs();
}

static void loadPrefs(void) {
@autoreleasepool {
NSDictionary *d = readPrefsDictionary();
if (!d) return;
g_enabled               = YES; // 始终启用，不依赖偏好设置
g_thermalBlockNotifPopup     = [d[S("thermalBlockNotifPopup")] ?: [NSNumber numberWithBool:YES] boolValue];
g_thermalPreventDimmingEnabled = [d[S("thermalPreventDimmingEnabled")] ?: [NSNumber numberWithBool:YES] boolValue];

// 温控锁定CPU频率值（对齐 insulation）：PSEditTextCell 存字符串，intValue 解析，空/非法为 0
g_cpuMinPowerValue = [d[S("cpuMinPowerValue")] intValue];
if (g_cpuMinPowerValue < 0) g_cpuMinPowerValue = 0;

// 低功耗 CPU 性能档位（可选偏好，默认 2）
NSNumber *prefLowCPULevel = d[S("lowPowerCPULevel")];
if (prefLowCPULevel) g_lowPowerCPULevel = [prefLowCPULevel intValue];
if (g_lowPowerCPULevel < 0) g_lowPowerCPULevel = 0;

NSString *mode = d[S("powerMode")] ?: S("fullPower");
os_unfair_lock_lock(&g_modeLock);
g_powerMode = [mode isEqualToString:S("lowPower")] ? CPUthermalPowerModeLow : CPUthermalPowerModeFull;
os_unfair_lock_unlock(&g_modeLock);
}
}

// ============================================================================
// IOServiceSetProperty — 仅拦截网络射频温控限流（独立于 thermalmonitord 的子系统）
//
// 关键修复：删除原先满血模式下对含 cpu/freq/throttle/mitigation key 的宽泛 drop
// （return KERN_SUCCESS）。那种冻结内核控制路径的做法正是「切回低功耗卡死」的
// 次要根因之一 —— 被静默丢弃的写入使驱动状态不一致，且没有任何机制能恢复。
// 满血解锁改由 insulation 方案（nominal 模拟 + ObjC 层阻塞热动作）实现。
// ============================================================================
static kern_return_t (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
if (!g_enabled) {
return orig_IOServiceSetProperty(service, key, value);
}

// 拦截 Wi‑Fi/蜂窝基带射频温控限流
if (isNetworkThrottleProperty(key)) {
NSLog(@"[CPUthermal] 已屏蔽网络射频热节流指令: %@", (__bridge NSString *)key);
return KERN_SUCCESS; // 直接丢弃指令，不写入驱动，取消限流
}
return orig_IOServiceSetProperty(service, key, value);
}

// ============================================================================
// ObjC 类钩子（第1层: CommonProduct / HidSensors）
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
// 满血：强制热压力 Nominal + 阻止所有热缓解动作（对齐 insulation）
CPUthermalForceNominalCombined();
return;
}
if (shouldApplyLowPowerLimit()) {
// 低功耗：阻止热动作改动已锁定的 CPULevel 档位，但不强制 Nominal（避免自相矛盾）
return;
}
%orig;
}

- (void)simulateLightThermalPressure {
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
return;
}
%orig;
}

- (void)updatePowerzoneTelemetry {
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
return;
}
%orig;
}

// 低功耗：强制 CPMS 启用；满血：关闭 CPMS（对齐 insulation）
- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
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

// 低功耗：强制 CPU 性能档位锁定；满血：全速档 0
- (void)setCPULevel:(int)level {
if (shouldApplyLowPowerLimit()) {
%orig(g_lowPowerCPULevel);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);
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
//   - 传感器读数 getHighestSkinTemp/dieTempFilteredMaxAverage/thermalSensorValuesMaxFromIndexSet 不 hook
//   - putDeviceInThermalSimulationMode: 不 hook（CPUthermal 自己调用会递归）
//   - setCPMSMitigationState: 不 hook
// ============================================================================

// --- ThermalManager: hook 决策树和热压力升级 ---
%hook ThermalManager

// 决策树评估 — thermalmonitord 判断"要不要降频"的核心。
// 两种模式均阻止：满血避免降频；低功耗避免系统改写已锁定的 CPULevel 目标。
// 满血时额外强制热压力 Nominal。
- (void)evaluateDecisionTree {
if (shouldApplyFullCPUProtection()) {
CPUthermalForceNominalCombined();
NSLog(@"[CPUthermal] 阻止决策树评估 (解除温控)");
return;
}
if (shouldApplyLowPowerLimit()) {
NSLog(@"[CPUthermal] 阻止决策树评估 (低功耗)");
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

// 获取组件释放速率 — 满血时归零，防止系统释放节流（保持满血）
- (float)getReleaseRateForComponent:(id)component {
if (shouldApplyFullCPUProtection()) {
return 0.0;
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

// 计算控制力度 — throttle 量核心。满血归零，低功耗放行（决策树已拦，实际不会被调用）
- (float)calculateControlEffort:(id)trigger trigger:(id)arg2 {
if (shouldApplyFullCPUProtection()) {
return 0.0;
}
return %orig(trigger, arg2);
}

// actionComponentControl / readReleaseRateForAllComponents — 两种模式均阻止，避免改动已锁定的状态
- (void)actionComponentControl {
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
return;
}
%orig;
}

- (void)readReleaseRateForAllComponents {
if (shouldApplyFullCPUProtection() || shouldApplyLowPowerLimit()) {
return;
}
%orig;
}

%end

// --- ApplePPMCPU: 低功耗时限制 CPU P-state 档位 ---
%hook ApplePPMCPU

// 追踪实例（弱引用防止僵尸实例泄漏）
- (id)init {
id res = %orig;
if (res) {
if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
[g_applePPMInstances addObject:res];
if (shouldApplyLowPowerLimit()) {
[res setCPULevel:g_lowPowerCPULevel];
[res updateCPU];
}
}
return res;
}

- (void)setCPULevel:(int)level {
// 每次调用都自注册实例，确保唤醒后重建的实例不被漏追踪
if (self) {
if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
[g_applePPMInstances addObject:self];
}
if (shouldApplyLowPowerLimit()) {
%orig(g_lowPowerCPULevel);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig;
}

- (void)updateCPU {
if (shouldApplyFullCPUProtection()) {
%orig;  // 放行，让 setCPULevel(0) 真正生效到硬件
return;
}
if (shouldApplyLowPowerLimit()) {
// 事件驱动钳制：系统每次更新 P-state 前，强制钳制到低功耗档位
if (self && [self respondsToSelector:@selector(setCPULevel:)]) {
[self setCPULevel:g_lowPowerCPULevel];
}
%orig;
return;
}
%orig;
}

%end

// --- MitigationController: CPU 性能档位 & 省电模式控制 ---
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
if (shouldApplyLowPowerLimit()) {
return YES;
}
if (shouldApplyFullCPUProtection()) {
return NO;
}
return %orig;
}

- (void)setPowerSaveActive:(BOOL)active {
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

// CPU 性能档位：低功耗强制 g_lowPowerCPULevel，满血强制 0（全速）
- (void)setCPULevel:(int)level {
if (shouldApplyLowPowerLimit()) {
%orig(g_lowPowerCPULevel);
return;
}
if (shouldApplyFullCPUProtection()) {
%orig(0);
return;
}
%orig(level);
}

- (void)updateCPU {
if (shouldApplyLowPowerLimit()) {
// 事件驱动钳制：系统每次更新前强制重新钳制低功耗 setter，
// 消除对保活定时器时序的依赖（长时间睡眠唤醒后的空窗期）
trackPowerController(self);
forceLowPowerSettersOnController(self);
%orig;
return;
}
%orig;  // 满血放行，让 CPULevel(0) 真正生效到硬件
}

// 满血阻止系统进入包域低功耗预算
- (void)setPackageLowPowerTarget {
if (shouldApplyFullCPUProtection()) {
return;
}
%orig;
}

%end

// ============================================================================
// 防温控暗屏 — 修补热配置 plist 中的背光参数
// 由 thermalPreventDimmingEnabled 开关控制
// ============================================================================

static NSDictionary *patchThermalPlist(NSDictionary *dict) {
// 防温控暗屏 或 温控锁定CPU频率值 任一启用才修补
if (!g_thermalPreventDimmingEnabled && g_cpuMinPowerValue <= 0) return dict;

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

// 温控锁定CPU频率值（对齐 insulation）：用户自定义值 > 0 时写入 max/minThermalPower
if (g_cpuMinPowerValue > 0) {
mutableBacklight[S("maxThermalPower")] = @(g_cpuMinPowerValue);
mutableBacklight[S("minThermalPower")] = @(g_cpuMinPowerValue);
}

mutableDict[S("backlightComponentControl")] = mutableBacklight;

NSLog(@"[CPUthermal] 已修补热配置: 防温控暗屏=%d 锁定CPU频率值=%d", g_thermalPreventDimmingEnabled, g_cpuMinPowerValue);
}

return mutableDict;
}

// --- NSDictionary: 拦截热配置 plist 加载，应用防暗屏补丁 ---
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
id res = %orig(path);
if ((g_thermalPreventDimmingEnabled || g_cpuMinPowerValue > 0) && [path containsString:S("/System/Library/ThermalMonitor/")]) {
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
applyPowerModeToRuntime();
}
NSLog(S("[CPUthermal] 收到唤醒/亮屏事件，已重应用当前功率模式"));
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
applyPowerModeToRuntime();
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

// 确保 IOKit 已加载，安装 IOServiceSetProperty 钩子（仅网络射频限流拦截）
void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
if (iokit) {
kern_return_t (*ptr)(io_service_t, CFStringRef, CFTypeRef) = (kern_return_t (*)(io_service_t, CFStringRef, CFTypeRef))dlsym(iokit, "IOServiceSetProperty");
if (ptr) {
MSHookFunction((void *)ptr, (void *)hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
NSLog(@"[CPUthermal] IOServiceSetProperty hook 已安装 (仅网络射频拦截)");
} else {
NSLog(@"[CPUthermal] 警告: 未找到 IOServiceSetProperty");
}
}

// 模拟热级别监听 + 设置变更监听 + 唤醒事件监听
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

// 进程启动即应用当前功率模式（新进程无残留状态，这是模式切换的可靠基础）
applyCurrentPowerModeToRuntime();
NSLog(@"[CPUthermal] 启动完成，当前功率模式:%@", isLowPowerMode() ? S("低功耗") : S("解除温控"));
}
}
