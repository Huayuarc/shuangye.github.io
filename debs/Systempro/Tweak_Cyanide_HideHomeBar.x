// Hide Home Bar — 隐藏主屏幕底部横条
// 移植自 Cyanide: tweaks/hide_home_bar
// 原版用 kernel 级文件清零操作，这里改为 hook SBFloatingDockController

#import <UIKit/UIKit.h>
#import <notify.h>

#pragma mark - Preferences

static NSString *const kHHBPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kHHBPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kHHBEnabledKey = @"cyanide_hideHomeBar";

static BOOL g_hhbEnabled = NO;

#pragma mark - Preferences Reload

static void hhb_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	g_hhbEnabled = [prefs[kHHBEnabledKey] boolValue];
}

static void hhb_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	hhb_reloadPreferences();
}

#pragma mark - Logos Hooks

%group HideHomeBarHooks

%hook SBFloatingDockController
- (void)_setHomeAffordanceHidden:(BOOL)hidden {
	%orig(g_hhbEnabled ? YES : hidden);
}
- (void)setWantsHomeGestureHidden:(BOOL)hidden {
	%orig(g_hhbEnabled ? YES : hidden);
}
%end

%end

%group HideHomeBariOS16Hooks

%hook CSHomeAffordanceView
- (void)setHidden:(BOOL)hidden {
	%orig(g_hhbEnabled ? YES : hidden);
}
- (void)setAlpha:(CGFloat)alpha {
	if (g_hhbEnabled) {
		%orig(0.0);
	} else {
		%orig;
	}
}
%end

%end

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		hhb_reloadPreferences();

		if (NSClassFromString(@"SBFloatingDockController")) {
			%init(HideHomeBarHooks);
		}
		if (NSClassFromString(@"CSHomeAffordanceView")) {
			%init(HideHomeBariOS16Hooks);
		}

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			hhb_prefsChangedCallback,
			(__bridge CFStringRef)kHHBPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
