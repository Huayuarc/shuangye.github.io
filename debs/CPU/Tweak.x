#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <IOKit/IOKitLib.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>
#import "CPUthermalHelper.h"

// ============================================================================
// notify.h 通知名（与 CPUthermalPrefs.m 同步）
// ============================================================================
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

// ============================================================================
// 动态查找 CommonProduct 实例（当 weak/strong 引用丢失时备用）
// ============================================================================
__attribute__((visibility("default"))) CommonProduct *g_lp_commonProduct = nil;

// ============================================================================
// 私有类声明（无对应 header 的类）
// ============================================================================
@interface ThermalControl : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (BOOL)powerSaveActive;
- (void)actionComponentControl;
- (void)readReleaseRateForAllComponents;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@protocol _CDBatterySaverProtocol <NSObject>
+ (id)batterySaver;
- (NSInteger)getPowerMode;
@end
@interface _CDBatterySaver : NSObject
+ (_CDBatterySaver *)batterySaver;
- (NSInteger)getPowerMode;
@end

// ============================================================================
// LowPower 状态
// ============================================================================
static BOOL g_lp_lowPowerActive = NO;
// 系统低功耗模式状态（从 _CDBatterySaver 读取）
static BOOL g_lp_systemLowPowerActive = NO;

typedef enum {
    LPFullPower = 0,
    LPLowPower  = 1
} LPPowerMode;

// 低功耗频率限制 — 70% 比例自动适应所有设备
static NSInteger g_lp_lowTargetMHz = 0;
// IOKit 频率钳位：下限 1500MHz，上限由低功耗目标动态决定
static const int64_t kLP_MinCapMHz = 1500;
// kLP_MaxCapMHz 在 lp_clampFreq 中动态计算 = g_lp_lowTargetMHz

// 定时器
static dispatch_source_t g_lp_timer = NULL;
// 200ms 保活間隔：更快速重新應用狀態，確保頻率立即生效
static const int64_t kLP_TimerIntervalMs = 200;

// 轮询定时器（回退：监控 plist 变化）
static dispatch_source_t g_lp_pollTimer = NULL;
static NSString *g_lp_lastPollMode = nil;

// 追踪已注册的功率控制器
static NSMutableArray *g_lp_controllers = nil;
static os_unfair_lock g_lp_lock = OS_UNFAIR_LOCK_INIT;

// 系统低功耗模式通知令牌（在所有进程中监听）
static int g_lpmNotifyToken = 0;

// 钩子状态
static int (*orig_IOServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

// ============================================================================
// LowPower 前向声明
// ============================================================================
static void lp_loadPrefs(void);
static BOOL lp_isLowPower(void);
static void lp_applyState(void);
static void lp_startTimer(void);
static void lp_stopTimer(void);
static void lp_startPollTimer(void);
static void lp_handleModeChange(void);
static void lp_forceDirectFrequencyCap(void);

// Helper 函数前向声明（在 Darwin 回调之前被调用）
static void CPUthermalSyncCommonProduct(void);
static void CPUthermalApplyMode(void);

// 系统低功耗模式
static BOOL lp_systemLowPowerActive(void);
static void lp_onSystemLowPowerChanged(void);

// ============================================================================
// LowPower 辅助函数
// ============================================================================

static NSString *lp_prefsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = rootlessPath(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist");
    });
    return path;
}

static NSDictionary *lp_readPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:lp_prefsPath()];
}

static NSInteger lp_nativeMaxMHz(void) {
    return CPUthermalNativeMaxPCoreFrequencyMHz();
}

static NSInteger lp_lowTargetMHz(void) {
    NSInteger nativeMax = lp_nativeMaxMHz();
    // 70% 比例，自动适应所有设备（A11~A17 Pro）
    // iPhone 8 (2390) → 1673 | iPhone 13 Pro (3230) → 2261 | 15 Pro Max (3780) → 2646
    NSInteger cap = nativeMax * 0.7;
    if (cap < 1500) cap = 1500;
    return cap;
}

static int64_t lp_freqMHzFromValue(int64_t value) {
    if (value >= 1000000000LL) return value / 1000000LL;
    if (value >= 1000000LL) return value / 1000LL;
    return value;
}

