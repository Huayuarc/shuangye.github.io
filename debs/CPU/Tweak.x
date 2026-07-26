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
// 解除温控状态
// ============================================================================
static BOOL g_lp_thermalUnlockEnabled = NO;

// ── 保活定时器（3秒），周期重建 CommonProduct 引用 + 重新应用热模拟 ──
static dispatch_source_t g_lp_reapplyTimer = NULL;
static const int64_t kLP_ReapplyIntervalMs = 3000;

// ── 热压力覆盖定时器（2秒），强制系统热压力为 Nominal ──
static dispatch_source_t g_lp_pressureTimer = NULL;
static BOOL g_lp_pressureRunning = NO;
static const int64_t kLP_PressureIntervalMs = 2000;

// ── 前向声明 ──
static void lp_loadPrefs(void);
static void lp_applyThermalSimulation(void);
static void lp_applyPressureOverride(void);
static void lp_startPressureTimer(void);
static void lp_stopPressureTimer(void);
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

// ============================================================================
// 加载偏好设置
// ============================================================================
static void lp_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = lp_readPrefs() ?: @{};
        g_lp_thermalUnlockEnabled = [d[@"thermalUnlockEnabled"] boolValue];
        NSLog(@"[CPUthermal] prefs: thermalUnlockEnabled=%d",
              g_lp_thermalUnlockEnabled);
    }
}

// ============================================================================
// 核心：热模拟 — 通知 CommonProduct 保持 Nominal 状态
// 系统因此不会触发降频
// ============================================================================
static void lp_applyThermalSimulation(void) {
    if (!g_lp_commonProduct) {
        NSLog(@"[CPUthermal] CommonProduct 不可用，跳过热模拟");
        return;
    }

    @try {
        // 解除温控：模拟常温，系统不降频
        if ([g_lp_commonProduct respondsToSelector:@selector(setCPULevel:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_lp_commonProduct, @selector(setCPULevel:), 0);
        }
        // 设置 CPU 功率上限为 100（无上限）
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
    } @catch (NSException *e) {
        NSLog(@"[CPUthermal] 热模拟失败: %@", e);
    }
}

// ============================================================================
// 热压力覆盖 — 强制系统热压力为 Nominal
// 防止真实高温触发通知中心降频
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
    if (!g_lp_thermalUnlockEnabled) {
        return;
    }
    lp_applyThermalSimulation();
    lp_applyPressureOverride();
}

// ============================================================================
// 保活定时器（3 秒）
// 系统可能会重置 CommonProduct 状态，定时重新应用确保生效
// 同时也修复了重启用户空间后 CommonProduct 引用丢失的问题
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
            if (!g_lp_thermalUnlockEnabled) {
                return;
            }
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
// 启用解除温控：启动所有定时器并应用状态
// ============================================================================
static void lp_enable(void) {
    lp_applyState();
    lp_startPressureTimer();
    lp_startReapplyTimer();
    NSLog(@"[CPUthermal] 解除温控已启用");
}

// ============================================================================
// 禁用解除温控：停止所有定时器，恢复系统默认
// ============================================================================
static void lp_disable(void) {
    lp_stopPressureTimer();
    lp_stopReapplyTimer();
    // 恢复系统默认热状态：重置 CommonProduct
    if (g_lp_commonProduct) {
        @try {
            if ([g_lp_commonProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(g_lp_commonProduct,
                    @selector(putDeviceInThermalSimulationMode:), @"nominal");
            }
            if ([g_lp_commonProduct respondsToSelector:@selector(tryTakeAction)]) {
                ((void (*)(id, SEL))objc_msgSend)(g_lp_commonProduct, @selector(tryTakeAction));
            }
        } @catch (NSException *e) {
            NSLog(@"[CPUthermal] 恢复默认状态失败: %@", e);
        }
    }
    NSLog(@"[CPUthermal] 解除温控已禁用，已恢复系统默认");
}

// ============================================================================
// Darwin 通知回调 — 偏好设置变更
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
    if (g_lp_thermalUnlockEnabled) {
        lp_enable();
        NSLog(@"[CPUthermal] 切换 → 解除温控已启用");
    } else {
        lp_disable();
        NSLog(@"[CPUthermal] 切换 → 解除温控已禁用");
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
        if (g_lp_thermalUnlockEnabled) {
            lp_applyState();
            NSLog(@"[CPUthermal] 唤醒后已重新应用解除温控");
        }
    });
}

// ============================================================================
// %hook: CommonProduct — 初始化时注入 Helper 并应用模式
// ============================================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    lp_loadPrefs();
    if (g_lp_thermalUnlockEnabled) {
        lp_enable();
    }
    NSLog(@"[CPUthermal] CommonProduct initProduct: thermalUnlockEnabled=%d",
          g_lp_thermalUnlockEnabled);
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
            NSDictionary *patched = [CPUthermalHelper.shared patchThermalPlist:res];
            return patched;
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
        // ── 第1步：加载偏好 ──
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

        // ── 第3步：根据当前模式初始化状态 ──
        if (g_lp_thermalUnlockEnabled) {
            lp_enable();
            NSLog(@"[CPUthermal] 已激活 — 解除温控模式");
        } else {
            NSLog(@"[CPUthermal] 已激活 — 未启用 (默认系统温控)");
        }

        // ── 第4步：注册 Darwin 通知 ──
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

        // 偏好设置变更
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

        // ── 第5步：注册 notify.h 通知（CFNotification 的互补通道）──
        int token;
        notify_register_dispatch(kCPUthermalReloadNotifyName, &token,
            dispatch_get_main_queue(), ^(int t) {
            lp_onModeChanged(NULL, NULL, NULL, NULL, NULL);
        });

        NSLog(@"[CPUthermal] 初始化完成 — thermalUnlockEnabled=%d",
              g_lp_thermalUnlockEnabled);
    }
}
