#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <CPUthermalPaths.h>
#include <CPUthermalThermalPrefs.h>
#include <CPUthermalPressure.h>
#import "CPUthermalHelper.h"

// ============================================================================
// notify.h 通知名（与 CPUthermalPrefs.m 同步）
// ============================================================================
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

// ============================================================================
// CommonProduct 实例引用
// ============================================================================
__attribute__((visibility("default"))) CommonProduct *g_lp_commonProduct = nil;

// ============================================================================
// 私有类声明
// ============================================================================
@interface ThermalControl : NSObject
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(id)token;
- (BOOL)powerSaveActive;
@end

@interface _CDBatterySaver : NSObject
+ (_CDBatterySaver *)batterySaver;
- (NSInteger)getPowerMode;
@end

// ============================================================================
// LowPower 状态
// ============================================================================
static BOOL g_lp_lowPowerActive = NO;
// 系统低功耗模式状态（仅信息参考，不再用于电池模拟）
static BOOL g_lp_systemLowPowerActive = NO;

// 低功耗频率上限：70% of native max
static NSInteger g_lp_lowTargetMHz = 0;
static const int64_t kLP_MinCapMHz = 1500;

// ── 保活定时器（单一定时器，不再分 200ms + 1s）──
static dispatch_source_t g_lp_reapplyTimer = NULL;
static const int64_t kLP_ReapplyIntervalMs = 3000; // 3秒

// ── 热压力覆盖定时器（仅解除温控模式使用）──
static dispatch_source_t g_lp_pressureTimer = NULL;
static BOOL g_lp_pressureRunning = NO;
static const int64_t kLP_PressureIntervalMs = 2000; // 2秒

// ── 系统低功耗模式通知令牌 ──
static int g_lpmNotifyToken = 0;

// ── 前向声明 ──
static void lp_loadPrefs(void);
static BOOL lp_isLowPower(void);
static void lp_applyState(void);
static void lp_startReapplyTimer(void);
static void lp_stopReapplyTimer(void);

// ============================================================================
// 辅助函数
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

// 计算 70% 频率上限，自动适应所有设备
static NSInteger lp_lowTargetMHz(void) {
    NSInteger nativeMax = lp_nativeMaxMHz();
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

// 频率钳位（仅用于 MitigationController 钩子中覆写值）
static int64_t lp_clampFreq(int64_t value) {
    int64_t mhz = lp_freqMHzFromValue(value);
    if (mhz < kLP_MinCapMHz) mhz = kLP_MinCapMHz;
    int64_t maxMHz = g_lp_lowTargetMHz > 0 ? (int64_t)g_lp_lowTargetMHz : 2400;
    if (mhz > maxMHz) mhz = maxMHz;
    return lp_freqValFromMHz(mhz, value);
}

// ============================================================================
// 加载偏好设置
// ============================================================================
static void lp_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = lp_readPrefs() ?: @{};
        NSString *mode = d[@"thermalPowerMode"] ?: @"off";
        g_lp_lowPowerActive = [mode isEqualToString:@"lowPower"];
        g_lp_systemLowPowerActive = NO;
        {
            uint64_t state = 0;
            if (g_lpmNotifyToken) {
                notify_get_state(g_lpmNotifyToken, &state);
                g_lp_systemLowPowerActive = (state != 0);
            }
        }
        g_lp_lowTargetMHz = lp_lowTargetMHz();
        NSLog(@"[CPUthermal] prefs: mode=%@ sysLPM=%d active=%d target=%ldMHz",
              mode, g_lp_systemLowPowerActive,
              g_lp_lowPowerActive, (long)g_lp_lowTargetMHz);
    }
}

static BOOL lp_isLowPower(void) {
    return g_lp_lowPowerActive;
}

