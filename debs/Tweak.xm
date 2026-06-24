#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <net/if_dl.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <BluetoothManager/BluetoothManager.h>
#import <CoreLocation/CoreLocation.h>
#import <substrate.h>

// ============================================================================
// 常量
// ============================================================================
static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist";

static NSString *const kEnabledKey               = @"enabled";
static NSString *const kBlockModeKey             = @"blockMode";
static NSString *const kDisableAppLibraryKey     = @"disableAppLibrary";
static NSString *const kDisableSignatureCheckKey = @"disableSignatureCheck";
static NSString *const kTransparentDockKey       = @"transparentDock";
static NSString *const kDisableFlashlightKey     = @"disableFlashlight";
static NSString *const kDisableCameraKey         = @"disableCamera";
static NSString *const kDisableLockScreenCameraKey = @"disableLockScreenCamera";
static NSString *const kDisableScreenshotDetectionKey = @"disableScreenshotDetection";
static NSString *const kDisableCameraShutterSoundKey  = @"disableCameraShutterSound";
static NSString *const kAutoDismissFaceIDKey          = @"autoDismissFaceID";
static NSString *const kDisableLockSoundKey           = @"disableLockSound";
static NSString *const kRemoveUnlockDelayKey          = @"removeUnlockDelay";
static NSString *const kInCallUnlockedKey             = @"inCallUnlocked";
static NSString *const kRightToLeftAppOpenKey         = @"rightToLeftAppOpen";
static NSString *const kAppOpenAnimationDirectionKey = @"appOpenAnimationDirection";
static NSString *const kDisconnectWiFiBTKey  = @"disconnectWiFiBT";
static NSString *const kLowPowerOnLockKey   = @"lowPowerOnLock";
static NSString *const kLockWhenFaceDownKey = @"lockWhenFaceDown";
static NSString *const kDisableIconFlyInKey = @"disableIconFlyIn";
static NSString *const kZeroWakeAnimationKey = @"zeroWakeAnimation";
static NSString *const kZeroBacklightFadeKey = @"zeroBacklightFade";
static NSString *const kDoubleTapToLockKey = @"doubleTapToLock";
static NSString *const kAppSwitcherGridKey = @"appSwitcherGrid";
static NSString *const kCustomAnimationSpeedKey = @"customAnimationSpeed";
static NSString *const kAnimationSpeedKey = @"animationSpeed";
static NSString *const kStatusMemoryOverlayKey = @"statusMemoryOverlay";
static NSString *const kStatusNetworkSpeedKey = @"statusNetworkSpeed";
static NSString *const kDisableOTAUpdatesKey = @"disableOTAUpdates";
static NSString *const kHomeLayoutEnabledKey = @"homeLayoutEnabled";
static NSString *const kHomeColumnsKey = @"homeColumns";
static NSString *const kHomeRowsKey = @"homeRows";
static NSString *const kDockIconCountKey = @"dockIconCount";
static NSString *const kHideIconLabelsKey = @"hideIconLabels";
static NSString *const kHomeIconScaleKey = @"homeIconScale";
static NSString *const kDockIconScaleKey = @"dockIconScale";
static NSString *const kNotifyPrefsChanged = @"com.huayuarc.systempro.prefschanged";
static NSString *const kNotifyRespring     = @"com.huayuarc.systempro.respring";

// 通话录音提示音静音
static NSString *const kCallRecordingSoundKey = @"callRecordingSound";

// 手表配对覆盖
static NSString *const kNanoRegistryEnabledKey = @"nanoRegistryEnabled";

// 定位模拟
static NSString *const kLocationSimEnabledKey = @"locationSimEnabled";
static NSString *const kLocationSimLatKey     = @"locationSimLatitude";
static NSString *const kLocationSimLonKey     = @"locationSimLongitude";
static NSString *const kLocationSimAltKey     = @"locationSimAltitude";
static NSString *const kLocationSimAccKey     = @"locationSimAccuracy";

// blockMode 值
typedef NS_ENUM(NSInteger, LSBlockMode) {
	LSBlockModeLowPower = 0,  // 低电模式
	LSBlockModeSilent   = 1,  // 静音模式
	LSBlockModeAlways   = 2,  // 始终不亮
};

// 动画方向值
typedef NS_ENUM(NSInteger, AppOpenAnimationDirection) {
	AppOpenAnimationDirectionDisabled = 0,    // 默认动画
	AppOpenAnimationDirectionRightToLeft = 1, // 从右向左
	AppOpenAnimationDirectionLeftToRight = 2, // 从左向右
	AppOpenAnimationDirectionTopToBottom = 3, // 从上向下
	AppOpenAnimationDirectionBottomToTop = 4, // 从下向上
};

