#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <substrate.h>
#import <AppLowPowerPaths.h>

#ifdef APPLOWPOWER_STRIP_LOGS
#define NSLog(...) do {} while (0)
#endif

// ============================================================================
// thermalmonitord 私有类声明（class-dump 获取）
// ============================================================================
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(id)source;
- (void)tryTakeAction;
@end

@interface MitigationController : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (void)updateCPU;
- (void)updatePackage;
- (void)setCPULowPowerTarget:(int)target;
- (void)setPackageLowPowerTarget;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(int)contributor;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)setCPULevel:(int)level;
- (void)setDVD1Level:(int)level;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
@end

@interface ThermalControl : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (id)initWithParams:(id)params;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

// ============================================================================
// 低功耗预算
// ============================================================================
static const int kALPLowPowerCPULevel = 2;          // CPULevel/DVD1Level 使用节流等级
static const int kALPLowPowerPowerLimitMW = 2500;   // setCPULowPowerTarget:/setMaxCPUPowerTarget: 使用 mW
static const int kALPLowPowerPercent = 45;          // Ceiling/PowerZone 使用 0~100 百分比
static const int kALPCPUDecisionSourceCount = 6;
static const int kALPCPUDVD1ContributorCount = 4;
// 重建节流窗口：新进程启动后 5 秒内不再触发下一次重建，避免 launchd 重启风暴。
static const uint64_t kALPRestartCooldownSeconds = 5;
// 重建标记有效期：超过该时间视为普通冷启动，走常规节奏而非急速套用。
static const uint64_t kALPRestartFlagValiditySeconds = 60;
static BOOL g_fastApplyAfterRestart = NO;
static BOOL g_didInitialEvaluate = NO;

static BOOL g_lowPowerActive = NO;                  // 当前前台应用命中列表
static uint64_t g_lastForegroundHash = UINT64_MAX;
static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_controllerLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *g_controllers = nil;            // 弱引用，避免僵尸实例
static NSHashTable *g_applePPMInstances = nil;
static CommonProduct *g_commonProduct = nil;
static dispatch_source_t g_keepAliveTimer = NULL;
static BOOL g_restartScheduled = NO;
static void applyLowPowerToRuntime(void);
static void restoreNativeRuntime(void);
static void restartThermalMonitorForFastApply(void);

static BOOL lowPowerActive(void) {
    os_unfair_lock_lock(&g_stateLock);
    BOOL active = g_lowPowerActive;
    os_unfair_lock_unlock(&g_stateLock);
    return active;
}

static void trackController(id controller) {
    if (!controller) return;
    os_unfair_lock_lock(&g_controllerLock);
    if (!g_controllers) g_controllers = [NSHashTable weakObjectsHashTable];
    [g_controllers addObject:controller];
    os_unfair_lock_unlock(&g_controllerLock);
}

static NSArray *controllersSnapshot(void) {
    os_unfair_lock_lock(&g_controllerLock);
    NSArray *controllers = g_controllers ? [g_controllers allObjects] : @[];
    os_unfair_lock_unlock(&g_controllerLock);
    return controllers;
}

static void trackApplePPM(id instance) {
    if (!instance) return;
    os_unfair_lock_lock(&g_controllerLock);
    if (!g_applePPMInstances) g_applePPMInstances = [NSHashTable weakObjectsHashTable];
    [g_applePPMInstances addObject:instance];
    os_unfair_lock_unlock(&g_controllerLock);
}

static NSArray *applePPMSnapshot(void) {
    os_unfair_lock_lock(&g_controllerLock);
    NSArray *instances = g_applePPMInstances ? [g_applePPMInstances allObjects] : @[];
    os_unfair_lock_unlock(&g_controllerLock);
    return instances;
}

