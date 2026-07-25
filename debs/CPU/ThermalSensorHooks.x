// ============================================================================
// ThermalPopupHooks — 屏蔽 iOS 高温温度计警告弹窗（全屏"iPhone 需要冷却"）
//
// 只做一件事：阻止 ThermalManager.updateThermalNotification: 触发高温警告 UI
// ============================================================================

#import <Foundation/Foundation.h>
#import <notify.h>

// ============================================================================
// 私有类声明
// ============================================================================
@interface ThermalManager : NSObject
- (void)updateThermalNotification:(id)notification;
@end

// ============================================================================
// 状态
// ============================================================================
static BOOL g_ts_blockNotifPopup = YES;

// ============================================================================
// Prefs 路径
// ============================================================================
static NSString *ts_prefsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *jbRoot = NSProcessInfo.processInfo.environment[@"JB_ROOT"];
        if (!jbRoot) jbRoot = @(getenv("JB_ROOT") ?: "");
        if (jbRoot.length > 0) {
            path = [jbRoot stringByAppendingPathComponent:@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist"];
        } else {
            path = @"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist";
        }
    });
    return path;
}

static NSDictionary *ts_readPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:ts_prefsPath()];
}

// ============================================================================
// 加载偏好设置
// ============================================================================
static void ts_loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *d = ts_readPrefs() ?: @{};
        g_ts_blockNotifPopup = [d[@"thermalBlockNotifPopup"] ?: @YES boolValue];
        NSLog(@"[ThermalPopup] blockPopup=%d", g_ts_blockNotifPopup);
    }
}

// ============================================================================
// Darwin 通知回调 — 设置变更时重载
// ============================================================================
static void ts_onPrefsChanged(CFNotificationCenterRef center, void *observer,
                               CFNotificationName name, const void *object,
                               CFDictionaryRef userInfo) {
    ts_loadPrefs();
    NSLog(@"[ThermalPopup] 设置已重载");
}

// ============================================================================
// %hook: ThermalManager — 阻断高温警告弹窗
// ============================================================================
%hook ThermalManager

- (void)updateThermalNotification:(id)notification {
    if (g_ts_blockNotifPopup) {
        NSLog(@"[ThermalPopup] 阻止高温警告: %@", notification);
        return;
    }
    %orig;
}

%end

// ============================================================================
// %ctor
// ============================================================================
%ctor {
    @autoreleasepool {
        ts_loadPrefs();

        // 注册监听设置变更
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) {
            CFNotificationCenterAddObserver(c, NULL, ts_onPrefsChanged,
                CFSTR("com.huayuarc.cputhermal-reloadPrefs"),
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        NSLog(@"[ThermalPopup] 初始化完成: blockPopup=%d", g_ts_blockNotifPopup);
    }
}