// ============================================================================
// 全局缓存
// ============================================================================
static BOOL      g_enabled                 = NO;
static LSBlockMode g_blockMode             = LSBlockModeAlways;
static BOOL      g_isRingerSilent          = NO;
static BOOL      g_disableAppLibrary       = NO;
static BOOL      g_disableSignatureCheck   = NO;
static BOOL      g_transparentDock         = NO;
static BOOL      g_disableFlashlight       = NO;
static BOOL      g_disableCamera           = NO;
static BOOL      g_disableLockScreenCamera = NO;
static BOOL      g_disableScreenshotDetection = NO;
static BOOL      g_disableCameraShutterSound  = NO;
static BOOL      g_autoDismissFaceID          = NO;
static BOOL      g_disableLockSound           = NO;
static BOOL      g_removeUnlockDelay          = NO;
static BOOL      g_inCallUnlocked             = NO;
static AppOpenAnimationDirection g_appOpenAnimationDirection = AppOpenAnimationDirectionDisabled;
static BOOL      g_disconnectWiFiBT           = NO;
static BOOL      g_lowPowerOnLock             = NO;
static BOOL      g_lockWhenFaceDown           = NO;
static BOOL      g_disableIconFlyIn          = NO;
static BOOL      g_zeroWakeAnimation        = NO;
static BOOL      g_zeroBacklightFade        = NO;
static BOOL      g_doubleTapToLock          = NO;
static BOOL      g_appSwitcherGrid          = NO;
static BOOL      g_customAnimationSpeed     = NO;
static NSInteger g_animationSpeed           = 2;
static BOOL      g_statusMemoryOverlay      = NO;
static BOOL      g_statusNetworkSpeed       = NO;
static BOOL      g_disableOTAUpdates        = NO;
static UIWindow *g_systemproStatusWindow    = nil;
static UILabel  *g_systemproStatusLabel     = nil;
static NSTimer  *g_systemproStatusTimer     = nil;
static uint64_t g_previousRxBytes           = 0;
static uint64_t g_previousTxBytes           = 0;
static BOOL      g_homeLayoutEnabled      = NO;
static NSInteger g_homeColumns            = 4;
static NSInteger g_homeRows               = 6;
static NSInteger g_dockIconCount          = 4;
static BOOL      g_hideIconLabels         = NO;
static NSInteger g_homeIconScale          = 100;
static NSInteger g_dockIconScale          = 100;
static BOOL      g_callRecordingSound      = NO;
static BOOL      g_nanoRegistryEnabled     = NO;
static BOOL      g_locationSimEnabled      = NO;
static double    g_locationSimLatitude     = 37.3317;
static double    g_locationSimLongitude    = -122.0307;
static double    g_locationSimAltitude     = 0.0;
static double    g_locationSimAccuracy     = 100.0;
static id        g_locationSimManager      = nil;
// 锁屏自动低电 — 记录锁屏前低电模式状态
static BOOL      g_isLPMOnBeforeLock          = NO;
// ============================================================================
// 配置读写 — 内存缓存（避免热路径 I/O）
// ============================================================================
static void reloadConfiguration(void) {
	@autoreleasepool {
		NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
		g_enabled           = [prefs[kEnabledKey] boolValue];
		g_blockMode         = (LSBlockMode)[prefs[kBlockModeKey] integerValue];
		g_disableAppLibrary = [prefs[kDisableAppLibraryKey] boolValue];
		g_disableSignatureCheck   = [prefs[kDisableSignatureCheckKey] boolValue];
		g_transparentDock         = [prefs[kTransparentDockKey] boolValue];
		g_disableFlashlight       = [prefs[kDisableFlashlightKey] boolValue];
		g_disableCamera           = [prefs[kDisableCameraKey] boolValue];
		g_disableLockScreenCamera = [prefs[kDisableLockScreenCameraKey] boolValue];
		g_disableScreenshotDetection = [prefs[kDisableScreenshotDetectionKey] boolValue];
		g_disableCameraShutterSound  = [prefs[kDisableCameraShutterSoundKey] boolValue];
		g_autoDismissFaceID          = [prefs[kAutoDismissFaceIDKey] boolValue];
		g_disableLockSound           = [prefs[kDisableLockSoundKey] boolValue];
		g_removeUnlockDelay          = [prefs[kRemoveUnlockDelayKey] boolValue];
		g_inCallUnlocked             = [prefs[kInCallUnlockedKey] boolValue];
		
		id directionVal = prefs[kAppOpenAnimationDirectionKey];
		if (directionVal) {
			g_appOpenAnimationDirection = (AppOpenAnimationDirection)[directionVal integerValue];
		} else {
			// 兼容老版本 boolean 键
			BOOL oldVal = [prefs[kRightToLeftAppOpenKey] boolValue];
			g_appOpenAnimationDirection = oldVal ? AppOpenAnimationDirectionRightToLeft : AppOpenAnimationDirectionDisabled;
		}
		
		g_disconnectWiFiBT           = [prefs[kDisconnectWiFiBTKey] boolValue];
		g_lowPowerOnLock             = [prefs[kLowPowerOnLockKey] boolValue];
		g_lockWhenFaceDown           = [prefs[kLockWhenFaceDownKey] boolValue];
		g_disableIconFlyIn          = [prefs[kDisableIconFlyInKey] boolValue];
		g_zeroWakeAnimation        = [prefs[kZeroWakeAnimationKey] boolValue];
		g_zeroBacklightFade        = [prefs[kZeroBacklightFadeKey] boolValue];
		g_doubleTapToLock          = [prefs[kDoubleTapToLockKey] boolValue];
		g_appSwitcherGrid          = [prefs[kAppSwitcherGridKey] boolValue];
		g_customAnimationSpeed     = [prefs[kCustomAnimationSpeedKey] boolValue];
		g_animationSpeed           = [prefs[kAnimationSpeedKey] integerValue];
		if (g_animationSpeed < 0 || g_animationSpeed > 3) g_animationSpeed = 2;
		g_statusMemoryOverlay      = [prefs[kStatusMemoryOverlayKey] boolValue];
		g_statusNetworkSpeed       = [prefs[kStatusNetworkSpeedKey] boolValue];
		g_disableOTAUpdates        = [prefs[kDisableOTAUpdatesKey] boolValue];
		g_homeLayoutEnabled        = [prefs[kHomeLayoutEnabledKey] boolValue];
		g_homeColumns              = [prefs[kHomeColumnsKey] integerValue] ?: 4;
		g_homeRows                 = [prefs[kHomeRowsKey] integerValue] ?: 6;
		g_dockIconCount            = [prefs[kDockIconCountKey] integerValue] ?: 4;
		g_hideIconLabels           = [prefs[kHideIconLabelsKey] boolValue];
		g_homeIconScale            = [prefs[kHomeIconScaleKey] integerValue] ?: 100;
		g_dockIconScale            = [prefs[kDockIconScaleKey] integerValue] ?: 100;
		g_callRecordingSound      = [prefs[kCallRecordingSoundKey] boolValue];
		g_nanoRegistryEnabled     = [prefs[kNanoRegistryEnabledKey] boolValue];
		g_locationSimEnabled      = [prefs[kLocationSimEnabledKey] boolValue];
		g_locationSimLatitude     = [prefs[kLocationSimLatKey] doubleValue] ?: 37.3317;
		g_locationSimLongitude    = [prefs[kLocationSimLonKey] doubleValue] ?: -122.0307;
		g_locationSimAltitude     = [prefs[kLocationSimAltKey] doubleValue];
		g_locationSimAccuracy     = [prefs[kLocationSimAccKey] doubleValue] ?: 100.0;
		if (g_homeColumns < 3 || g_homeColumns > 7) g_homeColumns = 4;
		if (g_homeRows < 4 || g_homeRows > 8) g_homeRows = 6;
		if (g_dockIconCount < 4 || g_dockIconCount > 7) g_dockIconCount = 4;
		if (g_homeIconScale < 80 || g_homeIconScale > 120) g_homeIconScale = 100;
		if (g_dockIconScale < 80 || g_dockIconScale > 120) g_dockIconScale = 100;
		// 兜底：确保枚举值不越界
		if (g_blockMode != LSBlockModeLowPower &&
			g_blockMode != LSBlockModeSilent &&
			g_blockMode != LSBlockModeAlways) {
			g_blockMode = LSBlockModeAlways;
		}
	}
}