// 不同 iOS/SoC 上参数宽度不一致；按方法签名选择正确 ABI 调用。
static char argumentTypeCode(id object, SEL selector, unsigned int index) {
    if (!object || !selector) return '\0';
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || index >= method_getNumberOfArguments(method)) return '\0';
    char type[32] = {0};
    method_getArgumentType(method, index, type, sizeof(type));
    const char *cursor = type;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor;
}
static BOOL typeIs32Bit(char type) { return type=='c'||type=='C'||type=='s'||type=='S'||type=='i'||type=='I'||type=='B'; }
static BOOL typeIs64Bit(char type) { return type=='q'||type=='Q'||type=='l'||type=='L'||type=='^'; }

static void sendTwoIntegers(id object, SEL selector, intptr_t first, uintptr_t second) {
    if (!object || ![object respondsToSelector:selector]) return;
    char a = argumentTypeCode(object, selector, 2), b = argumentTypeCode(object, selector, 3);
    if (typeIs32Bit(a) && typeIs32Bit(b)) { ((void (*)(id, SEL, int, int))objc_msgSend)(object, selector, (int)first, (int)second); return; }
    if (typeIs32Bit(a) && typeIs64Bit(b)) { ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(object, selector, (int)first, second); return; }
    if (typeIs64Bit(a) && typeIs32Bit(b)) { ((void (*)(id, SEL, intptr_t, int))objc_msgSend)(object, selector, first, (int)second); return; }
    if (typeIs64Bit(a) && typeIs64Bit(b)) { ((void (*)(id, SEL, intptr_t, uintptr_t))objc_msgSend)(object, selector, first, second); }
}

static CFStringRef cpuMaxPowerPropertyName(void) {
    static CFStringRef name = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ name = CFStringCreateWithCString(kCFAllocatorDefault, "CPUMaxPower", kCFStringEncodingUTF8); });
    return name;
}

static BOOL maxCPUPowerUsesCFString(id controller) {
    Method method = class_getInstanceMethod(object_getClass(controller), @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:));
    if (!method) return NO;
    const char *types = method_getTypeEncoding(method);
    return types && strstr(types, "^{__CFString=}") != NULL;
}

static void sendMaxCPUPowerTarget(id controller, int target) {
    if (!controller || ![controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) return;
    uintptr_t property = maxCPUPowerUsesCFString(controller) ? (uintptr_t)cpuMaxPowerPropertyName() : (uintptr_t)YES;
    ((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
        @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:), target, NO, property);
}

static void applyLowPowerBudgets(id controller) {
    if (!controller) return;
    trackController(controller);
    if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
    if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
    if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)])
        ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), kALPLowPowerPowerLimitMW);
    sendMaxCPUPowerTarget(controller, kALPLowPowerPowerLimitMW);
    if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)])
        ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), kALPLowPowerPercent);
    for (int source = 0; source < kALPCPUDecisionSourceCount; source++) {
        if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)])
            sendTwoIntegers(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), kALPLowPowerPercent, (uintptr_t)source);
        if ([controller respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)])
            sendTwoIntegers(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, (uintptr_t)source);
    }
    for (int contributor = 0; contributor < kALPCPUDVD1ContributorCount; contributor++)
        if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)])
            sendTwoIntegers(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), kALPLowPowerPercent, (uintptr_t)contributor);
    if ([controller respondsToSelector:@selector(setPackageLowPowerTarget)])
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(setPackageLowPowerTarget));
    if ([controller respondsToSelector:@selector(setCPULevel:)])
        ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kALPLowPowerCPULevel);
    if ([controller respondsToSelector:@selector(setDVD1Level:)])
        ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setDVD1Level:), kALPLowPowerCPULevel);
    if ([controller respondsToSelector:@selector(updateCPU)])
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
    if ([controller respondsToSelector:@selector(updatePackage)])
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
    // update 可能按原生策略回写；刷新后再次锁定当前预算。
    if ([controller respondsToSelector:@selector(setCPULevel:)])
        ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kALPLowPowerCPULevel);
}