static int64_t lp_freqValFromMHz(int64_t mhz, int64_t orig) {
    if (orig >= 1000000000LL) return mhz * 1000000LL;
    if (orig >= 1000000LL) return mhz * 1000LL;
    return mhz;
}

static int64_t lp_clampFreq(int64_t value) {
    int64_t mhz = lp_freqMHzFromValue(value);
    if (mhz < kLP_MinCapMHz) mhz = kLP_MinCapMHz;
    // 上限动态使用低功耗目标频率，未激活时允许 2400
    int64_t maxMHz = g_lp_lowTargetMHz > 0 ? (int64_t)g_lp_lowTargetMHz : 2400;
    if (mhz > maxMHz) mhz = maxMHz;
    return lp_freqValFromMHz(mhz, value);
}

static void lp_trackController(id controller) {
    if (!controller) return;
    os_unfair_lock_lock(&g_lp_lock);
    if (!g_lp_controllers) g_lp_controllers = [NSMutableArray array];
    if (![g_lp_controllers containsObject:controller]) {
        [g_lp_controllers addObject:controller];
    }
    os_unfair_lock_unlock(&g_lp_lock);
}

// ============================================================================
// 加载偏好设置
// ============================================================================
static void lp_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = lp_readPrefs() ?: @{};
        NSString *mode = d[@"thermalPowerMode"] ?: @"off";
        g_lp_lowPowerActive = [mode isEqualToString:@"lowPower"];

        // 检测系统低功耗模式状态（供其它功能参考）
        g_lp_systemLowPowerActive = lp_systemLowPowerActive();

        g_lp_lowTargetMHz = lp_lowTargetMHz();
        NSLog(@"[LowPower] prefs: mode=%@ sysLPM=%d active=%d target=%ldMHz",
              mode, g_lp_systemLowPowerActive,
              g_lp_lowPowerActive, (long)g_lp_lowTargetMHz);
    }
}

static BOOL lp_isLowPower(void) {
    return g_lp_lowPowerActive;
}

// ============================================================================
// 系统低功耗模式检测（_CDBatterySaver）
// ============================================================================
static BOOL lp_systemLowPowerActive(void) {
    // 优先通过 _CDBatterySaver 检测（SpringBoard 进程可用）
    Class cls = objc_getClass("_CDBatterySaver");
    if (cls) {
        id saver = [cls batterySaver];
        if (saver) return [saver getPowerMode] != 0;
    }
    // 回退：通过系统 notify 状态检测（thermalmonitord 等进程）
    uint64_t state = 0;
    if (g_lpmNotifyToken) {
        notify_get_state(g_lpmNotifyToken, &state);
    }
    return state != 0;
}

static void lp_onSystemLowPowerChanged(void) {
    g_lp_systemLowPowerActive = lp_systemLowPowerActive();
    NSLog(@"[LowPower] 系统低功耗模式更新: %d", g_lp_systemLowPowerActive);
}

// ============================================================================
// 低电量模拟（让系统以为电量 20%，触发系统级省电）
// ============================================================================
static void lp_applyBatterySim(BOOL simulate) {
    @autoreleasepool {
        NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
        if (simulate) {
            prefs[@"enabled"] = @YES;
            prefs[@"cpuProtection"] = @YES;
            prefs[@"powerMode"] = @"lowPower";
        } else {
            prefs[@"enabled"] = @NO;
            prefs[@"cpuProtection"] = @NO;
            prefs[@"powerMode"] = @"fullPower";
        }
        int result = CPUthermalApplyThermalStatusOverridesFromPrefs(prefs);
        if (result == kSCStatusOK) {
            NSLog(@"[LowPower] 低电量模拟: %@", simulate ? @"ON (20%)" : @"OFF");
        } else {
            NSLog(@"[LowPower] 低电量模拟写入失败: %d", result);
        }
    }
}

// ============================================================================
// CommonProduct 低功耗状态
// ============================================================================
static void lp_applyLowPowerToCommonProduct(void) {
    if (!g_lp_commonProduct) return;
    @try {
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 2);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setCPUPowerCeiling:fromDecisionSource:), 85, @"LowPower");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct, @selector(putDeviceInThermalSimulationMode:), @"moderate");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
            ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(handleMCSThermalPressure)]) {
            ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(handleMCSThermalPressure));
        }
        NSLog(@"[LowPower] CommonProduct: CPULevel=2 Ceiling=85 moderate sim tryTakeAction");
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 失败: %@", e);
    }
}

