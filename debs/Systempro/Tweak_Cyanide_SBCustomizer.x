// SBCustomizer — 主屏幕网格自定义（Dock 图标数、列数、隐藏标签）
// 移植自 Cyanide: tweaks/sbcustomizer.m

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

#pragma mark - Preferences

static NSString *const kSBPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";

static NSString *const kSBEnabledKey     = @"cyanide_sbCustomizer";
static NSString *const kSBDockIconsKey   = @"cyanide_sbDockIcons";
static NSString *const kSBColumnsKey     = @"cyanide_sbColumns";
static NSString *const kSBHideLabelsKey  = @"cyanide_sbHideLabels";

static BOOL  g_sbEnabled    = NO;
static int   g_sbDockIcons  = 4;
static int   g_sbColumns    = 4;
static BOOL  g_sbHideLabels = NO;

#pragma mark - Preferences Reload

static void sb_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	g_sbEnabled    = [prefs[kSBEnabledKey] boolValue];
	g_sbDockIcons  = (int)[prefs[kSBDockIconsKey] integerValue];
	g_sbColumns    = (int)[prefs[kSBColumnsKey] integerValue];
	g_sbHideLabels = [prefs[kSBHideLabelsKey] boolValue];
	if (g_sbDockIcons < 1) g_sbDockIcons = 4;
	if (g_sbDockIcons > 10) g_sbDockIcons = 10;
	if (g_sbColumns < 3) g_sbColumns = 4;
	if (g_sbColumns > 8) g_sbColumns = 8;
}

static void sb_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	sb_reloadPreferences();
}

#pragma mark - Logos Hooks

%hook SBIconListLayout
- (NSUInteger)numberOfColumns {
	if (g_sbEnabled) {
		NSString *clsName = NSStringFromClass(object_getClass(self));
		if ([clsName hasPrefix:@"SBDockIconListLayout"]) {
			return g_sbDockIcons;
		}
		return g_sbColumns;
	}
	return %orig;
}
%end

%hook SBIconView
- (void)setLabelHidden:(BOOL)hidden {
	%orig(g_sbEnabled && g_sbHideLabels ? YES : hidden);
}
%end

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		sb_reloadPreferences();

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			sb_prefsChangedCallback,
			(__bridge CFStringRef)kSBPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