static void applyLowPowerToCommonProduct(void) {
    os_unfair_lock_lock(&g_stateLock);
    CommonProduct *product = g_commonProduct;
    os_unfair_lock_unlock(&g_stateLock);
    if (!product) return;
    @try {
        if ([product respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(product, @selector(setCPMSMitigationsEnabled:), YES);
        if ([product respondsToSelector:@selector(setCPULevel:)])
            ((void (*)(id, SEL, int))objc_msgSend)(product, @selector(setCPULevel:), kALPLowPowerCPULevel);
        if ([product respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)])
            ((void (*)(id, SEL, int, id))objc_msgSend)(product, @selector(setCPUPowerCeiling:fromDecisionSource:), kALPLowPowerPercent, S("AppLowPower"));
        if ([product respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)])
            ((void (*)(id, SEL, int, id))objc_msgSend)(product, @selector(setCPUPowerFloor:fromDecisionSource:), 0, S("AppLowPower"));
        if ([product respondsToSelector:@selector(tryTakeAction)])
            ((void (*)(id, SEL))objc_msgSend)(product, @selector(tryTakeAction));
    } @catch (NSException *exception) {
        NSLog(@"[AppLowPower] CommonProduct 应用低功耗失败: %@", exception);
    }
}

static void applyLowPowerToApplePPM(void) {
    for (id ppm in applePPMSnapshot()) {
        if (![ppm respondsToSelector:@selector(setCPULevel:)]) continue;
        ((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), kALPLowPowerCPULevel);
        if ([ppm respondsToSelector:@selector(updateCPU)]) ((void (*)(id, SEL))objc_msgSend)(ppm, @selector(updateCPU));
        ((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), kALPLowPowerCPULevel);
    }
}

static void stopKeepAliveTimer(void) {
    os_unfair_lock_lock(&g_controllerLock);
    dispatch_source_t timer = g_keepAliveTimer;
    g_keepAliveTimer = NULL;
    os_unfair_lock_unlock(&g_controllerLock);
    if (timer) dispatch_source_cancel(timer);
}

static void startKeepAliveTimer(void) {
    os_unfair_lock_lock(&g_controllerLock);
    if (g_keepAliveTimer) { os_unfair_lock_unlock(&g_controllerLock); return; }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) { os_unfair_lock_unlock(&g_controllerLock); return; }
    g_keepAliveTimer = timer;
    os_unfair_lock_unlock(&g_controllerLock);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 5ull * NSEC_PER_SEC, 500ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (!lowPowerActive()) { stopKeepAliveTimer(); return; }
        applyLowPowerToCommonProduct();
        for (id controller in controllersSnapshot()) applyLowPowerBudgets(controller);
        applyLowPowerToApplePPM();
    });
    dispatch_resume(timer);
}

// 退出所选应用后交还系统原生温控策略：不再由本插件写入任何目标值。
static void restoreNativeRuntime(void) {
    stopKeepAliveTimer();
    g_fastApplyAfterRestart = NO;
    os_unfair_lock_lock(&g_controllerLock);
    g_restartScheduled = NO;
    os_unfair_lock_unlock(&g_controllerLock);
    @autoreleasepool {
        for (id controller in controllersSnapshot()) {
            if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), NO);
            if ([controller respondsToSelector:@selector(setCPULevel:)])
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), 0);
            if ([controller respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)])
                for (int source = 0; source < kALPCPUDecisionSourceCount; source++)
                    sendTwoIntegers(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), 100, (uintptr_t)source);
            if ([controller respondsToSelector:@selector(setCPUPowerCeiling:forDVD1Contributor:)])
                for (int contributor = 0; contributor < kALPCPUDVD1ContributorCount; contributor++)
                    sendTwoIntegers(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), 100, (uintptr_t)contributor);
            if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)])
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), 100);
            if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)])
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), 65000);
            sendMaxCPUPowerTarget(controller, 65000);
            if ([controller respondsToSelector:@selector(setDVD1Level:)])
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setDVD1Level:), 0);
            if ([controller respondsToSelector:@selector(updateCPU)])
                ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
            if ([controller respondsToSelector:@selector(updatePackage)])
                ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
        }
        for (id ppm in applePPMSnapshot()) {
            if ([ppm respondsToSelector:@selector(setCPULevel:)])
                ((void (*)(id, SEL, int))objc_msgSend)(ppm, @selector(setCPULevel:), 0);
            if ([ppm respondsToSelector:@selector(updateCPU)])
                ((void (*)(id, SEL))objc_msgSend)(ppm, @selector(updateCPU));
        }
    }
    NSLog(@"[AppLowPower] 已退出低功耗，恢复系统原生温控调度");
}

