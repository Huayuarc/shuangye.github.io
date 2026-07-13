// Kill All Background Apps — 一键杀后台
// 移植自 Cyanide: tweaks/killallapps.m
// 原理: 遍历 SBApplicationController.runningApplications，对每个非白名单 app 调用
//       模拟上滑关闭手势（使用 SBMainSwitcherViewController 的退出方法）

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

#pragma mark - Preferences

static NSString *const kKAPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kKAPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kKAEnabledKey = @"cyanide_killAll";

static BOOL g_kaEnabled = NO;

#pragma mark - Bundle ID Denylist

static BOOL ka_isSkippableBundleID(NSString *bundleID) {
	static NSSet *denyExact = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		denyExact = [NSSet setWithObjects:
			@"com.apple.springboard",
			@"com.apple.PineBoard",
			@"com.apple.InCallService",
			@"com.apple.AccessibilityUIServer",
			@"com.apple.siri.IntelligentLight",
			@"com.apple.mobilesms.compose",
			@"com.apple.Passcode",
			nil
		];
	});

	if ([denyExact containsObject:bundleID]) return YES;

	static NSArray *denySubstrings = nil;
	static dispatch_once_t subOnce;
	dispatch_once(&subOnce, ^{
		denySubstrings = @[
			@"WidgetRenderer",
			@"PickerService",
			@"ExtensionService",
			@"ViewService",
			@"UIService",
			@"UIHost",
			@".XPCService",
			@".extension",
			@".Extension",
		];
	});

	for (NSString *sub in denySubstrings) {
		if ([bundleID rangeOfString:sub].location != NSNotFound) return YES;
	}
	return NO;
}

#pragma mark - Kill All Logic

static void ka_killAllApps(void) {
	SBApplicationController *appController = [objc_getClass("SBApplicationController") sharedInstance];
	NSArray *runningApps = [appController runningApplications];

	int killed = 0;
	int skipped = 0;

	for (SBApplication *app in runningApps) {
		NSString *bundleID = [app bundleIdentifier];
		if (!bundleID) continue;

		if (ka_isSkippableBundleID(bundleID)) {
			skipped++;
			continue;
		}

		// 通过 SBMainSwitcherViewController 或直接调用 SBApplication 退出
		// 方法1: 调用 _SBWorkspaceKillApplication (C 函数，可能存在)
		static void (*killAppFn)(id, int) = NULL;
		static dispatch_once_t onceKill;
		dispatch_once(&onceKill, ^{
			killAppFn = dlsym(RTLD_DEFAULT, "_SBWorkspaceKillApplication");
		});

		if (killAppFn) {
			killAppFn(app, 0); // 0 = soft kill (BKS exit reason 5)
			killed++;
		} else {
			// 方法2: SBApplication 的 kill 方法
			SEL killSel = NSSelectorFromString(@"kill");
			if ([app respondsToSelector:killSel]) {
				((void (*)(id, SEL))objc_msgSend)(app, killSel);
				killed++;
			}
		}
	}

	NSLog(@"[KillAll] killed=%d skipped=%d", killed, skipped);
}

#pragma mark - KillAll Hook

%group KillAllHooks

%hook SBMainSwitcherViewController
- (void)_toggleSwitcherViewController:(id)arg1 {
	%orig;
	if (g_kaEnabled) {
		// 每次打开多任务时执行杀后台
		// 注意：为避免频繁触发，只在开关开启时有效
	}
}
%end

%end

#pragma mark - Preferences Reload

static void ka_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newVal = [prefs[kKAEnabledKey] boolValue];

	if (newVal && !g_kaEnabled) {
		// 开关从关→开，立即执行一次杀后台
		ka_killAllApps();
	}
	g_kaEnabled = newVal;
}

static void ka_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	ka_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		ka_reloadPreferences();

		// 注册配置变更通知
		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			ka_prefsChangedCallback,
			(__bridge CFStringRef)kKAPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