static void lp_restoreCommonProduct(void) {
    if (!g_lp_commonProduct) return;
    @try {
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 0);
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct, @selector(setCPUPowerCeiling:fromDecisionSource:), 0, @"LowPower");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct, @selector(putDeviceInThermalSimulationMode:), @"nominal");
        }
        if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
            ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
        }
        NSLog(@"[LowPower] CommonProduct 恢复 (nominal)");
    } @catch (NSException *e) {
        NSLog(@"[LowPower] CommonProduct 恢复失败: %@", e);
    }
}

// ============================================================================
// 对 MitigationController 施加低功耗限制
// ============================================================================
static void lp_applyToController(id controller) {
    if (!controller || !lp_isLowPower()) return;
    @try {
        if ([controller respondsToSelector:@selector(setPowerSaveActive:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
        }
        BOOL tokenIsObject = NO;
        Method m = class_getInstanceMethod(object_getClass(controller), @selector(setPowerSaveToken:));
        if (m) {
            char type[4] = {0};
            method_getArgumentType(m, 2, type, sizeof(type));
            tokenIsObject = (type[0] == '@');
        }
        if ([controller respondsToSelector:@selector(setPowerSaveToken:)]) {
            if (tokenIsObject) {
                ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setPowerSaveToken:), @1);
            } else {
                ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setPowerSaveToken:), 1);
            }
        }
        if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), (int)g_lp_lowTargetMHz);
        }
        if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)]) {
            ((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller,
                @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:),
                (int)g_lp_lowTargetMHz, NO, YES);
        }
        if ([controller respondsToSelector:@selector(updateCPU)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updateCPU));
        }
        if ([controller respondsToSelector:@selector(updatePackage)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(updatePackage));
        }
        NSLog(@"[LowPower] 限制控制器: target=%ldMHz", (long)g_lp_lowTargetMHz);
    } @catch (NSException *e) {
        NSLog(@"[LowPower] 控制器限制失败: %@", e);
    }
}

static void lp_applyToAllControllers(void) {
    os_unfair_lock_lock(&g_lp_lock);
    NSArray *controllers = [g_lp_controllers copy];
    os_unfair_lock_unlock(&g_lp_lock);
    for (id c in controllers) {
        lp_applyToController(c);
    }
}

static void lp_restoreControllers(void) {
    os_unfair_lock_lock(&g_lp_lock);
    NSArray *controllers = [g_lp_controllers copy];
    os_unfair_lock_unlock(&g_lp_lock);

    for (id c in controllers) {
        @try {
            if ([c respondsToSelector:@selector(setPowerSaveActive:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(c, @selector(setPowerSaveActive:), NO);
            }
            if ([c respondsToSelector:@selector(updateCPU)]) {
                ((void (*)(id, SEL))objc_msgSend)(c, @selector(updateCPU));
            }
        } @catch (NSException *e) {
            NSLog(@"[LowPower] 恢复控制器失败: %@", e);
        }
    }
    NSLog(@"[LowPower] 控制器已恢复（保留 %lu 个引用）", (unsigned long)controllers.count);
}

// ============================================================================
// 直接 IOKit 頻率上限 — 繞過 thermalmonitord PID 循環，立即生效
// 直接向 AppleCLPCv2/AppleCLPC 等 IOKit 服務寫入硬性頻率上限，
// 讓 kernel 的 CPU 電源管理驅動立即限制 P-state
// ============================================================================
static void lp_forceDirectFrequencyCap(void) {
    if (!lp_isLowPower()) return;

    @autoreleasepool {
        int64_t targetHz = (int64_t)g_lp_lowTargetMHz * 1000000LL;
        int64_t minHz = (int64_t)kLP_MinCapMHz * 1000000LL;
        CFNumberRef maxFreq = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &targetHz);
        CFNumberRef minFreq = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &minHz);

        // 嘗試所有已知的 CPU 電源管理 IOKit 服務
        const char *serviceNames[] = {"AppleCLPCv2", "AppleCLPC", "AppleARMIODevice", NULL};
        for (int i = 0; serviceNames[i]; i++) {
            io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                IOServiceMatching(serviceNames[i]));
            if (service == IO_OBJECT_NULL) continue;

            // 直接通過原始 IOServiceSetProperty 設置 IORegistry 屬性
            // CLPC driver 會立即讀取這些屬性來限制 P-state
            orig_IOServiceSetProperty(service, CFSTR("clpc-cpu-max-frequency"), maxFreq);
            orig_IOServiceSetProperty(service, CFSTR("clpc-cpu-min-frequency"), minFreq);
            orig_IOServiceSetProperty(service, CFSTR("max-cpu-frequency"), maxFreq);

            IOObjectRelease(service);
        }

        // 備用：直接寫入 pmgr (Power Manager) 服務
        io_service_t pmgr = IOServiceGetMatchingService(kIOMasterPortDefault,
            IOServiceNameMatching("pmgr"));
        if (pmgr != IO_OBJECT_NULL) {
            orig_IOServiceSetProperty(pmgr, CFSTR("clpc-cpu-max-frequency"), maxFreq);
            orig_IOServiceSetProperty(pmgr, CFSTR("max-cpu-frequency"), maxFreq);
            IOObjectRelease(pmgr);
        }

        if (maxFreq) CFRelease(maxFreq);
        if (minFreq) CFRelease(minFreq);

        NSLog(@"[LowPower] 直接 IOKit 頻率上限: %ldMHz (min: %lldMHz)",
              (long)g_lp_lowTargetMHz, (long long)kLP_MinCapMHz);
    }
}