static void applyLowPowerToRuntime(void) {
    applyLowPowerToCommonProduct();
    for (id controller in controllersSnapshot()) applyLowPowerBudgets(controller);
    applyLowPowerToApplePPM();
    startKeepAliveTimer();
    // 私有对象可能在 hook 之后才创建；重建后使用更密集的脉冲实现进入应用即刻降频。
    int pulses = g_fastApplyAfterRestart ? 12 : 6;
    double interval = g_fastApplyAfterRestart ? 0.1 : 0.2;
    for (int pulse = 1; pulse <= pulses; pulse++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pulse * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!lowPowerActive()) return;
            applyLowPowerToCommonProduct();
            for (id controller in controllersSnapshot()) applyLowPowerBudgets(controller);
            applyLowPowerToApplePPM();
        });
    }
}

// 进入所选应用时重建 thermalmonitord：新进程在 %ctor 阶段即读取前台状态，
// 从干净的 CPMS/ApplePPM 缓存直接进入低功耗，避免旧进程残留调度延迟生效。
static void restartThermalMonitorForFastApply(void) {
    uint64_t now = (uint64_t)time(NULL);
    uint64_t previous = ALPRestartTimestamp(ALPReadRestartState());
    if (previous && now >= previous && (now - previous) < kALPRestartCooldownSeconds) return;

    os_unfair_lock_lock(&g_controllerLock);
    if (g_restartScheduled) { os_unfair_lock_unlock(&g_controllerLock); return; }
    g_restartScheduled = YES;
    os_unfair_lock_unlock(&g_controllerLock);

    ALPPostRestartState(ALPMakeRestartState(now, YES));
    // 先在当前进程套用一次，覆盖重建期间的空窗；随后由 launchd 重新拉起守护。
    applyLowPowerToRuntime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[AppLowPower] 重建 thermalmonitord 以立即套用低功耗");
        kill(getpid(), SIGTERM);
    });
}

static BOOL foregroundAppSelected(void) {
    NSDictionary *prefs = ALPReadPrefs();
    if (![prefs isKindOfClass:[NSDictionary class]]) return NO;
    if (prefs[S("enabled")] && ![prefs[S("enabled")] boolValue]) return NO;
    uint64_t foregroundHash = ALPReadForegroundBundleHash();
    NSArray *selected = [prefs[S("lowPowerApps")] isKindOfClass:[NSArray class]] ? prefs[S("lowPowerApps")] : nil;
    if (foregroundHash == 0 || selected.count == 0) return NO;
    for (id rawBundleID in selected)
        if ([rawBundleID isKindOfClass:[NSString class]] && ALPBundleIDHash(rawBundleID) == foregroundHash) return YES;
    return NO;
}

static void reloadState(BOOL forceApply) {
    BOOL shouldApply = foregroundAppSelected();
    BOOL changed = NO;
    BOOL firstEvaluation = NO;
    os_unfair_lock_lock(&g_stateLock);
    changed = (g_lowPowerActive != shouldApply);
    g_lowPowerActive = shouldApply;
    firstEvaluation = !g_didInitialEvaluate;
    g_didInitialEvaluate = YES;
    os_unfair_lock_unlock(&g_stateLock);

    if (shouldApply) {
        // 重建后的新进程首次求值直接套用，不再触发下一次重建，避免重启循环。
        if (firstEvaluation) applyLowPowerToRuntime();
        else if (changed) restartThermalMonitorForFastApply();
        else if (forceApply) applyLowPowerToRuntime();
    } else if (changed || firstEvaluation) {
        // 离开所选应用（含返回桌面、切到未选应用）：立即交还原生频率调度。
        ALPPostRestartState(ALPMakeRestartState(ALPRestartTimestamp(ALPReadRestartState()), NO));
        if (changed) restoreNativeRuntime();
    }
    NSLog(@"[AppLowPower] 前台命中:%d 变化:%d 首次:%d", shouldApply, changed, firstEvaluation);
}