// ============================================================================
// 核心：热模拟静态降频 — 唯一降频手段
//
// 低功耗   → CommonProduct 模拟 moderate 热状态，系统自动降频
// 解除温控 → CommonProduct 模拟 nominal，同时强制热压力 Nominal 防真实高温降频
// ============================================================================
static void lp_applyThermalSimulation(BOOL lowPower) {
    if (!g_lp_commonProduct) {
        NSLog(@"[CPUthermal] CommonProduct 不可用，跳过热模拟");
        return;
    }

    @try {
        if (lowPower) {
            // ── 低功耗模式：模拟中温 → 系统自动降频 ──
            if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
                ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 2);
            }
            if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct,
                    @selector(putDeviceInThermalSimulationMode:), @"moderate");
            }
            if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
                ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
            }
            if ([g_lp_commonProduct respondsToSelector:@selector(handleMCSThermalPressure)]) {
                ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(handleMCSThermalPressure));
            }
            NSLog(@"[CPUthermal] 低功耗: 热模拟 moderate, CPULevel=2");
        } else {
            // ── 解除温控模式：模拟常温，系统不降频 ──
            if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
                ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 0);
            }
            // 注意：setCPUPowerCeiling 传 100 表示"无上限"，避免 0 被误解为"零功率"
            if ([g_lp_commonProduct respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)]) {
                ((void (*)(id, SEL, int, id))objc_msgSend)(g_lp_commonProduct,
                    @selector(setCPUPowerCeiling:fromDecisionSource:), 100, @"CPUthermal");
            }
            if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct,
                    @selector(putDeviceInThermalSimulationMode:), @"nominal");
            }
            if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
                ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
            }
            NSLog(@"[CPUthermal] 解除温控: 热模拟 nominal, CPULevel=0, Ceiling=100");
        }
    } @catch (NSException *e) {
        NSLog(@"[CPUthermal] 热模拟失败: %@", e);
    }
}

// ============================================================================
// 热压力覆盖 — 仅解除温控模式使用
// 强制系统热压力为 Nominal，防止真实高温触发降频
// ============================================================================
static void lp_applyPressureOverride(void) {
    int ret = CPUthermalForceNominalPressure();
    CPUthermalForceNormalNotifLevel();
    if (ret != 0 && ret != 2) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSLog(@"[CPUthermal] 强制 Nominal 压力失败: %d", ret);
        });
    }
}

static void lp_startPressureTimer(void) {
    if (g_lp_pressureTimer) return;
    g_lp_pressureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_pressureTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLP_PressureIntervalMs * NSEC_PER_MSEC)),
        (uint64_t)(kLP_PressureIntervalMs * NSEC_PER_MSEC),
        (uint64_t)(100 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_pressureTimer, ^{
        @autoreleasepool {
            if (!g_lp_pressureRunning) {
                dispatch_source_cancel(g_lp_pressureTimer);
                g_lp_pressureTimer = NULL;
                return;
            }
            lp_applyPressureOverride();
        }
    });
    dispatch_resume(g_lp_pressureTimer);
    g_lp_pressureRunning = YES;
    NSLog(@"[CPUthermal] 压力覆盖定时器已启动 (%.1fs)", (double)kLP_PressureIntervalMs / 1000.0);
}

static void lp_stopPressureTimer(void) {
    if (g_lp_pressureTimer) {
        dispatch_source_cancel(g_lp_pressureTimer);
        g_lp_pressureTimer = NULL;
    }
    g_lp_pressureRunning = NO;
    NSLog(@"[CPUthermal] 压力覆盖定时器已停止");
}

// ============================================================================
// 应用当前状态到所有层级
// ============================================================================
static void lp_applyState(void) {
    if (lp_isLowPower()) {
        // 低功耗: 启动热模拟（moderate），停止压力覆盖（让 moderate 生效）
        lp_stopPressureTimer();
        lp_applyThermalSimulation(YES);
    } else {
        // 解除温控: 停止热模拟（nominal），启动压力覆盖（防真实高温）
        lp_applyThermalSimulation(NO);
        lp_applyPressureOverride();
        lp_startPressureTimer();
    }
}