// ============================================================================
// 应用当前状态到所有层级
// ============================================================================
static void lp_applyState(void) {
    if (lp_isLowPower()) {
        lp_applyBatterySim(YES);
        lp_applyLowPowerToCommonProduct();
        lp_applyToAllControllers();
        // 直接 IOKit 頻率上限 — 繞過 thermalmonitord PID 循環，立即生效
        lp_forceDirectFrequencyCap();
    } else {
        lp_applyBatterySim(NO);
        lp_restoreCommonProduct();
        lp_restoreControllers();
    }
}

// ============================================================================
// 定时器 — 保活低功耗状态（系统会不断尝试恢复，需要定期覆盖）
// ============================================================================
static void lp_startTimer(void) {
    if (g_lp_timer) return;
    if (!lp_isLowPower()) return;

    g_lp_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLP_TimerIntervalMs * NSEC_PER_MSEC)),
        (uint64_t)(kLP_TimerIntervalMs * NSEC_PER_MSEC),
        (uint64_t)(20 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_timer, ^{
        @autoreleasepool {
            if (!lp_isLowPower()) {
                lp_stopTimer();
                return;
            }
            // 每次保活時重新同步 CommonProduct（防止引用過期）
            CPUthermalSyncCommonProduct();
            lp_applyBatterySim(YES);
            lp_applyLowPowerToCommonProduct();
            lp_applyToAllControllers();
            lp_forceDirectFrequencyCap();
        }
    });
    dispatch_resume(g_lp_timer);
    NSLog(@"[LowPower] 保活定时器已启动 (%.1fs)", (double)kLP_TimerIntervalMs / 1000.0);
}

static void lp_stopTimer(void) {
    if (g_lp_timer) {
        dispatch_source_cancel(g_lp_timer);
        g_lp_timer = NULL;
        NSLog(@"[LowPower] 保活定时器已停止");
    }
}

// ============================================================================
// 轮询定时器 — 检测 plist 变化（防 Darwin 通知丢失）
// ============================================================================
static void lp_handleModeChange(void) {
    lp_loadPrefs();
    NSString *currentMode = g_lp_lowPowerActive ? @"lowPower" : @"off";
    if (!g_lp_lastPollMode || ![g_lp_lastPollMode isEqualToString:currentMode]) {
        g_lp_lastPollMode = [currentMode copy];
        NSLog(@"[LowPower] 轮询检测到模式变化: %@", currentMode);
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
        } else {
            lp_stopTimer();
            lp_applyState();
        }
    }
}

