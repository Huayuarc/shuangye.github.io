// NSBar — 实时网速浮层
// 移植自 Cyanide: tweaks/nsbar.m
// 原理: 在 SpringBoard 创建 UIWindow 显示实时上传/下载速度

#import <UIKit/UIKit.h>
#import <notify.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>

#pragma mark - Preferences

static NSString *const kNSBPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kNSBPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";
static NSString *const kNSBEnabledKey  = @"cyanide_nsBar";
static NSString *const kNSBPositionKey = @"cyanide_nsBarPosition";

typedef NS_ENUM(NSInteger, NSBarPosition) {
	NSBarPositionTopLeft = 0,
	NSBarPositionTopRight = 2,
	NSBarPositionBottomLeft = 1,
	NSBarPositionBottomRight = 3,
};

static BOOL g_nsbEnabled   = NO;
static NSBarPosition g_nsbPosition = NSBarPositionTopLeft;

static UIWindow       *g_nsbWindow = nil;
static UILabel        *g_nsbLabel  = nil;
static dispatch_source_t g_nsbTimer = nil;

// 网络流量统计
static uint64_t g_nsbLastRx = 0;
static uint64_t g_nsbLastTx = 0;
static uint64_t g_nsbLastTime = 0;

#pragma mark - Network Stats

static void nsb_updateNetworkStats(void) {
	// 读取 /proc/net/dev 获取网络流量
	FILE *fp = fopen("/proc/net/dev", "r");
	if (!fp) {
		// fallback: 使用 sysctl 或 getifaddrs
		struct ifaddrs *ifaddr, *ifa;
		int family;
		if (getifaddrs(&ifaddr) == -1) return;

		uint64_t rx = 0, tx = 0;
		for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
			if (!ifa->ifa_addr) continue;
			family = ifa->ifa_addr->sa_family;
			if (family != AF_LINK) continue;
			NSString *name = @(ifa->ifa_name);
			if (![name hasPrefix:@"en"] && ![name hasPrefix:@"pdp_ip"]) continue;

			struct if_data *stats = (struct if_data *)ifa->ifa_data;
			if (stats) {
				rx += stats->ifi_ibytes;
				tx += stats->ifi_obytes;
			}
		}
		freeifaddrs(ifaddr);

		uint64_t now = mach_absolute_time();
		if (g_nsbLastTime > 0 && g_nsbLastRx > 0) {
			double elapsed = (double)(now - g_nsbLastTime) / 1000000000.0;
			if (elapsed > 0) {
				double downSpeed = (double)(rx - g_nsbLastRx) / elapsed;
				double upSpeed = (double)(tx - g_nsbLastTx) / elapsed;

				NSString *downStr, *upStr;
				if (downSpeed > 1048576) downStr = [NSString stringWithFormat:@"%.1fMB/s", downSpeed / 1048576.0];
				else if (downSpeed > 1024) downStr = [NSString stringWithFormat:@"%.0fKB/s", downSpeed / 1024.0];
				else downStr = [NSString stringWithFormat:@"%.0fB/s", downSpeed];

				if (upSpeed > 1048576) upStr = [NSString stringWithFormat:@"%.1fMB/s", upSpeed / 1048576.0];
				else if (upSpeed > 1024) upStr = [NSString stringWithFormat:@"%.0fKB/s", upSpeed / 1024.0];
				else upStr = [NSString stringWithFormat:@"%.0fB/s", upSpeed];

				g_nsbLabel.text = [NSString stringWithFormat:@"↓%@ ↑%@", downStr, upStr];
			}
		}
		g_nsbLastRx = rx;
		g_nsbLastTx = tx;
		g_nsbLastTime = now;
	} else {
		fclose(fp);
	}
}

#pragma mark - NSBar UI

static void nsb_createWindow(void) {
	if (g_nsbWindow) return;

	CGFloat w = 120, h = 20;
	CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
	CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
	CGFloat x = 0, y = 0;

	switch (g_nsbPosition) {
		case NSBarPositionTopLeft:     x = 0; y = 0; break;
		case NSBarPositionTopRight:    x = screenW - w; y = 0; break;
		case NSBarPositionBottomLeft:  x = 0; y = screenH - h; break;
		case NSBarPositionBottomRight: x = screenW - w; y = screenH - h; break;
	}

	g_nsbWindow = [[UIWindow alloc] initWithFrame:CGRectMake(x, y, w, h)];
	g_nsbWindow.windowLevel = UIWindowLevelStatusBar + 200;
	g_nsbWindow.backgroundColor = [UIColor clearColor];
	g_nsbWindow.userInteractionEnabled = NO;
	g_nsbWindow.clipsToBounds = YES;

	g_nsbLabel = [[UILabel alloc] initWithFrame:g_nsbWindow.bounds];
	g_nsbLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
	g_nsbLabel.textColor = [UIColor greenColor];
	g_nsbLabel.font = [UIFont boldSystemFontOfSize:9];
	g_nsbLabel.textAlignment = NSTextAlignmentCenter;
	g_nsbLabel.adjustsFontSizeToFitWidth = YES;
	g_nsbLabel.text = @"↓0B/s ↑0B/s";

	[g_nsbWindow addSubview:g_nsbLabel];
	g_nsbWindow.hidden = NO;
}

static void nsb_startTimer(void) {
	if (g_nsbTimer) return;

	g_nsbTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	if (!g_nsbTimer) return;

	dispatch_source_set_timer(g_nsbTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 0.3 * NSEC_PER_SEC);
	dispatch_source_set_event_handler(g_nsbTimer, ^{
		nsb_updateNetworkStats();
	});
	dispatch_resume(g_nsbTimer);
}

static void nsb_stopTimer(void) {
	if (g_nsbTimer) {
		dispatch_source_cancel(g_nsbTimer);
		g_nsbTimer = nil;
	}
}

static void nsb_cleanup(void) {
	nsb_stopTimer();
	g_nsbLabel = nil;
	g_nsbWindow = nil;
}

#pragma mark - Preferences Reload

static void nsb_reloadPreferences(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
	BOOL newEnabled = [prefs[kNSBEnabledKey] boolValue];
	NSBarPosition newPos = (NSBarPosition)[prefs[kNSBPositionKey] integerValue];

	if (newEnabled && !g_nsbEnabled) {
		g_nsbPosition = newPos;
		nsb_createWindow();
		g_nsbLastRx = 0;
		g_nsbLastTx = 0;
		g_nsbLastTime = 0;
		nsb_startTimer();
	} else if (!newEnabled && g_nsbEnabled) {
		nsb_cleanup();
	} else if (newPos != g_nsbPosition && g_nsbEnabled) {
		g_nsbPosition = newPos;
		nsb_cleanup();
		nsb_createWindow();
		nsb_startTimer();
	}
	g_nsbEnabled = newEnabled;
	g_nsbPosition = newPos;
}

static void nsb_prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	nsb_reloadPreferences();
}

#pragma mark - Constructor

%ctor {
	@autoreleasepool {
		nsb_reloadPreferences();
		if (g_nsbEnabled) {
			nsb_createWindow();
			nsb_startTimer();
		}

		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			NULL,
			nsb_prefsChangedCallback,
			(__bridge CFStringRef)kNSBPrefsChangedNotification,
			NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately
		);
	}
}