// ============================================================================
// 保活定时器（单一 3 秒）
// 系统可能会重置 CommonProduct 状态，定时重新应用确保生效
// ============================================================================
static void lp_startReapplyTimer(void) {
    if (g_lp_reapplyTimer) return;

    g_lp_reapplyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_reapplyTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLP_ReapplyIntervalMs * NSEC_PER_MSEC)),
        (uint64_t)(kLP_ReapplyIntervalMs * NSEC_PER_MSEC),
        (uint64_t)(200 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_reapplyTimer, ^{
        @autoreleasepool {
            // 每次保活时重建 CommonProduct 引用
            Class cpClass = objc_getClass("CommonProduct");
            if (cpClass) {
                id instance = nil;
                if ([cpClass respondsToSelector:@selector(sharedProduct)]) {
                    instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, @selector(sharedProduct));
                }
                if (!instance && [cpClass respondsToSelector:@selector(sharedInstance)]) {
                    instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, @selector(sharedInstance));
                }
                if (instance) {
                    g_lp_commonProduct = instance;
                    CPUthermalHelper.shared.commonProductObject = instance;
                }
            }
            lp_applyState();
        }
    });
    dispatch_resume(g_lp_reapplyTimer);
    NSLog(@"[CPUthermal] 保活定时器已启动 (%.1fs)", (double)kLP_ReapplyIntervalMs / 1000.0);
}

static void lp_stopReapplyTimer(void) {
    if (g_lp_reapplyTimer) {
        dispatch_source_cancel(g_lp_reapplyTimer);
        g_lp_reapplyTimer = NULL;
        NSLog(@"[CPUthermal] 保活定时器已停止");
    }
}

// ============================================================================
// Darwin 通知回调 — 模式切换
// ============================================================================
static void lp_onModeChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object,
                              CFDictionaryRef userInfo) {
    // 重新加载 CommonProduct 引用
    Class cpClass = objc_getClass("CommonProduct");
    if (cpClass) {
        id instance = nil;
        if ([cpClass respondsToSelector:@selector(sharedProduct)]) {
            instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, @selector(sharedProduct));
        }
        if (!instance && [cpClass respondsToSelector:@selector(sharedInstance)]) {
            instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, @selector(sharedInstance));
        }
        if (instance) {
            g_lp_commonProduct = instance;
            CPUthermalHelper.shared.commonProductObject = instance;
        }
    }

    lp_loadPrefs();
    if (lp_isLowPower()) {
        lp_startReapplyTimer();
        lp_applyState();
        NSLog(@"[CPUthermal] 模式切换 → 低功耗 (目标频率:%ldMHz)", (long)g_lp_lowTargetMHz);
    } else {
        lp_stopReapplyTimer();
        lp_applyState();
        NSLog(@"[CPUthermal] 模式切换 → 解除温控");
    }
}

static void lp_onWakeEvent(CFNotificationCenterRef center, void *observer,
                            CFNotificationName name, const void *object,
                            CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 唤醒后重建 CommonProduct 引用
        Class cpClass = objc_getClass("CommonProduct");
        if (cpClass) {
            id instance = nil;
            if ([cpClass respondsToSelector:@selector(sharedProduct)]) {
                instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, @selector(sharedProduct));
            }
            if (!instance && [cpClass respondsToSelector:@selector(sharedInstance)]) {
                instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, @selector(sharedInstance));
            }
            if (instance) {
                g_lp_commonProduct = instance;
                CPUthermalHelper.shared.commonProductObject = instance;
            }
        }
        lp_loadPrefs();
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startReapplyTimer();
        } else {
            lp_applyState();
        }
        NSLog(@"[CPUthermal] 唤醒后已重新应用模式");
    });
}

// ============================================================================
// %hook: MitigationController — CPU 功率目标控制
// ============================================================================
%hook MitigationController

// 初始化时自动追踪（不再需要显式追踪数组，仅用于组件注册）
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay
     powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    return %orig(fastLoop, noDisplay, saveParams, zoneParams);
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
// %hook: ThermalControl — 省电状态
// ============================================================================
%hook ThermalControl

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
// %hook: SpringBoard — 系统低功耗模式检测
// ============================================================================
%hook SpringBoard

