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
// CommonProduct 实例引用（全局可见，供其他文件使用）
// ============================================================================
__attribute__((visibility("default"))) CommonProduct *g_lp_commonProduct = nil;

// ── 保活定时器（3秒），周期重建 CommonProduct 引用 + 重新应用热模拟 ──
static dispatch_source_t g_lp_reapplyTimer = NULL;
static const int64_t kLP_ReapplyIntervalMs = 3000;

// ── 热压力覆盖定时器（2秒），强制系统热压力为 Nominal ──
static dispatch_source_t g_lp_pressureTimer = NULL;
static const int64_t kLP_PressureIntervalMs = 2000;

// ── 前向声明 ──
static void lp_applyThermalSimulation(void);
static void lp_applyPressureOverride(void);
static void lp_refreshCommonProduct(void);

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

// ============================================================================
// 刷新 CommonProduct 引用
// ============================================================================
static void lp_refreshCommonProduct(void) {
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
}

// ============================================================================
// 应用当前状态到所有层级（无条件强制执行）
// ============================================================================
static void lp_applyState(void) {
    lp_applyThermalSimulation();
    lp_applyPressureOverride();
}

// ============================================================================
// 压力覆盖定时器（永远运行，不受开关影响）
// ============================================================================
static void lp_startPressureTimer(void) {
    if (g_lp_pressureTimer) return;
    g_lp_pressureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_lp_pressureTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLP_PressureIntervalMs * NSEC_PER_MSEC)),
        (uint64_t)(kLP_PressureIntervalMs * NSEC_PER_MSEC),
        (uint64_t)(100 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_lp_pressureTimer, ^{
        @autoreleasepool {
            lp_applyPressureOverride();
        }
    });
    dispatch_resume(g_lp_pressureTimer);
    NSLog(@"[CPUthermal] 压力覆盖定时器已启动 (%.1fs 周期)", (double)kLP_PressureIntervalMs / 1000.0);
}

// ============================================================================
// 保活定时器（永远运行，不受开关影响）
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
            lp_refreshCommonProduct();
            lp_applyState();
        }
    });
    dispatch_resume(g_lp_reapplyTimer);
    NSLog(@"[CPUthermal] 保活定时器已启动 (%.1fs 周期)", (double)kLP_ReapplyIntervalMs / 1000.0);
}

// ============================================================================
// Darwin 通知回调 — 偏好设置变更
// 仅刷新 CommonProduct 引用并重新应用，不受任何开关影响
// ============================================================================
static void lp_onModeChanged(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object,
                              CFDictionaryRef userInfo) {
    lp_refreshCommonProduct();
    lp_applyState();
    NSLog(@"[CPUthermal] 设置变更后已重新强制 Nominal 压力");
}

static void lp_onWakeEvent(CFNotificationCenterRef center, void *observer,
                            CFNotificationName name, const void *object,
                            CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        lp_refreshCommonProduct();
        lp_applyState();
        NSLog(@"[CPUthermal] 唤醒后已重新强制 Nominal 压力");
    });
}

// ============================================================================
// %hook: CommonProduct — 初始化时注入 Helper 并应用 Nominal
// ============================================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    g_lp_commonProduct = self;
    lp_applyState();
    NSLog(@"[CPUthermal] CommonProduct initProduct: 已强制 Nominal 压力");
    return res;
}

%end

// ============================================================================
// %hook: NSDictionary — 修补温控配置文件（防温控暗屏）
// 此功能仍受面板开关控制，由 CPUthermalHelper 内部判断
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
        // ── 第1步：尝试获取已有的 CommonProduct 实例 ──
        lp_refreshCommonProduct();

        // ── 第2步：立即应用强制 Nominal ──
        lp_applyState();

        // ── 第3步：启动所有定时器（永远运行，不受任何开关影响）──
        lp_startPressureTimer();
        lp_startReapplyTimer();
        NSLog(@"[CPUthermal] 强制 Nominal 压力已激活 — 不受面板开关影响");

        // ── 第4步：注册 Darwin 通知 ──
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();

        // 偏好设置变更（仅刷新引用，不改变强制行为）
        CFNotificationCenterAddObserver(nc, NULL, lp_onModeChanged,
            CFSTR("com.huayuarc.cputhermal.reloadPrefs"),
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

        NSLog(@"[CPUthermal] 初始化完成 — 强制热压力为 Nominal（硬编码）");
    }
}
