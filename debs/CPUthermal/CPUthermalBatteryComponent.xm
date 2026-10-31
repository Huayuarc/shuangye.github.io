// CPUthermal 电池维修/部件提示屏蔽
// isolation.24：两份还原样本并入单一开关 suppressBatteryServiceWarnings。
//   NoAppleMobileRepair：BatteryUIResourceClass、BatteryUIController、
//     FLGroupViewModelImpl、SystemHealthUI、SBIconController
//   NoPreferencesTips：PSUIPrefsListController、PSGAboutDataSource、
//     SBApplication、BSUIBadgeController
// 只改变 UI 呈现，不写入电池健康数据、不改变硬件保护。

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
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id value = prefs[S("suppressBatteryServiceWarnings")];
        BOOL enabled = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
        // 兼容 isolation.23 曾独立存在的部件开关。
        if (!enabled) {
            id legacy = prefs[S("suppressComponentWarning")];
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

static BOOL CPUthermalIsBatteryWarningItem(id item) {
    if (!item) return NO;
    NSString *identifier = nil;
    if ([item respondsToSelector:@selector(clientIdentifier)])
        identifier = [item performSelector:@selector(clientIdentifier)];
    else if ([item respondsToSelector:@selector(bundleIdentifier)])
        identifier = [item performSelector:@selector(bundleIdentifier)];
    if ([identifier isEqualToString:S("com.apple.mobilerepair")] ||
        [identifier isEqualToString:S("com.apple.SoftwareUpdateServices")]) return YES;

    NSString *label = nil;
    NSString *detail = nil;
    if ([item respondsToSelector:@selector(name)]) label = [item performSelector:@selector(name)];
    if (!label.length && [item respondsToSelector:@selector(label)])
        label = [item performSelector:@selector(label)];
    if ([item respondsToSelector:@selector(detailText)])
        detail = [item performSelector:@selector(detailText)];
    for (NSString *text in @[ label ?: S(""), detail ?: S("") ]) {
        if ([text containsString:S("未知部件")] || [text containsString:S("Unknown Part")] ||
            [text containsString:S("Important Battery Message")] ||
            [text containsString:S("重要电池信息")] ||
            [text containsString:S("电池维修")] || [text containsString:S("Battery Service")])
            return YES;
    }
    return NO;
}

static BOOL CPUthermalIsPreferencesBundle(id object) {
    NSString *bundleID = nil;
    if ([object respondsToSelector:@selector(bundleIdentifier)])
        bundleID = [object performSelector:@selector(bundleIdentifier)];
    else if ([object respondsToSelector:@selector(applicationBundleID)])
        bundleID = [object performSelector:@selector(applicationBundleID)];
    return [bundleID isEqualToString:S("com.apple.Preferences")];
}

%group CPUthermalComponentHooks

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

%hook BatteryUIController

- (id)getBatteryServiceSuggestion:(uintptr_t)suggestion {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig(suggestion);
}

- (id)setUpBatteryHealthSpecifiers {
    id result = %orig;
    if (!CPUthermalComponentSuppressionEnabled() || ![result respondsToSelector:@selector(lastObject)])
        return result;
    id last = [result lastObject];
    if ([last respondsToSelector:@selector(setProperty:forKey:)])
        [last setProperty:@NO forKey:S("enabled")];
    return result;
}

%end

%hook FLGroupViewModelImpl

- (void)addItem:(id)item {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsBatteryWarningItem(item)) return;
    %orig(item);
}

%end

%hook SystemHealthUI

+ (id)getCurrentSystemHealthInfoSpecifiers {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig;
}

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

%hook PSGAboutDataSource

- (id)nonGenuineComponentSpecifierForComponent:(id)component {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig(component);
}

%end

%hook PSUIPrefsListController

- (void)updateFollowupSpecifiersWithCompletion:(id)completion {
    if (CPUthermalComponentSuppressionEnabled()) {
        if (completion) ((void (^)(void))completion)();
        return;
    }
    %orig(completion);
}

%end

%end

%group CPUthermalSpringBoardComponent

%hook SBIconController

- (BOOL)allowsBadgingForIcon:(id)icon {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsPreferencesBundle(icon)) return NO;
    return %orig(icon);
}

%end

%hook SBApplication

- (id)badgeValue {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsPreferencesBundle(self)) return nil;
    return %orig;
}

%end

%hook BSUIBadgeController

- (void)updateBadgeValue:(id)value forBundleID:(id)bundleID {
    if (CPUthermalComponentSuppressionEnabled() &&
        [bundleID isKindOfClass:[NSString class]] &&
        [bundleID isEqualToString:S("com.apple.Preferences")]) {
        %orig(nil, bundleID);
        return;
    }
    %orig(value, bundleID);
}

%end

%end

static void CPUthermalInstallComponentHooks(void);

static void CPUthermalComponentBundleLoaded(CFNotificationCenterRef c, void *o, CFStringRef n,
                                            const void *obj, CFDictionaryRef ui) {
    (void)c; (void)o; (void)n; (void)obj; (void)ui;
    if (objc_getClass("BatteryUIResourceClass") != Nil || objc_getClass("BatteryUIController") != Nil)
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
        if (![process isEqualToString:S("Preferences")] && ![process isEqualToString:S("SpringBoard")])
            return;

        dispatch_async(CPUthermalComponentQueue(), ^{ CPUthermalReloadComponentSuppression(); });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gCPUthermalComponentToken,
                                 CPUthermalComponentQueue(), ^(int token) {
            (void)token;
            CPUthermalReloadComponentSuppression();
        });

        if ([process isEqualToString:S("SpringBoard")]) {
            CPUthermalInstallComponentHooks();
        } else {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                            CPUthermalComponentBundleLoaded,
                                            (__bridge CFStringRef)NSBundleDidLoadNotification,
                                            NULL, CFNotificationSuspensionBehaviorCoalesce);
            if (objc_getClass("BatteryUIResourceClass") != Nil ||
                objc_getClass("PSUIPrefsListController") != Nil ||
                objc_getClass("PSGAboutDataSource") != Nil)
                CPUthermalInstallComponentHooks();
        }
    }
}