static void lp_startPollTimer(void) {
    if (g_lp_pollTimer) return;
    g_lp_lastPollMode = g_lp_lowPowerActive ? @"lowPower" : @"off";

    g_lp_pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_pollTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        (uint64_t)(1.0 * NSEC_PER_SEC),
        (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_pollTimer, ^{
        @autoreleasepool {
            // 每次輪詢時重新同步 CommonProduct
            CPUthermalSyncCommonProduct();

            // 检测 plist 驱动的模式变化
            lp_handleModeChange();
            // 始终尝试重新应用低功耗状态（捕获延迟创建的控制器，确保生效）
            if (lp_isLowPower()) {
                lp_applyState();
                lp_startTimer();
            }
        }
    });
    dispatch_resume(g_lp_pollTimer);
    NSLog(@"[LowPower] 轮询定时器已启动 (1s)");
}

// ============================================================================
// IOKit IOServiceSetProperty Hook — 钳位 CPU 频率值
// ============================================================================
static int lp_hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (lp_isLowPower()) {
        NSString *ks = (__bridge NSString *)key;
        NSString *lower = [ks lowercaseString];
        BOOL isCPUKey = [lower containsString:@"cpu"] ||
                        [lower containsString:@"clpc"] ||
                        [lower containsString:@"ppm"] ||
                        [lower containsString:@"freq"] ||
                        [lower containsString:@"frequency"] ||
                        [lower containsString:@"lowpower"] ||
                        [lower containsString:@"target"] ||
                        [lower containsString:@"powerzone"] ||
                        [lower containsString:@"mitigat"];

        if (isCPUKey && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            int64_t numVal = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &numVal)) {
                int64_t clamped = lp_clampFreq(numVal);
                if (clamped != numVal) {
                    CFTypeRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &clamped);
                    kern_return_t ret = orig_IOServiceSetProperty(service, key, replacement);
                    if (replacement) CFRelease(replacement);
                    return ret;
                }
            }
        }
    }
    return orig_IOServiceSetProperty(service, key, value);
}

// ============================================================================
// Darwin 通知回调 — 低功耗模式切换
// ============================================================================
static void lp_onModeChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    // 路徑A: CPUthermalHelper/CommonProduct 模擬模式
    // 先強制重新同步 CommonProduct（確保引用有效）
    CPUthermalSyncCommonProduct();
    CPUthermalApplyMode();

    // 路徑B: LowPower 狀態機（hook 覆蓋、電量模擬、保活定時器）
    lp_loadPrefs();
    g_lp_lastPollMode = g_lp_lowPowerActive ? @"lowPower" : @"off";
    if (lp_isLowPower()) {
        lp_applyState();
        lp_startTimer();
    } else {
        lp_stopTimer();
        lp_applyState();
    }

    // 通知完成
    NSLog(@"[LowPower] 模式切換: %@ — 目標頻率:%ldMHz",
          lp_isLowPower() ? @"低功耗" : @"解除溫控",
          (long)g_lp_lowTargetMHz);
}

static void lp_onWakeEvent(CFNotificationCenterRef center, void *observer,
                            CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 睡醒后同步 CommonProduct 引用（可能已被系统重置）
        CPUthermalSyncCommonProduct();
        lp_loadPrefs();
        if (lp_isLowPower()) {
            CPUthermalApplyMode();
            lp_applyState();
            lp_startTimer();
            NSLog(@"[LowPower] 唤醒后重新激活低功耗模式");
        }
    });
}