// ============================================================================
// thermalmonitord 侧 Hook：只在命中所选应用时限制功率，其余全部放行
// ============================================================================
%group ThermalMonitor

%hook CommonProduct
- (id)initProduct:(id)arg1 {
    id result = %orig;
    if (result) {
        os_unfair_lock_lock(&g_stateLock);
        g_commonProduct = (CommonProduct *)result;
        os_unfair_lock_unlock(&g_stateLock);
        reloadState(YES);
    }
    return result;
}
%end

%hook ThermalControl
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id result = %orig; if (result) { trackController(result); reloadState(NO); } return result;
}
- (id)initWithParams:(id)params { id result = %orig; if (result) { trackController(result); reloadState(NO); } return result; }
- (BOOL)powerSaveActive { return lowPowerActive() ? YES : %orig; }
- (void)setPowerSaveActive:(BOOL)active { trackController(self); %orig(lowPowerActive() ? YES : active); }
%end

%hook MitigationController
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id result = %orig; if (result) { trackController(result); reloadState(NO); } return result;
}
- (BOOL)powerSaveActive { return lowPowerActive() ? YES : %orig; }
- (void)setPowerSaveActive:(BOOL)active { trackController(self); %orig(lowPowerActive() ? YES : active); }
- (void)setCPMSMitigationsEnabled:(BOOL)enabled { %orig(lowPowerActive() ? YES : enabled); }
- (void)setCPULevel:(int)level { trackController(self); %orig(lowPowerActive() ? kALPLowPowerCPULevel : level); }
- (void)setDVD1Level:(int)level { %orig(lowPowerActive() ? kALPLowPowerCPULevel : level); }
- (void)setCPULowPowerTarget:(int)target { %orig(lowPowerActive() ? kALPLowPowerPowerLimitMW : target); }
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    if (lowPowerActive()) %orig(kALPLowPowerPowerLimitMW, NO, property); else %orig(target, legacy, property);
}
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    %orig(lowPowerActive() ? kALPLowPowerPercent : ceiling, source);
}
- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(int)contributor {
    %orig(lowPowerActive() ? kALPLowPowerPercent : ceiling, contributor);
}
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source {
    %orig(lowPowerActive() ? 0 : floor, source);
}
- (void)setCPUPowerZoneTarget:(int)target { %orig(lowPowerActive() ? kALPLowPowerPercent : target); }
- (void)updateCPU {
    if (!lowPowerActive()) { %orig; return; }
    applyLowPowerBudgets(self); %orig; applyLowPowerBudgets(self);
}
%end

%hook ApplePPMCPU
- (id)init { id result = %orig; if (result) trackApplePPM(result); return result; }
- (void)setCPULevel:(int)level { trackApplePPM(self); %orig(lowPowerActive() ? kALPLowPowerCPULevel : level); }
- (void)updateCPU {
    if (lowPowerActive() && [self respondsToSelector:@selector(setCPULevel:)])
        ((void (*)(id, SEL, int))objc_msgSend)(self, @selector(setCPULevel:), kALPLowPowerCPULevel);
    %orig;
}
%end

%end

