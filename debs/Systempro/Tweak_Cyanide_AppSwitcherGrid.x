// App Switcher Grid — Grid-style app switcher
// 移植自 Cyanide: tweaks/appswitchergrid.m
// 原理: hook SBAppSwitcherSettings.switcherStyle 返回 dockUpdateMode 的值

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Preferences

static NSString *const kASGPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kASGPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kASGEnabledKey = @"cyanide_appSwitcherGrid";

static BOOL g_asgEnabled = NO;

#pragma mark - Preferences Reload

static void asg_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	g_asgEnabled = [prefs[kASGEnabledKey] boolValue];
}

static void asg_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	asg_reloadPreferences();
}

#pragma mark - Logos Hooks

%group AppSwitcherGridHooks

%hook SBAppSwitcherSettings
- (int)switcherStyle {
	if (g_asgEnabled) {
		// 返回 dockUpdateMode 的值使多任务变为网格布局
		SBDeckSwitcherModifier *modifier = [objc_getClass("SBDeckSwitcherModifier") sharedInstance];
		if ([modifier respondsToSelector:@selector(dockUpdateMode)]) {
			return (int)[modifier dockUpdateMode];
		}
	}
	return %orig;
}
%end

%end

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		asg_reloadPreferences();

		if (NSClassFromString(@"SBAppSwitcherSettings") && NSClassFromString(@"SBDeckSwitcherModifier")) {
			%init(AppSwitcherGridHooks);
		}

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			asg_prefsChangedCallback,
			(__bridge CFStringRef)kASGPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
