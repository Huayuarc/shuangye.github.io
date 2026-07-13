// SBCustomizer — 主屏幕网格自定义（Dock 图标数、列数、行数、隐藏标签）
// 移植自 Cyanide: tweaks/sbcustomizer.m
// 原理: Hook SBIconListLayout / SBDockIconListView 控制图标布局

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

#pragma mark - Preferences

static NSString *const kSBPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kSBPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";

static NSString *const kSBEnabledKey     = @"cyanide_sbCustomizer";
static NSString *const kSBDockIconsKey   = @"cyanide_sbDockIcons";
static NSString *const kSBColumnsKey     = @"cyanide_sbColumns";
static NSString *const kSBRowsKey        = @"cyanide_sbRows";
static NSString *const kSBHideLabelsKey  = @"cyanide_sbHideLabels";

static BOOL  g_sbEnabled   = NO;
static int   g_sbDockIcons = 4;
static int   g_sbColumns   = 4;
static int   g_sbRows      = 0;
static BOOL  g_sbHideLabels = NO;

#pragma mark - Preferences Reload

static void sb_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	g_sbEnabled    = [prefs[kSBEnabledKey] boolValue];
	g_sbDockIcons  = (int)[prefs[kSBDockIconsKey] integerValue];
	g_sbColumns    = (int)[prefs[kSBColumnsKey] integerValue];
	g_sbRows       = (int)[prefs[kSBRowsKey] integerValue];
	g_sbHideLabels = [prefs[kSBHideLabelsKey] boolValue];

	if (g_sbDockIcons < 1) g_sbDockIcons = 4;
	if (g_sbDockIcons > 10) g_sbDockIcons = 10;
	if (g_sbColumns < 3) g_sbColumns = 4;
	if (g_sbColumns > 8) g_sbColumns = 8;
	if (g_sbRows < 0) g_sbRows = 0;
	if (g_sbRows > 8) g_sbRows = 8;
}

static void sb_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	sb_reloadPreferences();
}

#pragma mark - Logos Hooks

%group SBCustomizerHooks

// Dock 图标数量
%hook SBIconListLayout
- (NSUInteger)numberOfColumns {
	if (g_sbEnabled) {
		// 判断是否为 Dock Layout
		static NSString *dockListLayoutClass = @"SBDockIconListLayout";
		if ([NSStringFromClass(object_getClass(self)) hasPrefix:dockListLayoutClass]) {
			return g_sbDockIcons;
		}
		return g_sbColumns;
	}
	return %orig;
}

- (NSUInteger)numberOfRows {
	if (g_sbEnabled && g_sbRows > 0) {
		static NSString *dockListLayoutClass = @"SBDockIconListLayout";
		if (![NSStringFromClass(object_getClass(self)) hasPrefix:dockListLayoutClass]) {
			return g_sbRows;
		}
	}
	return %orig;
}
%end

// 隐藏图标标签
%hook SBIconView
- (void)setLabelHidden:(BOOL)hidden {
	if (g_sbEnabled && g_sbHideLabels) {
		%orig(YES);
	} else {
		%orig;
	}
}
%end

// 布局刷新辅助
%hook SBRootFolder
- (void)setIconListView:(id)listView forIconListModel:(id)model {
	%orig;
	if (g_sbEnabled) {
		// 通知布局更新
		[[NSNotificationCenter defaultCenter] postNotificationName:@"SBIconListLayoutDidChangeNotification" object:self];
	}
}
%end

%end

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		sb_reloadPreferences();

		if (NSClassFromString(@"SBIconListLayout") && NSClassFromString(@"SBIconView")) {
			%init(SBCustomizerHooks);
		}

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
