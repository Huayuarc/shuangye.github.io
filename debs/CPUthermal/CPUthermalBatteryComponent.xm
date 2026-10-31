// CPUthermal 部件与服务历史 / 电池维修提示深度屏蔽
// Hook 清单来自已实证的 NoAppleMobileRepair 分析（Unicorn 仿真解出）：
//   BatteryUIResourceClass  —— Preferences / BatteryUsageUI 电池状态数据源
//   BatteryUIController      —— 设置 > 电池 页面控制器
//   SBIconController         —— SpringBoard 角标（"1" / Important Battery Message）
// 只改变 UI 呈现，不写入电池健康数据、不改变硬件保护。
//
// isolation.23 注：不再猜测 SetupAssistant / backboardd / SNDeviceBatteryInfo 等未经
// 实证的类名——无依据的 %hook 会在类缺失时静默失效，反而掩盖真实问题。

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <CPUthermalPaths.h>

static BOOL gCPUthermalComponentSuppressed = NO;
static int gCPUthermalComponentToken = -1;

static BOOL CPUthermalComponentSuppressionEnabled(void) {
    return __atomic_load_n(&gCPUthermalComponentSuppressed, __ATOMIC_ACQUIRE);
}

static void CPUthermalReloadComponentSuppression(void) {
    @autoreleasepool {
        id value = CPUthermalReadPrefsSnapshot()[S("suppressComponentWarning")];
        BOOL enabled = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
        // 兼容旧键：隐藏电池维修提示开启时同样抑制部件提示
        if (!enabled) {
            id legacy = CPUthermalReadPrefsSnapshot()[S("suppressBatteryServiceWarnings")];
            enabled = [legacy respondsToSelector:@selector(boolValue)] ? [legacy boolValue] : NO;
        }
        __atomic_store_n(&gCPUthermalComponentSuppressed, enabled, __ATOMIC_RELEASE);
    }
}

static dispatch_queue_t CPUthermalComponentQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huayuarc.cputhermal.component", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// 判定一个 specifier / group item 是否代表"电池未知部件 / 重要电池信息"提示行。
// 只按可见文本匹配，命中才过滤，避免误伤正常行。
static BOOL CPUthermalIsBatteryWarningItem(id item) {
    if (!item) return NO;
    NSString *label = nil;
    NSString *detail = nil;
    @try {
        if ([item respondsToSelector:@selector(label)]) label = [item performSelector:@selector(label)];
        if ([item respondsToSelector:@selector(name)]) {
            NSString *n = [item performSelector:@selector(name)];
            if (!label.length) label = n;
        }
        if ([item respondsToSelector:@selector(detailText)]) detail = [item performSelector:@selector(detailText)];
    } @catch (...) {
        return NO;
    }
    for (NSString *s in @[ label ?: S(""), detail ?: S("") ]) {
        if ([s containsString:S("未知部件")] || [s containsString:S("Unknown Part")] ||
            [s containsString:S("Important Battery Message")] || [s containsString:S("重要电池信息")] ||
            [s containsString:S("电池维修")] || [s containsString:S("Battery Service")]) return YES;
    }
    return NO;
}

%group CPUthermalComponentHooks

// ===== Preferences / BatteryUsageUI：电池状态数据源 =====
%hook BatteryUIResourceClass

+ (int)getBatteryHealthServiceState {
    if (CPUthermalComponentSuppressionEnabled()) return 0;
    return %orig;
}

+ (int)genuineBatteryStatus {
    if (CPUthermalComponentSuppressionEnabled()) return 1;
    return %orig;
}

+ (int)getManagementState {
    if (CPUthermalComponentSuppressionEnabled()) return 2;
    return %orig;
}

%end

// 设置 > 电池：服务建议（驱动"重要电池信息"红字入口）
%hook BatteryUIController

- (id)getBatteryServiceSuggestion:(uintptr_t)suggestion {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig(suggestion);
}

%end

// ===== 关于本机 / 系统健康：部件与服务历史分组 =====
// FLGroupViewModelImpl.addItem: 负责把"电池 未知部件"行加入分组；命中即跳过。
%hook FLGroupViewModelImpl

- (void)addItem:(id)item {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsBatteryWarningItem(item)) return;
    %orig(item);
}

%end

// SystemHealthUI：系统健康信息 specifier 列表，过滤电池未知部件行。
%hook SystemHealthUI

- (id)getCurrentSystemHealthInfoSpecifiers {
    id result = %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return result;
    if (![result isKindOfClass:[NSArray class]]) return result;
    NSMutableArray *kept = [NSMutableArray array];
    for (id spec in (NSArray *)result) {
        if (!CPUthermalIsBatteryWarningItem(spec)) [kept addObject:spec];
    }
    return kept;
}

%end

%end

// ===== SpringBoard：设置首页 / 通知中心红字角标"1" =====
%group CPUthermalSpringBoardComponent

%hook SBIconController

- (BOOL)allowsBadgingForIcon:(id)icon {
    if (CPUthermalComponentSuppressionEnabled()) return NO;
    return %orig(icon);
}

%end

%end

static void CPUthermalInstallComponentHooks(void);

static void CPUthermalComponentBundleLoaded(CFNotificationCenterRef c, void *o, CFStringRef n,
                                            const void *obj, CFDictionaryRef ui) {
    (void)c; (void)o; (void)n; (void)obj; (void)ui;
    // BatteryUsageUI.bundle 就绪后再安装 Preferences 侧 Hook。
    if (objc_getClass("BatteryUIResourceClass") != Nil)
        CPUthermalInstallComponentHooks();
}

static void CPUthermalInstallComponentHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init(CPUthermalComponentHooks);
        if ([NSProcessInfo.processInfo.processName isEqualToString:S("SpringBoard")])
            %init(CPUthermalSpringBoardComponent);
    });
}

%ctor {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        // 仅两层注入：Preferences（电池状态页）+ SpringBoard（首页红字）。
        // 类缺失时 Logos 自动跳过，不会崩溃。
        if (![process isEqualToString:S("Preferences")] && ![process isEqualToString:S("SpringBoard")])
            return;

        dispatch_async(CPUthermalComponentQueue(), ^{ CPUthermalReloadComponentSuppression(); });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gCPUthermalComponentToken,
                                 CPUthermalComponentQueue(), ^(int token) {
            (void)token;
            CPUthermalReloadComponentSuppression();
        });

        // Preferences：等 BatteryUsageUI.bundle 加载；SpringBoard：立即装角标 Hook。
        if ([process isEqualToString:S("SpringBoard")]) {
            CPUthermalInstallComponentHooks();
        } else {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                            CPUthermalComponentBundleLoaded,
                                            (__bridge CFStringRef)NSBundleDidLoadNotification,
                                            NULL, CFNotificationSuspensionBehaviorCoalesce);
            if (objc_getClass("BatteryUIResourceClass") != Nil)
                CPUthermalInstallComponentHooks();
        }
    }
}