- (void)_batterySaverModeChanged:(NSInteger)arg1 {
    %orig(arg1);
    // 仅记录状态变化，不再参与电池模拟
    uint64_t state = 0;
    if (g_lpmNotifyToken) {
        notify_get_state(g_lpmNotifyToken, &state);
    }
    g_lp_systemLowPowerActive = (state != 0);
    NSLog(@"[CPUthermal] 系统低功耗模式: %d", g_lp_systemLowPowerActive);
}

%end

// ============================================================================
// %hook: CommonProduct — 初始化时注入 Helper 并应用模式
// ============================================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    lp_loadPrefs();
    if (lp_isLowPower()) {
        lp_applyState();
        lp_startReapplyTimer();
    } else {
        lp_applyState();
    }
    NSLog(@"[CPUthermal] CommonProduct initProduct: mode=%@",
          lp_isLowPower() ? @"低功耗" : @"解除温控");
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
// %ctor — 构造函数
// ============================================================================
%ctor {
    @autoreleasepool {
        // ── 第1步：加载低功耗偏好 ──
        lp_loadPrefs();

        // ── 第2步：尝试获取已有的 CommonProduct 实例 ──
        Class cpClass = objc_getClass("CommonProduct");
        if (cpClass) {
            SEL sharedSel = @selector(sharedProduct);
            if ([cpClass respondsToSelector:sharedSel]) {
                id instance = ((id (*)(id, SEL))objc_msgSend)(cpClass, sharedSel);
                if (instance) {
                    g_lp_commonProduct = instance;
                    CPUthermalHelper.shared.commonProductObject = instance;
                    NSLog(@"[CPUthermal] 获取到已有 CommonProduct: %@", instance);
                }
            }
        }

        // ── 第3步：注册系统低功耗模式通知 ──
        notify_register_dispatch("com.apple.system.batterysaver.mode",
            &g_lpmNotifyToken, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            notify_get_state(g_lpmNotifyToken, &state);
            g_lp_systemLowPowerActive = (state != 0);
            NSLog(@"[CPUthermal] 系统低功耗模式变化: %d", g_lp_systemLowPowerActive);
        });
        {
            uint64_t state = 0;
            notify_get_state(g_lpmNotifyToken, &state);
            g_lp_systemLowPowerActive = (state != 0);
        }

        // ── 第4步：根据当前模式初始化状态 ──
        if (lp_isLowPower()) {
            lp_applyState();
            lp_startReapplyTimer();
            NSLog(@"[CPUthermal] 已激活 — 低功耗模式 (目标频率:%ldMHz)",
                  (long)g_lp_lowTargetMHz);
        } else {
            lp_applyState();
            NSLog(@"[CPUthermal] 已激活 — 解除温控模式 (压力覆盖已启动)");
        }

        // ── 第5步：注册 Darwin 通知 ──
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

        // 模式切换
        CFNotificationCenterAddObserver(nc, NULL, lp_onModeChanged,
            CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 屏幕唤醒事件
        CFNotificationCenterAddObserver(nc, NULL, lp_onWakeEvent,
            CFSTR("com.apple.springboard.hasFinishedUnblankingScreen"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(nc, NULL, lp_onWakeEvent,
            CFSTR("com.apple.springboard.lockstate"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // ── 第6步：注册 notify.h 通知（CFNotification 的互补通道）──
        int token;
        notify_register_dispatch(kCPUthermalReloadNotifyName, &token,
            dispatch_get_main_queue(), ^(int t) {
            lp_onModeChanged(NULL, NULL, NULL, NULL, NULL);
        });

        NSLog(@"[CPUthermal] 初始化完成 — 模式:%@ 目标频率:%ldMHz",
              lp_isLowPower() ? @"低功耗" : @"解除温控",
              (long)g_lp_lowTargetMHz);
    }
}