// ============================================================================
// 判断是否应阻止亮屏
// ============================================================================
static BOOL shouldBlock(void) {
	if (!g_enabled) return NO;

	switch (g_blockMode) {
		case LSBlockModeAlways:
			return YES;
		case LSBlockModeLowPower:
			return [NSProcessInfo processInfo].isLowPowerModeEnabled;
		case LSBlockModeSilent:
			return g_isRingerSilent;
	}
	return NO;
}


static double SPAnimationSpeedCoefficient(void) {
	if (!g_customAnimationSpeed) return 1.0;
	switch (g_animationSpeed) {
		case 0: return 0.25;
		case 1: return 0.5;
		case 3: return 1.5;
		default: return 1.0;
	}
}

static double (*SPOrigUIAnimationDragCoefficient)(void) = NULL;

static double SPUIAnimationDragCoefficientHook(void) {
	if (!g_customAnimationSpeed) {
		return SPOrigUIAnimationDragCoefficient ? SPOrigUIAnimationDragCoefficient() : 1.0;
	}
	return SPAnimationSpeedCoefficient();
}

static void SPInstallAnimationSpeedHook(void) {
	void *symbol = dlsym(RTLD_DEFAULT, "_UIAnimationDragCoefficient");
	if (!symbol) {
		void *handle = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_LAZY);
		if (handle) symbol = dlsym(handle, "_UIAnimationDragCoefficient");
	}
	if (symbol) {
		MSHookFunction(symbol, (void *)&SPUIAnimationDragCoefficientHook, (void **)&SPOrigUIAnimationDragCoefficient);
	}
}

static uint64_t SPNetworkInterfaceBytes(BOOL transmit) {
	uint64_t total = 0;
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0) return 0;
	for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
		if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_LINK) continue;
		if (!(cursor->ifa_flags & IFF_UP) || (cursor->ifa_flags & IFF_LOOPBACK)) continue;
		struct if_data *data = (struct if_data *)cursor->ifa_data;
		if (!data) continue;
		total += transmit ? data->ifi_obytes : data->ifi_ibytes;
	}
	freeifaddrs(interfaces);
	return total;
}

static NSString *SPFormatBytesPerSecond(uint64_t bytes) {
	if (bytes >= 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1fM/s", (double)bytes / 1024.0 / 1024.0];
	if (bytes >= 1024ULL) return [NSString stringWithFormat:@"%.0fK/s", (double)bytes / 1024.0];
	return [NSString stringWithFormat:@"%lluB/s", (unsigned long long)bytes];
}

static uint64_t SPFreeMemoryMB(void) {
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	vm_statistics64_data_t vmstat;
	if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmstat, &count) != KERN_SUCCESS) return 0;
	uint64_t freePages = vmstat.free_count + vmstat.inactive_count;
	return (freePages * (uint64_t)vm_kernel_page_size) / 1024ULL / 1024ULL;
}

static void SPUpdateStatusOverlay(void) {
	if (!g_systemproStatusLabel) return;
	NSMutableArray<NSString *> *parts = [NSMutableArray array];
	if (g_statusMemoryOverlay) {
		[parts addObject:[NSString stringWithFormat:@"RAM %lluM", (unsigned long long)SPFreeMemoryMB()]];
	}
	if (g_statusNetworkSpeed) {
		uint64_t rx = SPNetworkInterfaceBytes(NO);
		uint64_t tx = SPNetworkInterfaceBytes(YES);
		uint64_t deltaRx = g_previousRxBytes ? rx - g_previousRxBytes : 0;
		uint64_t deltaTx = g_previousTxBytes ? tx - g_previousTxBytes : 0;
		g_previousRxBytes = rx;
		g_previousTxBytes = tx;
		[parts addObject:[NSString stringWithFormat:@"↓%@ ↑%@", SPFormatBytesPerSecond(deltaRx), SPFormatBytesPerSecond(deltaTx)]];
	}
	g_systemproStatusLabel.text = [parts componentsJoinedByString:@"  "];
	[g_systemproStatusLabel sizeToFit];
	CGRect frame = g_systemproStatusLabel.frame;
	frame.size.width += 16.0;
	frame.size.height = 20.0;
	frame.origin.x = ([UIScreen mainScreen].bounds.size.width - frame.size.width) / 2.0;
	frame.origin.y = 2.0;
	g_systemproStatusWindow.frame = frame;
	g_systemproStatusLabel.frame = g_systemproStatusWindow.bounds;
	g_systemproStatusWindow.hidden = parts.count == 0;
}

static void SPRefreshStatusOverlay(void) {
	BOOL enabled = g_statusMemoryOverlay || g_statusNetworkSpeed;
	if (!enabled) {
		[g_systemproStatusTimer invalidate];
		g_systemproStatusTimer = nil;
		g_systemproStatusWindow.hidden = YES;
		return;
	}
	if (!g_systemproStatusWindow) {
		g_systemproStatusWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 2, 1, 20)];
		g_systemproStatusWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
		g_systemproStatusWindow.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
		g_systemproStatusWindow.layer.cornerRadius = 6.0;
		g_systemproStatusWindow.clipsToBounds = YES;
		g_systemproStatusWindow.userInteractionEnabled = NO;
		g_systemproStatusLabel = [[UILabel alloc] initWithFrame:g_systemproStatusWindow.bounds];
		g_systemproStatusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		g_systemproStatusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
		g_systemproStatusLabel.textColor = UIColor.whiteColor;
		g_systemproStatusLabel.textAlignment = NSTextAlignmentCenter;
		[g_systemproStatusWindow addSubview:g_systemproStatusLabel];
	}
	g_systemproStatusWindow.hidden = NO;
	if (!g_systemproStatusTimer) {
		g_systemproStatusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
			SPUpdateStatusOverlay();
		}];
	}
	SPUpdateStatusOverlay();
}

static void SPApplyOTAState(void) {
	NSString *path = @"/var/db/com.apple.xpc.launchd/disabled.plist";
	NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:path];
	if (!plist) plist = [NSMutableDictionary dictionary];
	NSArray<NSString *> *labels = @[@"com.apple.mobile.softwareupdated", @"com.apple.OTATaskingAgent", @"com.apple.softwareupdateservicesd"];
	for (NSString *label in labels) {
		if (g_disableOTAUpdates) plist[label] = @YES;
		else [plist removeObjectForKey:label];
	}
	[plist writeToFile:path atomically:YES];
}

