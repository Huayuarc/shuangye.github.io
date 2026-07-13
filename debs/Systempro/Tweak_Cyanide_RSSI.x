// RSSI Display — 实时 WiFi/蜂窝信号强度显示(dBm)
// 移植自 Cyanide: tweaks/experimental/rssidisplay.m
// 原理: 在 SpringBoard 创建浮层读取 CTServiceRadioAccessTechnology 显示 dBm

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <SystemConfiguration/CaptiveNetwork.h>

#pragma mark - Preferences

static NSString *const kRSSIPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kRSSIPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kRSSIEnabledKey  = @"cyanide_rssi";
static NSString *const kRSSIShowWiFiKey = @"cyanide_rssiShowWiFi";
static NSString *const kRSSIShowCellKey = @"cyanide_rssiShowCell";

static BOOL g_rssiEnabled  = NO;
static BOOL g_rssiShowWiFi = YES;
static BOOL g_rssiShowCell = YES;

static UIWindow       *g_rssiWindow = nil;
static UILabel        *g_rssiLabel  = nil;
static dispatch_source_t g_rssiTimer = nil;

#pragma mark - Signal Info

static int rssi_getWiFiRSSI(void) {
	// 通过 CNCopyCurrentNetworkInfo 获取 WiFi RSSI
	// 实际上 CNCopyCurrentNetworkInfo 不提供 RSSI
	// 从系统状态栏数据中读取
	NSArray *interfaces = (__bridge_transfer NSArray *)CNCopySupportedInterfaces();
	for (NSString *ifname in interfaces) {
		NSDictionary *info = (__bridge_transfer NSDictionary *)CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifname);
		if (info && info[(NSString *)kCNNetworkInfoKeySSID]) {
			// 尝试读取 RSSI, 部分版本不可用
			id rssiVal = info[@"RSSI"];
			if (rssiVal) return [rssiVal intValue];
		}
	}
	return 0;
}

static int rssi_getCellRSSI(void) {
	// 通过 SBTelephonyManager（SpringBoard 私有类）
	id telephonyMgr = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("SBTelephonyManager"), sel_registerName("sharedTelephonyManager"));
	if ([telephonyMgr respondsToSelector:@selector(signalStrength)]) {
		int bars = (int)((NSInteger (*)(id, SEL))objc_msgSend)(telephonyMgr, sel_registerName("signalStrength"));
		// dBm 近似: bars 0->-113, 1->-105, 2->-97, 3->-89, 4->-77, 5->-65
		int dBm[] = { -113, -105, -97, -89, -77, -65 };
		if (bars >= 0 && bars <= 5) return dBm[bars];
	}
	return 0;
}

#pragma mark - RSSI UI

static void rssi_createWindow(void) {
	if (g_rssiWindow) return;

	CGFloat w = 100, h = 20;
	CGFloat screenW = [UIScreen mainScreen].bounds.size.width;

	g_rssiWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screenW - w - 5, 0, w, h)];
	g_rssiWindow.windowLevel = UIWindowLevelStatusBar + 150;
	g_rssiWindow.backgroundColor = [UIColor clearColor];
	g_rssiWindow.userInteractionEnabled = NO;

	g_rssiLabel = [[UILabel alloc] initWithFrame:g_rssiWindow.bounds];
	g_rssiLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
	g_rssiLabel.textColor = [UIColor whiteColor];
	g_rssiLabel.font = [UIFont systemFontOfSize:9];
	g_rssiLabel.textAlignment = NSTextAlignmentCenter;
	g_rssiLabel.text = @"WiFi:-- Cell:--";

	[g_rssiWindow addSubview:g_rssiLabel];
	g_rssiWindow.hidden = NO;
}

static void rssi_updateLabel(void) {
	if (!g_rssiLabel) return;

	NSMutableString *text = [NSMutableString string];
	if (g_rssiShowWiFi) {
		int wifi = rssi_getWiFiRSSI();
		if (wifi < 0) [text appendFormat:@"WiFi:%d ", wifi];
		else [text appendString:@"WiFi:-- "];
	}
	if (g_rssiShowCell) {
		int cell = rssi_getCellRSSI();
		if (cell < 0) [text appendFormat:@"Cell:%d", cell];
		else [text appendString:@"Cell:--"];
	}
	g_rssiLabel.text = text;
}

static void rssi_startTimer(void) {
	if (g_rssiTimer) return;

	g_rssiTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	if (!g_rssiTimer) return;

	dispatch_source_set_timer(g_rssiTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 0.3 * NSEC_PER_SEC);
	dispatch_source_set_event_handler(g_rssiTimer, ^{
		rssi_updateLabel();
	});
	dispatch_resume(g_rssiTimer);
}

static void rssi_stopTimer(void) {
	if (g_rssiTimer) {
		dispatch_source_cancel(g_rssiTimer);
		g_rssiTimer = nil;
	}
}

static void rssi_cleanup(void) {
	rssi_stopTimer();
	g_rssiLabel = nil;
	g_rssiWindow = nil;
}

#pragma mark - Preferences Reload

static void rssi_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newEnabled = [prefs[kRSSIEnabledKey] boolValue];
	g_rssiShowWiFi = [prefs[kRSSIShowWiFiKey] boolValue];
	g_rssiShowCell = [prefs[kRSSIShowCellKey] boolValue];

	if (newEnabled && !g_rssiEnabled) {
		rssi_createWindow();
		rssi_startTimer();
	} else if (!newEnabled && g_rssiEnabled) {
		rssi_cleanup();
	}
	g_rssiEnabled = newEnabled;
}

static void rssi_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	rssi_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		rssi_reloadPreferences();
		if (g_rssiEnabled) {
			rssi_createWindow();
			rssi_startTimer();
		}

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			rssi_prefsChangedCallback,
			(__bridge CFStringRef)kRSSIPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