// ============================================================================
// %hook: MitigationController — CPU 功率目标控制
// ============================================================================
%hook MitigationController

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) lp_trackController(res);
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (lp_isLowPower()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(int)token {
    if (lp_isLowPower()) { %orig(1); return; }
    %orig;
}

- (BOOL)powerSaveActive {
    if (lp_isLowPower()) return YES;
    return %orig;
}

- (void)setCPULowPowerTarget:(int)target {
    if (lp_isLowPower()) { %orig((int)g_lp_lowTargetMHz); return; }
    %orig;
}

- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property {
    if (lp_isLowPower()) { %orig((int)lp_clampFreq(target), legacy, property); return; }
    %orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source {
    if (lp_isLowPower()) { %orig(85, source); return; }
    %orig;
}

- (void)setCPUPowerZoneTarget:(int)target {
    if (lp_isLowPower()) { %orig((int)lp_clampFreq(target)); return; }
    %orig;
}

%end

// ============================================================================
// %hook: SpringBoard — 系统低功耗模式切换检测
// ============================================================================
%hook SpringBoard

- (void)_batterySaverModeChanged:(NSInteger)arg1 {
    %orig(arg1);
    lp_onSystemLowPowerChanged();
}

%end

// ============================================================================
// %hook: ThermalControl — 省电状态
// ============================================================================
%hook ThermalControl

- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id res = %orig(fastLoop, noDisplay, saveParams, zoneParams);
    if (res) lp_trackController(res);
    return res;
}

- (id)initWithParams:(id)params {
    id res = %orig(params);
    if (res) lp_trackController(res);
    return res;
}

- (void)setPowerSaveActive:(BOOL)active {
    if (lp_isLowPower()) { %orig(YES); return; }
    %orig;
}

- (void)setPowerSaveToken:(id)token {
    if (lp_isLowPower()) { %orig([NSNumber numberWithInt:1]); return; }
    %orig;
}

- (BOOL)powerSaveActive {
    if (lp_isLowPower()) return YES;
    return %orig;
}

%end

// ============================================================================
// %hook: ApplePPMCPU — CPU P-state 限制
// ============================================================================
%hook ApplePPMCPU

- (void)setCPULevel:(int)level {
    if (lp_isLowPower()) {
        if (level < 0) level = 0;
        if (level > 2) level = 2;
        %orig(level);
        return;
    }
    %orig;
}

%end

// ============================================================================
// Helper: Tweak 公共产品查找与同步
// ============================================================================
static CommonProduct *CPUthermalFindCommonProduct(void) {
    Class cpClass = objc_getClass("CommonProduct");
    if (!cpClass) return nil;

    SEL sharedSel = @selector(sharedInstance);
    if ([cpClass respondsToSelector:sharedSel]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
        if (instance) return instance;
    }
    sharedSel = @selector(sharedProduct);
    if ([cpClass respondsToSelector:sharedSel]) {
        id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
        if (instance) return instance;
    }
    return nil;
}

static void CPUthermalSyncCommonProduct(void) {
    if (g_lp_commonProduct) return;
    CommonProduct *cp = CPUthermalFindCommonProduct();
    if (cp) {
        CPUthermalHelper.shared.commonProductObject = cp;
        g_lp_commonProduct = cp;
        NSLog(@"[CPUthermal] 动态获取 CommonProduct: %@", cp);
    }
}

// ============================================================================
// Helper: 根据当前偏好设置 thermalmonitord 的工作模式
// ============================================================================
static void CPUthermalApplyMode(void) {
    CPUthermalHelper *helper = CPUthermalHelper.shared;
    [helper reloadPrefs];

    CPUthermalSyncCommonProduct();

    if (!helper.commonProductObject) {
        NSLog(@"[CPUthermal] commonProductObject 为空，LowPower 状态机将接管降频");
        return;
    }

    if ([helper.thermalPowerMode isEqualToString:@"lowPower"]) {
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"moderate"];
        NSLog(@"[CPUthermal] 模式: 低功耗 (moderate)");
    } else {
        [helper.commonProductObject putDeviceInThermalSimulationMode:@"nominal"];
        NSLog(@"[CPUthermal] 模式: 解除温控 (nominal)");
    }

    if ([helper.commonProductObject respondsToSelector:@selector(tryTakeAction)]) {
        [helper.commonProductObject tryTakeAction];
    }
    if ([helper.commonProductObject respondsToSelector:@selector(handleMCSThermalPressure)]) {
        [helper.commonProductObject handleMCSThermalPressure];
    }
}

// ============================================================================
// Darwin 通知回调 — puppet event
// ============================================================================
static void puppetEventCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [CPUthermalHelper.shared executePuppetEvent];
}

// ============================================================================
// %hook: CommonProduct — 初始化时注入 Helper 并应用模式
// ============================================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    CPUthermalApplyMode();
    return res;
}

%end