static void SPInstallDoubleTapGesture(UIView *view) {
	if (!view || objc_getAssociatedObject(view, @selector(SPInstallDoubleTapGesture:))) return;
	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[%c(SpringBoard) sharedApplication] action:@selector(_simulateLockButtonPress)];
	tap.numberOfTapsRequired = 2;
	tap.cancelsTouchesInView = NO;
	[view addGestureRecognizer:tap];
	objc_setAssociatedObject(view, @selector(SPInstallDoubleTapGesture:), tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


static double SPScaleForIconView(UIView *view) {
	if (!g_homeLayoutEnabled || !view) return 1.0;
	NSString *className = NSStringFromClass([view class]);
	BOOL isDock = [className containsString:@"Dock"];
	NSInteger pct = isDock ? g_dockIconScale : g_homeIconScale;
	return (double)pct / 100.0;
}

static void SPApplyIconViewScale(UIView *view) {
	if (!g_homeLayoutEnabled || !view) return;
	double scale = SPScaleForIconView(view);
	view.transform = CGAffineTransformMakeScale(scale, scale);
}

static NSUInteger SPLayoutCount(NSUInteger original, NSUInteger replacement) {
	return g_homeLayoutEnabled ? replacement : original;
}

// ============================================================================
// 通话录音提示音静音 — 静音音频数据 (移植 Cyanide call_recording_sound)
// ============================================================================
static const unsigned char kSilentAudioData[] = {
	0x00, 0x00, 0x00, 0x1c, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x41, 0x20, 0x00, 0x00, 0x02, 0x00,
	0x4d, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6f, 0x6d, 0x69, 0x73, 0x6f, 0x32, 0x00, 0x00, 0x00, 0x08,
	0x66, 0x72, 0x65, 0x65, 0x00, 0x00, 0x00, 0x25, 0x6d, 0x64, 0x61, 0x74, 0xde, 0x02, 0x00, 0x4c,
	0x61, 0x76, 0x63, 0x36, 0x32, 0x2e, 0x32, 0x38, 0x2e, 0x31, 0x30, 0x31, 0x00, 0x02, 0x30, 0x40,
	0x0e, 0x01, 0x18, 0x20, 0x07, 0x01, 0x18, 0x20, 0x07, 0x00, 0x00, 0x03, 0x07, 0x6d, 0x6f, 0x6f,
	0x76, 0x00, 0x00, 0x00, 0x6c, 0x6d, 0x76, 0x68, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x65, 0x00, 0x01, 0x00,
	0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x02,
	0x31, 0x74, 0x72, 0x61, 0x6b, 0x00, 0x00, 0x00, 0x5c, 0x74, 0x6b, 0x68, 0x64, 0x00, 0x00, 0x00,
	0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x24, 0x65, 0x64, 0x74, 0x73, 0x00, 0x00, 0x00, 0x1c, 0x65, 0x6c, 0x73,
	0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x04,
	0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0xa9, 0x6d, 0x64, 0x69, 0x61, 0x00, 0x00, 0x00,
	0x20, 0x6d, 0x64, 0x68, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x2b, 0x11, 0x00, 0x00, 0x08, 0x4f, 0x55, 0xc4, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x2d, 0x68, 0x64, 0x6c, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x73, 0x6f, 0x75,
	0x6e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x53, 0x6f, 0x75,
	0x6e, 0x64, 0x48, 0x61, 0x6e, 0x64, 0x6c, 0x65, 0x72, 0x00, 0x00, 0x00, 0x01, 0x54, 0x6d, 0x69,
	0x6e, 0x66, 0x00, 0x00, 0x00, 0x10, 0x73, 0x6d, 0x68, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x64, 0x69, 0x6e, 0x66, 0x00, 0x00, 0x00, 0x1c, 0x64, 0x72,
	0x65, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0c, 0x75, 0x72,
	0x6c, 0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x18, 0x73, 0x74, 0x62, 0x6c, 0x00, 0x00,
	0x00, 0x6a, 0x73, 0x74, 0x73, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
	0x00, 0x5a, 0x6d, 0x70, 0x34, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x2b, 0x11,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x65, 0x73, 0x64, 0x73, 0x00, 0x00, 0x00, 0x00, 0x03, 0x80,
	0x80, 0x80, 0x25, 0x00, 0x01, 0x00, 0x04, 0x80, 0x80, 0x80, 0x17, 0x40, 0x15, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x1f, 0x40, 0x00, 0x00, 0x04, 0xb2, 0x05, 0x80, 0x80, 0x80, 0x05, 0x15, 0x08, 0x56,
	0xe5, 0x00, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02, 0x00, 0x00, 0x00, 0x20, 0x73, 0x74, 0x74, 0x73,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x04, 0x00,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x4f, 0x00, 0x00, 0x00, 0x1c, 0x73, 0x74, 0x73, 0x63,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x20, 0x73, 0x74, 0x73, 0x7a, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x04,
	0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x14, 0x73, 0x74, 0x63, 0x6f, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x1a, 0x73, 0x67, 0x70, 0x64,
	0x01, 0x00, 0x00, 0x00, 0x72, 0x6f, 0x6c, 0x6c, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
	0xff, 0xff, 0x00, 0x00, 0x00, 0x1c, 0x73, 0x62, 0x67, 0x70, 0x00, 0x00, 0x00, 0x00, 0x72, 0x6f,
	0x6c, 0x6c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
	0x00, 0x62, 0x75, 0x64, 0x74, 0x61, 0x00, 0x00, 0x00, 0x5a, 0x6d, 0x65, 0x74, 0x61, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x68, 0x64, 0x6c, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x6d, 0x64, 0x69, 0x72, 0x61, 0x70, 0x70, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2d, 0x69, 0x6c, 0x73, 0x74, 0x00, 0x00, 0x00, 0x25, 0xa9,
	0x74, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x1d, 0x64, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x01, 0x00,
	0x00, 0x00, 0x00, 0x4c, 0x61, 0x76, 0x66, 0x36, 0x32, 0x2e, 0x31, 0x32, 0x2e, 0x31, 0x30, 0x31,
};
static const NSUInteger kSilentAudioLength = 848;

// ============================================================================
// 通话录音提示音静音 — 替换 CallServices 录音提示音文件
// ============================================================================
// 移植自 Cyanide call_recording_sound.m，去除 KRW/sandbox 依赖。
// 在 jailbreak 环境下 SpringBoard 有 /var/mobile 文件写入权限。
static void SPApplyCallRecordingSound(BOOL disabled) {
	NSString *targetDir = @"/var/mobile/Library/CallServices/Greetings/default";
	NSString *backupDir = @"/var/mobile/Library/Preferences/.systempro_callrecord_backup";
	NSFileManager *fm = [NSFileManager defaultManager];

	// 确保目标目录存在
	if (![fm fileExistsAtPath:targetDir]) {
		[fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	// 确保备份目录存在
	if (![fm fileExistsAtPath:backupDir]) {
		[fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	NSArray<NSString *> *fileNames = @[@"StartDisclosureWithTone.m4a", @"StopDisclosure.caf"];

	for (NSString *fileName in fileNames) {
		NSString *targetPath = [targetDir stringByAppendingPathComponent:fileName];
		NSString *backupPath = [backupDir stringByAppendingPathComponent:fileName];

		if (disabled) {
			// 静音模式：备份原文件 → 写入静音文件
			if ([fm fileExistsAtPath:targetPath] && ![fm fileExistsAtPath:backupPath]) {
				[fm copyItemAtPath:targetPath toPath:backupPath error:NULL];
			}
			NSData *silentData = [NSData dataWithBytes:kSilentAudioData length:kSilentAudioLength];
			[silentData writeToFile:targetPath atomically:YES];
		} else {
			// 恢复模式：从备份还原
			if ([fm fileExistsAtPath:backupPath]) {
				NSData *origData = [NSData dataWithContentsOfFile:backupPath];
				if (origData.length > 0) {
					[origData writeToFile:targetPath atomically:YES];
				}
				[fm removeItemAtPath:backupPath error:NULL];
			} else if ([fm fileExistsAtPath:targetPath]) {
				// 无备份但有目标文件 — 可能是手动创建的，保持原样
			}
		}
	}
	NSLog(@"[Systempro] CallRecordingSound %s", disabled ? "silenced" : "restored");
}

// ============================================================================
// 手表配对覆盖 — 写入/清除 NanoRegistry plist 兼容性键值
// ============================================================================
// 移植自 Cyanide nano_registry.m，去除 KRW/RemoteCall/sandbox 依赖。
// 直接编辑 /var/mobile/Library/Preferences/com.apple.NanoRegistry.plist。
static void SPApplyWatchNanoRegistry(BOOL enabled) {
	NSString *plistPath = @"/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist";
	NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
	if (!plist) plist = [NSMutableDictionary dictionary];

	if (enabled) {
		plist[@"maxPairingCompatibilityVersion"] = @99;
		plist[@"minPairingCompatibilityVersion"] = @23;
		plist[@"minPairingCompatibilityVersionWithChipID"] = @10;
		plist[@"minQuickSwitchCompatibilityVersion"] = @6;
	} else {
		[plist removeObjectForKey:@"maxPairingCompatibilityVersion"];
		[plist removeObjectForKey:@"minPairingCompatibilityVersion"];
		[plist removeObjectForKey:@"minPairingCompatibilityVersionWithChipID"];
		[plist removeObjectForKey:@"minQuickSwitchCompatibilityVersion"];
	}

	if ([plist writeToFile:plistPath atomically:YES]) {
		notify_post("com.apple.nanoregistry.pairingcompatibilityversion");
		NSLog(@"[Systempro] NanoRegistry %s", enabled ? "applied" : "cleared");
	}
}

// ============================================================================
// 定位模拟 — 使用 CLSimulationManager 在本进程注入模拟位置
// ============================================================================
// 移植自 Cyanide location_sim.m，去除 RemoteCall 依赖。
// SpringBoard 进程可直接调用 CoreLocation CLSimulationManager。
// CLSimulationManager 是私有类，声明方法在 NSObject 类别上使编译器通过
@interface NSObject (SystemproLocationSim)
- (void)stopLocationSimulation;
- (void)clearSimulatedLocations;
- (void)appendSimulatedLocation:(id)location;
- (void)startLocationSimulation;
@end
static void SPApplyLocationSim(BOOL enabled) {
	Class cls = NSClassFromString(@"CLSimulationManager");
	if (!cls) {
		NSLog(@"[Systempro] CLSimulationManager class not available");
		return;
	}

	if (enabled) {
		// 停止旧的模拟
		if (g_locationSimManager) {
			[(id)g_locationSimManager stopLocationSimulation];
			[(id)g_locationSimManager clearSimulatedLocations];
			g_locationSimManager = nil;
		}

		// 创建新 manager
		id manager = [[cls alloc] init];
		if (!manager) {
			NSLog(@"[Systempro] CLSimulationManager init failed");
			return;
		}

		// 创建 CLLocation
		Class locCls = NSClassFromString(@"CLLocation");
		if (!locCls) {
			NSLog(@"[Systempro] CLLocation class not available");
			return;
		}

		id location = [[locCls alloc] initWithLatitude:g_locationSimLatitude
		                                     longitude:g_locationSimLongitude];
		if (!location) {
			// 尝试带精度的 init
			location = [[locCls alloc] initWithCoordinate:CLLocationCoordinate2DMake(g_locationSimLatitude, g_locationSimLongitude)
			                                     altitude:g_locationSimAltitude
			                           horizontalAccuracy:g_locationSimAccuracy
			                             verticalAccuracy:g_locationSimAccuracy
			                                    timestamp:[NSDate date]];
		}

		if (location) {
			[manager appendSimulatedLocation:location];
			[manager startLocationSimulation];
			g_locationSimManager = manager;
			notify_post("AutomaticTimeZoneUpdateNeeded");
			NSLog(@"[Systempro] LocationSim started: %.4f, %.4f", g_locationSimLatitude, g_locationSimLongitude);
		}
	} else {
		// 停止模拟
		if (g_locationSimManager) {
			[(id)g_locationSimManager stopLocationSimulation];
			[(id)g_locationSimManager clearSimulatedLocations];
			g_locationSimManager = nil;
			NSLog(@"[Systempro] LocationSim stopped");
		}
	}
}

// ============================================================================
// ===== Logos Hooks =====
// ============================================================================

%group MainHooks

%hook SBNCScreenController
- (bool)canTurnOnScreenForNotificationRequest:(id)arg1 {
	if (!shouldBlock()) return %orig;
	return 0;
}
- (void)_turnOnScreen {
	if (!shouldBlock()) { %orig; return; }
}
%end

%hook SBLockScreenNotificationListController
- (void)_turnOnScreen {
	if (!shouldBlock()) { %orig; return; }
}
%end

// 禁用主屏幕 App 资源库
%hook SBIconController
- (bool)isAppLibraryAllowed {
	if (g_disableAppLibrary) return 0;
	return %orig;
}
- (bool)isAppLibrarySupported {
	if (g_disableAppLibrary) return 0;
	return %orig;
}
%end

// ============================================================================
// 透明 Dock 背景
// ============================================================================
%hook SBDockView
- (void)setBackgroundAlpha:(double)arg1 {
	if (g_transparentDock) {
		%orig(0);
	} else {
		%orig;
	}
}
%end

// ============================================================================
// 禁用锁屏快捷操作（手电筒/相机）
// ============================================================================
%hook CSQuickActionsViewController
- (bool)hasFlashlight {
	if (g_disableFlashlight) return 0;
	return %orig;
}
- (bool)hasCamera {
	if (g_disableCamera) return 0;
	return %orig;
}
%end

// ============================================================================
// 禁用锁屏相机按钮
// ============================================================================
%hook SpringBoard
- (bool)lockScreenCameraSupported {
	if (g_disableLockScreenCamera) return 0;
	return %orig;
}
%end

// ============================================================================
// 屏蔽屏幕截图录制检测 — 阻止系统检测截图/录屏状态
// ============================================================================
%hook UIDidTakeScreenshotAction
- (long long)UIActionType {
	if (g_disableScreenshotDetection) return 0;
	return %orig;
}
%end

%hook UIScreen
- (bool)isCaptured {
	if (g_disableScreenshotDetection) return 0;
	return %orig;
}
%end

%end

// ============================================================================
// 禁用签名验证（独立 group，仅在类存在时初始化）
// ============================================================================
%group SignatureHooks

%hook FBSSignatureValidationService
- (unsigned long long)trustStateForApplication:(id)arg1 {
	if (g_disableSignatureCheck) return 8;
	return %orig;
}
%end

%end

// ============================================================================
// 禁用相机快门声（独立 group，仅在类存在时初始化）
// ============================================================================
%group CameraShutterHooks

%hook AVCaptureIrisStillImageSettings
- (unsigned long)shutterSound {
	if (g_disableCameraShutterSound) return 0;
	return %orig;
}
%end

%hook AVCapturePhotoSettings
- (void)setShutterSound:(unsigned int)arg1 {
	if (g_disableCameraShutterSound) {
		arg1 = 0;
	}
	%orig;
}
- (unsigned int)shutterSound {
	if (g_disableCameraShutterSound) return 0;
	return %orig;
}
%end

%end

// ============================================================================
// 额外功能 — 面容ID / 锁屏声音 / 解锁动画 / 通话 / 文件夹功能
// ============================================================================
%group ExtraHooks

#pragma mark - 自动解锁面容ID
%hook CSLockScreenSettings
- (bool)autoDismissUnlockedLockScreen {
    if (!g_autoDismissFaceID) return %orig;
    return 1;
}
%end

#pragma mark - 关闭锁屏/解锁声音
%hook SBLockScreenManager
- (bool)shouldPlayLockSound {
    if (!g_disableLockSound) return %orig;
    return 0;
}
%end

#pragma mark - 移除滑动解锁动画延迟
%hook SBLockScreenView
- (void)_startAnimatingSlideToUnlockWithDelay:(double)arg1 {
    if (!g_removeUnlockDelay) { %orig; return; }
    arg1 = 0;
    %orig;
}
%end

#pragma mark - 锁屏来电拒接按钮

%hook PHInCallUIUtilities
- (bool)isSpringBoardLocked {
    if (!g_inCallUnlocked) return %orig;
    return 0;
}
%end

%end

// ============================================================================
// 开关 K1：应用打开动画方向 — 修改 App Switcher 图标锚点位置
// ============================================================================
%group FluidSwitcherHooks

%hook SBFluidSwitcherViewController

// 将图标 frame 的 x/y 原点设到屏幕边缘，使打开动画从相应方向划入
- (CGRect)_iconImageFrameForIconView:(id)iconView {
	CGRect frame = %orig;
	if (g_appOpenAnimationDirection != AppOpenAnimationDirectionDisabled) {
		CGSize screenSize = [UIScreen mainScreen].bounds.size;
		CGFloat screenW = screenSize.width;
		CGFloat screenH = screenSize.height;
		switch (g_appOpenAnimationDirection) {
			case AppOpenAnimationDirectionRightToLeft:
				frame.origin.x = screenW - frame.size.width;
				break;
			case AppOpenAnimationDirectionLeftToRight:
				frame.origin.x = 0;
				break;
			case AppOpenAnimationDirectionTopToBottom:
				frame.origin.y = 0;
				break;
			case AppOpenAnimationDirectionBottomToTop:
				frame.origin.y = screenH - frame.size.height;
				break;
			default:
				break;
		}
	}
	return frame;
}

// 调整图标视图获取，传递 nil 让系统重新计算布局，从而使用我们修改后的 frame 锚点
- (id)_iconViewForDisplayItem:(id)displayItem isVisible:(BOOL *)isVisible {
	if (g_appOpenAnimationDirection != AppOpenAnimationDirectionDisabled) {
		// 置空 displayItem 触发从自定义锚点位置重建动画
		return %orig(nil, isVisible);
	}
	return %orig(displayItem, isVisible);
}

%end

%end

// ============================================================================
// 彻关 Wi-Fi / 蓝牙（从控制中心点击后彻底关闭，不只暂时断开）
// ============================================================================

@interface BluetoothManager (Addition)
@property (assign) BOOL ignoreAirplaneModeCheck;
@end

@interface WFWiFiStateMonitor : NSObject
@end

@interface WFControlCenterStateMonitor : WFWiFiStateMonitor
@end

@interface WFControlCenterStateMonitor (Addition)
@property (assign) BOOL forceAirplaneMode;
@end

// ============================================================================
// 锁屏自动低电量 — 私有类声明
// ============================================================================

@interface _CDBatterySaver : NSObject
+(id)batterySaver;
-(BOOL)setPowerMode:(long long)arg1 error:(id *)arg2;
@end

@interface SBCoverSheetPresentationManager : NSObject
+(id)sharedInstance;
-(BOOL)hasBeenDismissedSinceKeybagLock;
@end

@interface SBCoverSheetPrimarySlidingViewController : UIViewController
@end

// SBLockScreenManager 前向声明（ExtraHooks 中有 %hook，这里给 LowPowerOnLock 用）
@interface SBLockScreenManager : NSObject
+(instancetype)sharedInstance;
-(BOOL)isUILocked;
@end

// SpringBoard 前向声明（设备朝下自动锁屏用）
@interface SpringBoard : UIApplication
+(id)sharedApplication;
-(void)_simulateLockButtonPress;
@end

%group DisconnectWiFiBT

%hook BluetoothManager

- (void)bluetoothStateActionWithCompletion:(id)completion {
	if (!g_disconnectWiFiBT) { %orig; return; }
	BOOL shouldTurnOff = [[self valueForKey:@"_state"] intValue] == 3;
	if (shouldTurnOff) [self setValue:@(99) forKey:@"_state"];
	%orig;
	if (shouldTurnOff) {
		[self setValue:@(1) forKey:@"_state"];
		[self setPowered:NO];
		[self postNotification:@"BluetoothStateChangedNotification"];
	}
}

%end

%hook WFControlCenterStateMonitor

%property (assign) BOOL forceAirplaneMode;

- (BOOL)_airplaneModeEnabled {
	if (!g_disconnectWiFiBT) return %orig;
	return self.forceAirplaneMode ? YES : %orig;
}

- (void)performAction:(id)completion {
	if (!g_disconnectWiFiBT) { %orig; return; }
	self.forceAirplaneMode = YES;
	%orig;
	self.forceAirplaneMode = NO;
}

%end

%end

// ============================================================================
// 锁屏自动低电量 — 锁屏时自动开启低电模式，解锁后恢复
// ============================================================================
%group LowPowerOnLock

%hook SBSleepWakeHardwareButtonInteraction
-(void)_playLockSound {
	%orig;
	if (!g_lowPowerOnLock) return;
	if ([[%c(SBLockScreenManager) sharedInstance] isUILocked]) return;

	if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
		g_isLPMOnBeforeLock = YES;
	} else {
		[[%c(_CDBatterySaver) batterySaver] setPowerMode:1 error:nil];
		g_isLPMOnBeforeLock = NO;
	}
}
%end

%hook SBCoverSheetPrimarySlidingViewController
-(void)viewWillDisappear:(BOOL)arg1 {
	%orig;
	if (!g_lowPowerOnLock) return;
	if ([[%c(SBCoverSheetPresentationManager) sharedInstance] hasBeenDismissedSinceKeybagLock]) return;

	if (!g_isLPMOnBeforeLock) {
		[[%c(_CDBatterySaver) batterySaver] setPowerMode:0 error:nil];
	}
}
%end

%end

// ============================================================================
// 设备朝下自动锁屏 — 口袋检测状态变为 3（屏幕朝下）时模拟锁屏键
// ============================================================================
%group FaceDownLock

%hook SBIdleTimerGlobalStateMonitor
- (void)pocketStateMonitor:(id)arg1 pocketStateDidChangeFrom:(long long)arg2 to:(long long)arg3 {
	%orig;
	if (!g_lockWhenFaceDown) return;
	if (arg3 == 3) {
		[[%c(SpringBoard) sharedApplication] _simulateLockButtonPress];
	}
}
%end

%end


// ============================================================================
// Cyanide 可移植功能 — SpringBoard/锁屏/系统增强
// ============================================================================
%group CyanidePortableHooks

%hook SBCoverSheetPresentationManager
- (id)init {
	id ret = %orig;
	if (g_disableIconFlyIn) {
		@try {
			MSHookIvar<double>(self, "_iconFlyInTension") = 1.0e6;
			MSHookIvar<double>(self, "_iconFlyInFriction") = 1.0e6;
			MSHookIvar<double>(self, "_iconFlyInInteractiveResponseMin") = 0.0001;
			MSHookIvar<double>(self, "_iconFlyInInteractiveResponseMax") = 0.0001;
			MSHookIvar<double>(self, "_iconFlyInInteractiveDampingRatioMin") = 1.0;
			MSHookIvar<double>(self, "_iconFlyInInteractiveDampingRatioMax") = 1.0;
		} @catch (__unused NSException *exception) {}
	}
	return ret;
}
%end

%hook SBScreenWakeAnimationController
- (id)_animationSettingsForBacklightChangeSource:(long long)source isWake:(BOOL)isWake {
	id settings = %orig;
	if (settings && (g_zeroWakeAnimation || g_zeroBacklightFade)) {
		@try { MSHookIvar<double>(settings, "_backlightFadeDuration") = 0.0; } @catch (__unused NSException *exception) {}
	}
	if (settings && g_zeroWakeAnimation && isWake) {
		@try { MSHookIvar<double>(settings, "_speedMultiplierForWake") = 1000.0; } @catch (__unused NSException *exception) {}
		@try { MSHookIvar<double>(settings, "_speedMultiplierForLiftToWake") = 1000.0; } @catch (__unused NSException *exception) {}
		@try {
			id content = MSHookIvar<id>(settings, "_contentWakeSettings");
			if (content) {
				MSHookIvar<double>(content, "_durationBeforeContentAnimating") = 0.0;
				MSHookIvar<double>(content, "_contentFadeInDuration") = 0.0;
				MSHookIvar<double>(content, "_blurFadeAnimationDuration") = 0.0;
			}
		} @catch (__unused NSException *exception) {}
	}
	return settings;
}
%end

%hook SBIconController
- (void)viewDidAppear:(BOOL)animated {
	%orig;
	id controller = (id)self;
	if (g_doubleTapToLock && [controller respondsToSelector:@selector(view)]) {
		SPInstallDoubleTapGesture((UIView *)[controller performSelector:@selector(view)]);
	}
	SPRefreshStatusOverlay();
}
%end


%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	SPRefreshStatusOverlay();
	SPApplyOTAState();
}
%end

%hook SBAppSwitcherSettings
- (long long)switcherStyle {
	if (g_appSwitcherGrid) return 2;
	return %orig;
}
%end

%hook SBDeckSwitcherModifier
- (long long)dockUpdateMode {
	if (g_appSwitcherGrid) return 2;
	return %orig;
}
%end

%hook SBIconListGridLayoutConfiguration
- (unsigned long long)numberOfPortraitColumns {
	return SPLayoutCount(%orig, (NSUInteger)g_homeColumns);
}
- (unsigned long long)numberOfPortraitRows {
	return SPLayoutCount(%orig, (NSUInteger)g_homeRows);
}
- (BOOL)showsLabels {
	if (g_homeLayoutEnabled && g_hideIconLabels) return NO;
	return %orig;
}
%end

%hook SBIconListFlowLayout
- (unsigned long long)numberOfPortraitColumns {
	return SPLayoutCount(%orig, (NSUInteger)g_homeColumns);
}
- (unsigned long long)numberOfPortraitRows {
	return SPLayoutCount(%orig, (NSUInteger)g_homeRows);
}
%end

%hook SBDockIconListView
- (unsigned long long)iconColumnsForCurrentOrientation {
	return g_homeLayoutEnabled ? (NSUInteger)g_dockIconCount : %orig;
}
%end

%hook SBIconView
- (void)layoutSubviews {
	%orig;
	SPApplyIconViewScale((UIView *)self);
}
- (void)setLabelHidden:(BOOL)hidden {
	if (g_homeLayoutEnabled && g_hideIconLabels) hidden = YES;
	%orig(hidden);
}
%end

%end


// ============================================================================
// ===== CFNotification 回调 =====
// ============================================================================

static void onPrefsChanged(CFNotificationCenterRef center,
						   void *observer,
						   CFNotificationName name,
						   const void *object,
						   CFDictionaryRef userInfo) {
	reloadConfiguration();
	dispatch_async(dispatch_get_main_queue(), ^{
		SPRefreshStatusOverlay();
		SPApplyOTAState();
		SPApplyCallRecordingSound(g_callRecordingSound);
		SPApplyWatchNanoRegistry(g_nanoRegistryEnabled);
		SPApplyLocationSim(g_locationSimEnabled);
	});
}

static volatile bool g_isRespringing = false;

static const char *LSExecutablePath(const char *jbrootRelativePath, const char *rootlessPath, const char *rootfulPath) {
	char *(*jbrootFunction)(const char *) = (char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
	const char *resolvedPath = jbrootFunction ? jbrootFunction(jbrootRelativePath) : NULL;
	if (resolvedPath && access(resolvedPath, X_OK) == 0) return resolvedPath;
	if (rootlessPath && access(rootlessPath, X_OK) == 0) return rootlessPath;
	if (rootfulPath && access(rootfulPath, X_OK) == 0) return rootfulPath;
	return NULL;
}

static BOOL LSLaunchExecutable(const char *executablePath, char *const arguments[]) {
	if (!executablePath) return NO;
	pid_t processID = 0;
	return posix_spawn(&processID, executablePath, NULL, NULL, arguments, NULL) == 0;
}

static BOOL LSPerformRespring(void) {
	char *const sbreloadArguments[] = {(char *)"sbreload", NULL};
	const char *sbreloadPath = LSExecutablePath("/usr/bin/sbreload", "/var/jb/usr/bin/sbreload", "/usr/bin/sbreload");
	if (LSLaunchExecutable(sbreloadPath, sbreloadArguments)) return YES;

	char *const killallArguments[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};
	const char *killallPath = LSExecutablePath("/usr/bin/killall", "/var/jb/usr/bin/killall", "/usr/bin/killall");
	return LSLaunchExecutable(killallPath, killallArguments);
}

static void onRespring(CFNotificationCenterRef center,
					   void *observer,
					   CFNotificationName name,
					   const void *object,
					   CFDictionaryRef userInfo) {
	if (g_isRespringing) return;
	g_isRespringing = true;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!LSPerformRespring()) {
			g_isRespringing = false;
		}
	});
}

// ============================================================================
// ===== %ctor — 构造函数 =====
// ============================================================================

%ctor {
	@autoreleasepool {
		reloadConfiguration();

		// 核心功能 — 类必然存在
		%init(MainHooks);

		// 签名验证 hook — FBSSignatureValidationService 仅 iOS 14+ 存在
		if (NSClassFromString(@"FBSSignatureValidationService")) {
			%init(SignatureHooks);
		}

		// 相机快门 hook — 部分设备/版本可能缺少特定类
		if (NSClassFromString(@"AVCaptureIrisStillImageSettings")) {
			%init(CameraShutterHooks);
		}

		// 额外功能 — 所有类在 iOS 16 上应都存在
		%init(ExtraHooks);

		// Fluid Switcher 动画 — SBFluidSwitcherViewController 在 iOS 16 上存在
		if (NSClassFromString(@"SBFluidSwitcherViewController")) {
			%init(FluidSwitcherHooks);
		}

		// 彻关 Wi-Fi/蓝牙 — 预加载私有框架
		dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW);
		dlopen("/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit", RTLD_NOW);
		if (NSClassFromString(@"BluetoothManager") && NSClassFromString(@"WFControlCenterStateMonitor")) {
			%init(DisconnectWiFiBT);
		}

		// 锁屏自动低电量 — 类在 iOS 16 上存在
		if (NSClassFromString(@"SBSleepWakeHardwareButtonInteraction")) {
			%init(LowPowerOnLock);
		}

		// 设备朝下自动锁屏 — SBIdleTimerGlobalStateMonitor 类在 iOS 16 上存在
		if (NSClassFromString(@"SBIdleTimerGlobalStateMonitor")) {
			%init(FaceDownLock);
		}

		%init(CyanidePortableHooks);

		SPInstallAnimationSpeedHook();

		// 应用三个新移植功能（启动时执行）
		SPApplyCallRecordingSound(g_callRecordingSound);
		SPApplyWatchNanoRegistry(g_nanoRegistryEnabled);
		SPApplyLocationSim(g_locationSimEnabled);

		// 监听静音开关状态变化
		int ringerToken = 0;
		notify_register_dispatch("com.apple.springboard.ringerState",
			&ringerToken,
			dispatch_get_main_queue(),
			^(int t) {
				uint64_t state = 1;
				notify_get_state(t, &state);
				g_isRingerSilent = (state == 0);
			});

		// 初始读取静音状态
		{
			uint64_t state = 1;
			notify_get_state(ringerToken, &state);
			g_isRingerSilent = (state == 0);
		}

		// 注册配置变更和注销通知
		CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
		if (!c) return;

		CFNotificationCenterAddObserver(c, NULL, onPrefsChanged,
			(__bridge CFStringRef)kNotifyPrefsChanged, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);

		CFNotificationCenterAddObserver(c, NULL, onRespring,
			(__bridge CFStringRef)kNotifyRespring, NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