// ============================================================================
// SpringBoard 侧：识别当前前台应用并上报 Bundle ID 哈希
// ============================================================================
static NSString *stringFromObject(id object, const char **selectors) {
    for (int i = 0; object && selectors[i]; i++) {
        SEL selector = sel_registerName(selectors[i]);
        if (![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}

static NSString *springBoardFrontmostBundleID(void) {
    id application = nil;
    id springBoard = [UIApplication sharedApplication];
    const char *frontSelectors[] = {"_accessibilityFrontMostApplication", "accessibilityFrontMostApplication", "frontmostApplication", NULL};
    for (int i = 0; frontSelectors[i] && !application; i++) {
        SEL selector = sel_registerName(frontSelectors[i]);
        if ([springBoard respondsToSelector:selector]) application = ((id (*)(id, SEL))objc_msgSend)(springBoard, selector);
    }
    if (!application) {
        Class controllerClass = objc_getClass("SBApplicationController");
        SEL sharedSelector = sel_registerName("sharedInstance");
        id controller = [controllerClass respondsToSelector:sharedSelector] ? ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector) : nil;
        SEL frontSelector = sel_registerName("frontmostApplication");
        if ([controller respondsToSelector:frontSelector]) application = ((id (*)(id, SEL))objc_msgSend)(controller, frontSelector);
    }
    const char *idSelectors[] = {"bundleIdentifier", "displayIdentifier", "applicationIdentifier", NULL};
    return stringFromObject(application, idSelectors);
}

static void reportFrontmostApplication(void) {
    NSString *bundleID = springBoardFrontmostBundleID();
    uint64_t hash = ALPBundleIDHash(bundleID);
    if (hash == g_lastForegroundHash) return;
    g_lastForegroundHash = hash;
    if (bundleID.length) ALPPostForegroundBundleID(bundleID);
    else ALPPostForegroundBundleID(nil);
}

%group SpringBoard

%hook SBApplication
- (void)activate {
    %orig;
    const char *selectors[] = {"bundleIdentifier", "displayIdentifier", "applicationIdentifier", NULL};
    NSString *bundleID = stringFromObject(self, selectors);
    if (bundleID.length) { g_lastForegroundHash = ALPBundleIDHash(bundleID); ALPPostForegroundBundleID(bundleID); }
}
%end

%end

// ============================================================================
// %ctor
// ============================================================================
static void onSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_block_t block = ^{ reloadState(NO); };
    if ([NSThread isMainThread]) block(); else dispatch_async(dispatch_get_main_queue(), block);
}

static void onForegroundAppChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_block_t block = ^{ reloadState(YES); };
    if ([NSThread isMainThread]) block(); else dispatch_async(dispatch_get_main_queue(), block);
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *processName = [[NSProcessInfo processInfo] processName];
        BOOL isSpringBoard = [bundleID isEqualToString:S("com.apple.springboard")];
        BOOL isThermalMonitor = [processName isEqualToString:S("thermalmonitord")];

        if (isSpringBoard) {
            %init(SpringBoard);
            dispatch_async(dispatch_get_main_queue(), ^{
                reportFrontmostApplication();
                // SpringBoard 作为系统级真值源轮询前台应用，不依赖第三方应用注入。
                [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
                    reportFrontmostApplication();
                }];
            });
            NSLog(@"[AppLowPower] SpringBoard 前台监控已启动");
            return;
        }

        if (!isThermalMonitor) return;

        // 读取重建标记：若本次启动由“进入指定应用”触发，则使用急速套用节奏。
        uint64_t restartState = ALPReadRestartState();
        uint64_t restartAge = (uint64_t)time(NULL) - ALPRestartTimestamp(restartState);
        g_fastApplyAfterRestart = ALPRestartWantsFastApply(restartState) && restartAge <= kALPRestartFlagValiditySeconds;

        %init(ThermalMonitor);
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, NULL, onSettingsChanged,
                (__bridge CFStringRef)S(kALPSettingsChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(center, NULL, onForegroundAppChanged,
                (__bridge CFStringRef)S(kALPForegroundAppNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        reloadState(NO);
        NSLog(@"[AppLowPower] thermalmonitord 调度已接入，急速套用:%d", g_fastApplyAfterRestart);
    }
}