// ============================================================================
// %hook: NSDictionary — 修补温控配置文件（防温控暗屏）
// ============================================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig(path);
    if ([path containsString:@"/System/Library/ThermalMonitor/"]) {
        if ([res isKindOfClass:[NSDictionary class]]) {
            CFDictionaryRef patched = [CPUthermalHelper.shared patchThermalPlist:(__bridge CFDictionaryRef)res];
            return (__bridge id)patched;
        }
    }
    return res;
}

%end

// ============================================================================
// %ctor — 构造函数（合并 LowPowerHooks 与 Tweak 初始化逻辑）
// ============================================================================
%ctor {
    @autoreleasepool {

        // ── 第1步：加载低功耗偏好 ──
        lp_loadPrefs();

        // ── 第2步：安装 IOKit IOServiceSetProperty hook ──
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            void *sspPtr = dlsym(iokit, "IOServiceSetProperty");
            if (sspPtr) {
                MSHookFunction(sspPtr, (void *)lp_hooked_IOServiceSetProperty, (void **)&orig_IOServiceSetProperty);
                NSLog(@"[LowPower] IOServiceSetProperty hook 已安装");
            }
        }

        // ── 第3步：尝试获取已有的 CommonProduct 实例 ──
        if (!g_lp_commonProduct) {
            Class cpClass = objc_getClass("CommonProduct");
            if (cpClass) {
                SEL sharedSel = @selector(sharedProduct);
                if ([cpClass respondsToSelector:sharedSel]) {
                    id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
                    if (instance) {
                        g_lp_commonProduct = instance;
                        Class helperClass = objc_getClass("CPUthermalHelper");
                        if (helperClass) {
                            SEL sharedHelperSel = @selector(shared);
                            id helper = ((id (*)(id, SEL))objc_msgSend)(helperClass, sharedHelperSel);
                            if (helper) {
                                SEL setCPSel = @selector(setCommonProductObject:);
                                ((void (*)(id, SEL, id))objc_msgSend)(helper, setCPSel, instance);
                            }
                        }
                        NSLog(@"[LowPower] 获取到已有 CommonProduct: %@", instance);
                    }
                }
            }
        }

        // ── 第4步：注册系统低功耗模式通知（所有进程均可接收） ──
        notify_register_dispatch("com.apple.system.batterysaver.mode",
            &g_lpmNotifyToken, dispatch_get_main_queue(), ^(int t) {
            lp_onSystemLowPowerChanged();
        });
        // 读取当前 LPM 状态（初始化 g_lp_systemLowPowerActive）
        {
            uint64_t state = 0;
            notify_get_state(g_lpmNotifyToken, &state);
            g_lp_systemLowPowerActive = (state != 0);
            NSLog(@"[LowPower] 系统低功耗模式注册完成，当前状态: %d", g_lp_systemLowPowerActive);
        }

        // ── 第5步：如果当前是低功耗模式，立即应用状态并启动定时器 ──
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startTimer();
            NSLog(@"[LowPower] 已激活 — 目标频率:%ldMHz 保活:%dms",
                  (long)g_lp_lowTargetMHz, (int)kLP_TimerIntervalMs);
        } else {
            NSLog(@"[LowPower] 待命中（可在运行时切换激活）");
        }

        // ── 第6步：启动轮询定时器（每秒检测 plist 变化） ──
        lp_startPollTimer();

        // ── 第7步：注册 Darwin 通知 ──
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

        // 低功耗模式切换（单入口：合并 CPUthermalHelper + LowPower 状态机）
        CFNotificationCenterAddObserver(nc, NULL, lp_onModeChanged,
            CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // Puppet event
        CFNotificationCenterAddObserver(nc, NULL, puppetEventCallback,
            CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 屏幕唤醒事件（睡醒后重新应用低功耗状态）
        CFNotificationCenterAddObserver(nc, NULL, lp_onWakeEvent,
            CFSTR("com.apple.springboard.hasFinishedUnblankingScreen"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(nc, NULL, lp_onWakeEvent,
            CFSTR("com.apple.springboard.lockstate"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // ── 第8步：注册 notify.h 通知（CFNotification 的互补通道） ──
        int token;
        notify_register_dispatch(kCPUthermalReloadNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            // 使用与 CFNotification 相同的统一入口
            lp_onModeChanged(NULL, NULL, NULL, NULL, NULL);
        });

    } // @autoreleasepool
}
