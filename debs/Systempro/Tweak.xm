#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>
#import <math.h>
#import <BluetoothManager/BluetoothManager.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
static NSString *const kIPadDockKey = @"ipadDock";
static NSString *const kInAppDockKey = @"inAppDock";
static NSString *const kRecentAppKey = @"recentApp";
static NSString *const kIPadMultitaskKey = @"iPadMultitask";
static NSString *const kNewSwitcherKey = @"newSwitcher";
static NSString *const kScreenModeKey = @"screenMode";
static NSString *const kDisableIconFlyInKey = @"disableIconFlyIn";

// SystemBox 移植功能键（只保留有实际 Hook 的功能）
static NSString *const kDoubleTapToLockKey = @"doubleTapToLock";
static NSString *const kLongPressToLockKey = @"longPressToLock";
static NSString *const kHomePullDownNotificationCenterKey = @"homePullDownNotificationCenter";
static NSString *const kHomePullDownControlCenterKey = @"homePullDownControlCenter";
static NSString *const kHomePullUpNotificationCenterKey = @"homePullUpNotificationCenter";
static NSString *const kHomePullUpControlCenterKey = @"homePullUpControlCenter";
static NSString *const kHideHomePageDotsKey = @"hideHomePageDots";
static NSString *const kHideHomeIconLabelsKey = @"hideHomeIconLabels";
static NSString *const kHideIconDotLabelsKey = @"hideIconDotLabels";
static NSString *const kHideWidgetLabelsKey = @"hideWidgetLabels";
static NSString *const kHideAllBadgesKey = @"hideAllBadges";
static NSString *const kHideStatusBarBreadcrumbKey = @"hideStatusBarBreadcrumb";
static NSString *const kHideLockScreenControlCenterGrabberKey = @"hideLockScreenControlCenterGrabber";
static NSString *const kDisableTodayViewKey = @"disableTodayView";
static NSString *const kDisableHomePullDownSearchKey = @"disableHomePullDownSearch";
static NSString *const kDisableAppLibraryPullDownKey = @"disableAppLibraryPullDown";
static NSString *const kDisableOpenFolderBackgroundKey = @"disableOpenFolderBackground";
static NSString *const kDisableScreenshotPreviewKey = @"disableScreenshotPreview";
static NSString *const kHideChargingAlertKey = @"hideChargingAlert";
static NSString *const kHideLowBatteryAlertKey = @"hideLowBatteryAlert";
static NSString *const kEnableFolder4x4Key = @"enableFolder4x4";
static NSString *const kForceZoomToSystemApertureKey = @"forceZoomToSystemAperture";
static NSString *const kMagicInteractionAnimationKey = @"magicInteractionAnimation";
static NSString *const kFakeBatteryPercentKey = @"fakeBatteryPercent";

// Cyanide 功能键
static NSString *const kCyanideHideHomeBarKey    = @"cyanide_hideHomeBar";
static NSString *const kCyanideDisableOTAKey      = @"cyanide_disableOTA";
static NSString *const kCyanideMuteCallRecordKey  = @"cyanide_muteCallRecord";
static NSString *const kCyanideNanoRegistryKey    = @"cyanide_nanoRegistry";

static NSString *const kNotifyPrefsChanged = @"com.huayuarc.systempro.prefschanged";
static NSString *const kNotifyRespring     = @"com.huayuarc.systempro.respring";

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
static BOOL      g_iPadDock                  = YES;
static BOOL      g_inAppDock                 = NO;
static BOOL      g_recentApp                 = NO;
static BOOL      g_iPadMultitask             = NO;
static BOOL      g_newSwitcher               = NO;
static NSInteger g_screenMode                = 0;
static BOOL      g_disableIconFlyIn          = NO;
static BOOL      g_doubleTapToLock           = NO;
static BOOL      g_longPressToLock           = NO;
static BOOL      g_homePullDownNotificationCenter = NO;
static BOOL      g_homePullDownControlCenter = NO;
static BOOL      g_homePullUpNotificationCenter = NO;
static BOOL      g_homePullUpControlCenter   = NO;
static BOOL      g_hideHomePageDots          = NO;
static BOOL      g_hideHomeIconLabels        = NO;
static BOOL      g_hideIconDotLabels         = NO;
static BOOL      g_hideWidgetLabels          = NO;
static BOOL      g_hideAllBadges             = NO;
static BOOL      g_hideStatusBarBreadcrumb   = NO;
static BOOL      g_hideLockScreenControlCenterGrabber = NO;
static BOOL      g_disableTodayView          = NO;
static BOOL      g_disableHomePullDownSearch = NO;
static BOOL      g_disableAppLibraryPullDown = NO;
static BOOL      g_disableOpenFolderBackground = NO;
static BOOL      g_disableScreenshotPreview  = NO;
static BOOL      g_hideChargingAlert         = NO;
static BOOL      g_hideLowBatteryAlert       = NO;
static BOOL      g_enableFolder4x4           = NO;
static BOOL      g_forceZoomToSystemAperture = NO;
static BOOL      g_magicInteractionAnimation = NO;
static NSString *g_fakeBatteryPercent        = nil;
// 锁屏自动低电 — 记录锁屏前低电模式状态
static BOOL      g_isLPMOnBeforeLock          = NO;

// Cyanide 功能缓存
static BOOL      g_cyanideHideHomeBar         = NO;
static BOOL      g_cyanideDisableOTA          = NO;
static BOOL      g_cyanideMuteCallRecord      = NO;
static BOOL      g_cyanideNanoRegistry        = NO;

// 前向声明（定义在文件后半部分的静态函数）
static void cyanide_applyDisableOTA(BOOL disabled);
static void cyanide_applyMuteCallRecord(BOOL mute);
static void cyanide_applyNanoRegistry(BOOL apply);


// ============================================================================
// SystemBox 移植 — 手势目标（保留 target，避免 UIGestureRecognizer 释放 target 后失效）
// ============================================================================
@interface SystemproLockGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SystemproLockGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
	return g_doubleTapToLock || g_longPressToLock;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
	return g_doubleTapToLock || g_longPressToLock;
}
- (void)lockDevice:(UIGestureRecognizer *)gesture {
	if (gesture.state != UIGestureRecognizerStateRecognized && gesture.state != UIGestureRecognizerStateBegan) return;
	id springBoard = [NSClassFromString(@"SpringBoard") sharedApplication];
	if ([springBoard respondsToSelector:@selector(_simulateLockButtonPress)]) {
		((void (*)(id, SEL))objc_msgSend)(springBoard, @selector(_simulateLockButtonPress));
	}
}
@end

@interface SystemproHomeGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) NSInteger action;
@end

@implementation SystemproHomeGestureTarget
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
	UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
	CGPoint velocity = [pan velocityInView:gestureRecognizer.view];
	CGPoint translation = [pan translationInView:gestureRecognizer.view];
	BOOL down = velocity.y > 120.0 && fabs(translation.x) * 1.25 <= fabs(velocity.y);
	BOOL up = velocity.y < -120.0 && fabs(translation.x) * 1.25 <= fabs(velocity.y);
	switch (self.action) {
		case 0: return g_homePullDownNotificationCenter && !g_homePullDownControlCenter && down;
		case 1: return g_homePullDownControlCenter && !g_homePullDownNotificationCenter && down;
		case 2: return g_homePullUpNotificationCenter && !g_homePullUpControlCenter && up;
		case 3: return g_homePullUpControlCenter && !g_homePullUpNotificationCenter && up;
		default: return NO;
	}
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
	return YES;
}
- (void)handlePan:(UIGestureRecognizer *)gesture {
	if (gesture.state != UIGestureRecognizerStateRecognized && gesture.state != UIGestureRecognizerStateEnded) return;
	BOOL wantsNotificationCenter = self.action == 0 || self.action == 2;
	Class controllerClass = NSClassFromString(wantsNotificationCenter ? @"SBNotificationCenterController" : @"SBControlCenterController");
	id controller = [controllerClass respondsToSelector:@selector(sharedInstance)] ? [controllerClass sharedInstance] : nil;
	if ([controller respondsToSelector:@selector(presentAnimated:completion:)]) {
		((void (*)(id, SEL, BOOL, id))objc_msgSend)(controller, @selector(presentAnimated:completion:), YES, nil);
	}
}
@end

static NSMutableArray *g_systemBoxGestureTargets;
static BOOL g_systemBoxGesturesInstalled = NO;

static void systemBoxInstallGestures(void) {
	if (g_systemBoxGesturesInstalled) return;
	if (!g_doubleTapToLock && !g_longPressToLock &&
		!g_homePullDownNotificationCenter && !g_homePullDownControlCenter &&
		!g_homePullUpNotificationCenter && !g_homePullUpControlCenter) {
		return;
	}
	UIWindow *window = [UIApplication sharedApplication].keyWindow;
	if (!window) window = [UIApplication sharedApplication].windows.firstObject;
	if (!window) return;

	g_systemBoxGestureTargets = [NSMutableArray array];
	if (g_doubleTapToLock || g_longPressToLock) {
		SystemproLockGestureTarget *target = [SystemproLockGestureTarget new];
		[g_systemBoxGestureTargets addObject:target];
		if (g_doubleTapToLock) {
			UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(lockDevice:)];
			tap.numberOfTapsRequired = 2;
			tap.delegate = target;
			[window addGestureRecognizer:tap];
		}
		if (g_longPressToLock) {
			UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(lockDevice:)];
			press.minimumPressDuration = 0.6;
			press.delegate = target;
			[window addGestureRecognizer:press];
		}
	}

	for (NSInteger action = 0; action < 4; action++) {
		BOOL enabled = (action == 0 && g_homePullDownNotificationCenter) ||
			(action == 1 && g_homePullDownControlCenter) ||
			(action == 2 && g_homePullUpNotificationCenter) ||
			(action == 3 && g_homePullUpControlCenter);
		if (!enabled) continue;
		SystemproHomeGestureTarget *target = [SystemproHomeGestureTarget new];
		target.action = action;
		[g_systemBoxGestureTargets addObject:target];
		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(handlePan:)];
		pan.delegate = target;
		[window addGestureRecognizer:pan];
	}
	g_systemBoxGesturesInstalled = YES;
}

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
		g_iPadDock                  = prefs[kIPadDockKey] ? [prefs[kIPadDockKey] boolValue] : YES;
		g_inAppDock                 = [prefs[kInAppDockKey] boolValue];
		g_recentApp                 = [prefs[kRecentAppKey] boolValue];
		g_iPadMultitask             = [prefs[kIPadMultitaskKey] boolValue];
		g_newSwitcher               = [prefs[kNewSwitcherKey] boolValue];
		g_screenMode                = prefs[kScreenModeKey] ? [prefs[kScreenModeKey] integerValue] : 0;
		g_disableIconFlyIn          = [prefs[kDisableIconFlyInKey] boolValue];

		g_doubleTapToLock           = [prefs[kDoubleTapToLockKey] boolValue];
		g_longPressToLock           = [prefs[kLongPressToLockKey] boolValue];
		g_homePullDownNotificationCenter = [prefs[kHomePullDownNotificationCenterKey] boolValue];
		g_homePullDownControlCenter = [prefs[kHomePullDownControlCenterKey] boolValue];
		g_homePullUpNotificationCenter = [prefs[kHomePullUpNotificationCenterKey] boolValue];
		g_homePullUpControlCenter   = [prefs[kHomePullUpControlCenterKey] boolValue];

		g_hideHomePageDots          = [prefs[kHideHomePageDotsKey] boolValue];
		g_hideHomeIconLabels        = [prefs[kHideHomeIconLabelsKey] boolValue];
		g_hideIconDotLabels         = [prefs[kHideIconDotLabelsKey] boolValue];
		g_hideWidgetLabels          = [prefs[kHideWidgetLabelsKey] boolValue];
		g_hideAllBadges             = [prefs[kHideAllBadgesKey] boolValue];
		g_hideStatusBarBreadcrumb   = [prefs[kHideStatusBarBreadcrumbKey] boolValue];
		g_hideLockScreenControlCenterGrabber = [prefs[kHideLockScreenControlCenterGrabberKey] boolValue];
		g_disableTodayView          = [prefs[kDisableTodayViewKey] boolValue];
		g_disableHomePullDownSearch = [prefs[kDisableHomePullDownSearchKey] boolValue];
		g_disableAppLibraryPullDown = [prefs[kDisableAppLibraryPullDownKey] boolValue];
		g_disableOpenFolderBackground = [prefs[kDisableOpenFolderBackgroundKey] boolValue];
		g_disableScreenshotPreview  = [prefs[kDisableScreenshotPreviewKey] boolValue];
		g_hideChargingAlert         = [prefs[kHideChargingAlertKey] boolValue];
		g_hideLowBatteryAlert       = [prefs[kHideLowBatteryAlertKey] boolValue];
		g_enableFolder4x4           = [prefs[kEnableFolder4x4Key] boolValue];
		g_forceZoomToSystemAperture = [prefs[kForceZoomToSystemApertureKey] boolValue];
		g_magicInteractionAnimation = [prefs[kMagicInteractionAnimationKey] boolValue];

		id fakeBatteryPercentValue = prefs[kFakeBatteryPercentKey];
		if ([fakeBatteryPercentValue isKindOfClass:[NSString class]]) {
			g_fakeBatteryPercent = [(NSString *)fakeBatteryPercentValue copy];
		} else if ([fakeBatteryPercentValue respondsToSelector:@selector(stringValue)]) {
			g_fakeBatteryPercent = [fakeBatteryPercentValue stringValue];
		} else {
			g_fakeBatteryPercent = nil;
		}

		// Cyanide 功能
		g_cyanideHideHomeBar     = [prefs[kCyanideHideHomeBarKey] boolValue];
		g_cyanideDisableOTA      = [prefs[kCyanideDisableOTAKey] boolValue];
		g_cyanideMuteCallRecord  = [prefs[kCyanideMuteCallRecordKey] boolValue];
		g_cyanideNanoRegistry    = [prefs[kCyanideNanoRegistryKey] boolValue];

		// 兜底：确保枚举值不越界
		// 兜底：确保枚举值不越界
		if (g_blockMode != LSBlockModeLowPower &&
			g_blockMode != LSBlockModeSilent &&
			g_blockMode != LSBlockModeAlways) {
			g_blockMode = LSBlockModeAlways;
		}

		// 应用 Cyanide 文件级功能
		cyanide_applyDisableOTA(g_cyanideDisableOTA);
		cyanide_applyMuteCallRecord(g_cyanideMuteCallRecord);
		cyanide_applyNanoRegistry(g_cyanideNanoRegistry);
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

// ============================================================================
// ===== Logos Hooks// ============================================================================
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

// SpringBoard 前向声明
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
// SystemBox 移植 — 主屏隐藏/禁用类功能
// ============================================================================
%group SystemBoxHomeScreenHooks

%hook SBRootFolderView
- (void)setPageControlHidden:(BOOL)hidden {
	%orig(g_hideHomePageDots ? YES : hidden);
}

- (void)layoutSubviews {
	%orig;
	if (g_hideHomePageDots) {
		((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setPageControlHidden:), YES);
	}
}
%end

%hook SBIconListPageControl
- (void)setHidden:(BOOL)hidden {
	%orig(g_hideHomePageDots ? YES : hidden);
}
%end

%hook SBIconView
- (void)setLabelHidden:(BOOL)hidden {
	%orig(g_hideHomeIconLabels ? YES : hidden);
}
%end

%hook SBIconDotLabelAccessoryView
- (void)setHidden:(BOOL)hidden {
	%orig(g_hideIconDotLabels ? YES : hidden);
}
%end

%hook SBHIconManager
- (BOOL)iconViewDisplaysLabel:(id)iconView {
	if (g_hideHomeIconLabels) return NO;
	return %orig(iconView);
}

- (BOOL)iconManager:(id)manager iconViewDisplaysLabel:(id)iconView {
	if (g_hideHomeIconLabels) return NO;
	return %orig(manager, iconView);
}
%end

%hook SBIconBadgeView
- (void)setHidden:(BOOL)hidden {
	%orig(g_hideAllBadges ? YES : hidden);
}
%end

%hook SBRootFolderController
- (void)setTodayViewPageHidden:(BOOL)hidden {
	%orig(g_disableTodayView ? YES : hidden);
}
%end

%hook SBHLibrarySearchController
- (BOOL)spotlightPresenterAllowsPullToSearch {
	if (g_disableAppLibraryPullDown) return NO;
	return %orig;
}
%end

%hook SBSearchGesture
- (BOOL)searchScrollViewShouldRecognize:(id)scrollView {
	if (g_disableHomePullDownSearch) return NO;
	return %orig(scrollView);
}
%end

%end

%group SystemBoxWidgetHooks

%hook SBHWidgetContainerView
- (void)setTitleLabel:(id)label {
	%orig(label);
	if (g_hideWidgetLabels && [label respondsToSelector:@selector(setHidden:)]) {
		[label setHidden:YES];
	}
}
%end

%hook SBHWidgetWrapperView
- (void)setTitleAndSubtitleVisible:(BOOL)visible {
	%orig(g_hideWidgetLabels ? NO : visible);
}
%end

%hook SBHWidgetWrapperViewController
- (void)setTitleAndSubtitleVisible:(BOOL)visible {
	%orig(g_hideWidgetLabels ? NO : visible);
}
%end

%end

%group SystemBoxFolderHooks

%hook SBFolderView
- (void)setBackgroundBlurEnabled:(BOOL)enabled {
	%orig(g_disableOpenFolderBackground ? NO : enabled);
}
%end

%hook SBFolderBackgroundView
- (void)setHidden:(BOOL)hidden {
	%orig(g_disableOpenFolderBackground ? YES : hidden);
}
%end

%end

%group SystemBoxStatusBarHooks

%hook SBDeviceApplicationSceneStatusBarBreadcrumbProvider
- (BOOL)_shouldAddBreadcrumbToActivatingSceneEntity:(id)entity sceneHandle:(id)handle withTransitionContext:(id)context {
	if (g_hideStatusBarBreadcrumb) return NO;
	return %orig(entity, handle, context);
}
%end

%hook UIStatusBarBatteryPercentItemView
- (id)_percentString {
	if (g_fakeBatteryPercent.length > 0 && ![g_fakeBatteryPercent isEqualToString:@"0"]) {
		return [NSString stringWithFormat:@"%@%%", g_fakeBatteryPercent];
	}
	return %orig;
}
%end

%end

%group SystemBoxLockScreenHooks

%hook SBHomeGrabberView
- (void)setHidden:(BOOL)hidden {
	%orig(g_hideLockScreenControlCenterGrabber ? YES : hidden);
}
%end

%end

%group SystemBoxTodayViewHooks

%hook SBMainDisplayPolicyAggregator
- (BOOL)_allowsCapabilityTodayViewWithExplanation:(id)explanation {
	if (g_disableTodayView) return NO;
	return %orig(explanation);
}

- (BOOL)_allowsCapabilityLockScreenTodayViewWithExplanation:(id)explanation {
	if (g_disableTodayView) return NO;
	return %orig(explanation);
}
%end

%hook SBTodayViewController
- (void)setTodayViewPageHidden:(BOOL)hidden {
	%orig(g_disableTodayView ? YES : hidden);
}
%end

%end

%group SystemBoxAlertHooks

%hook SBAlertItemsController
- (void)activateAlertItem:(id)item animated:(BOOL)animated {
	Class lowPowerAlertClass = NSClassFromString(@"SBLowPowerAlertItem");
	Class chargingAlertClass = NSClassFromString(@"SBLockScreenBatteryChargingViewController");
	if (g_hideLowBatteryAlert && lowPowerAlertClass && [item isKindOfClass:lowPowerAlertClass]) {
		return;
	}
	if (g_hideChargingAlert && chargingAlertClass && [item isKindOfClass:chargingAlertClass]) {
		return;
	}
	%orig(item, animated);
}
%end

%hook SBChargingSystemApertureElementProvider
- (void)showChargeLevelWithBatteryVisible:(BOOL)visible {
	if (g_hideChargingAlert) return;
	%orig(visible);
}

- (id)powerElementWithBatteryCapacity:(id)capacity {
	if (g_hideChargingAlert) return nil;
	return %orig(capacity);
}
%end

%end

%group SystemBoxScreenshotPreviewHooks

%hook SSScreenshotsWindowRootViewController
- (void)setHidden:(BOOL)hidden {
	%orig(g_disableScreenshotPreview ? YES : hidden);
}
%end

%hook SBDarkeningImageView
- (void)setHidden:(BOOL)hidden {
	%orig(g_disableScreenshotPreview ? YES : hidden);
}
%end

%end

%group SystemBoxAnimationHooks

%hook SBFluidSwitcherViewController
- (BOOL)shouldZoomToSystemApertureForEvent:(id)event activeLayout:(id)layout {
	if (g_forceZoomToSystemAperture) return YES;
	return %orig(event, layout);
}
%end

%hook SBSwitcherModifier
- (id)applyUpdate:(id)update toDisplayItem:(id)item {
	if (g_magicInteractionAnimation) {
		id settingsClass = NSClassFromString(@"SBFluidSwitcherAnimationSettings");
		id settings = [settingsClass respondsToSelector:@selector(centralAnimationSettings)] ? [settingsClass performSelector:@selector(centralAnimationSettings)] : nil;
		if (settings) {
			[settings setValue:@(0.4) forKey:@"stiffness"];
			[settings setValue:@(0.8) forKey:@"damping"];
		}
	}
	return %orig(update, item);
}
%end

%hook SBHUnlockSettings
- (BOOL)iconsFlyIn {
	if (g_disableIconFlyIn) return NO;
	return %orig;
}
%end

%end

%group SystemBoxFolderGridHooks

%hook SBRootFolderControllerConfiguration
- (unsigned long long)numberOfColumnsForOrientation:(int)orientation {
	if (g_enableFolder4x4) return 4;
	return %orig(orientation);
}

- (unsigned long long)numberOfRowsForOrientation:(int)orientation {
	if (g_enableFolder4x4) return 4;
	return %orig(orientation);
}
%end

%hook SBIconListFlowLayout
- (unsigned long long)numberOfColumnsForOrientation:(int)orientation {
	if (g_enableFolder4x4) return 4;
	return %orig(orientation);
}

- (unsigned long long)numberOfRowsForOrientation:(int)orientation {
	if (g_enableFolder4x4) return 4;
	return %orig(orientation);
}
%end

%end

// ============================================================================
// Cyanide — 通话录音提示音静音
// ============================================================================

static NSString *const kCRSTargetDir = @"/var/mobile/Library/CallServices/Greetings/default";
static NSString *const kCRSBackupDir = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.callrecord.backup";

static const char *kCRSFileNames[] = {
	"StartDisclosureWithTone.m4a",
	"StopDisclosure.caf",
};

static NSData *cyanide_silentAudioData(void) {
	const int sampleRate = 8000;
	const int duration = 1;
	const int dataSize = sampleRate * duration;
	const int fileSize = 44 + dataSize;
	uint8_t *buf = (uint8_t *)malloc(fileSize);
	if (!buf) return nil;
	memcpy(buf, "RIFF", 4);
	uint32_t riffSize = fileSize - 8;
	memcpy(buf + 4, &riffSize, 4);
	memcpy(buf + 8, "WAVE", 4);
	memcpy(buf + 12, "fmt ", 4);
	uint32_t fmtSize = 16;
	memcpy(buf + 16, &fmtSize, 4);
	uint16_t audioFmt = 1;
	memcpy(buf + 20, &audioFmt, 2);
	uint16_t channels = 1;
	memcpy(buf + 22, &channels, 2);
	memcpy(buf + 24, &sampleRate, 4);
	uint32_t byteRate = sampleRate;
	memcpy(buf + 28, &byteRate, 4);
	uint16_t blockAlign = 1;
	memcpy(buf + 32, &blockAlign, 2);
	uint16_t bitsPerSample = 8;
	memcpy(buf + 34, &bitsPerSample, 2);
	memcpy(buf + 36, "data", 4);
	memcpy(buf + 40, &dataSize, 4);
	memset(buf + 44, 0, dataSize);
	return [NSData dataWithBytesNoCopy:buf length:fileSize freeWhenDone:YES];
}

static void cyanide_crsEnsureDirs(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	if (![fm fileExistsAtPath:kCRSBackupDir])
		[fm createDirectoryAtPath:kCRSBackupDir withIntermediateDirectories:YES attributes:nil error:nil];
	if (![fm fileExistsAtPath:kCRSTargetDir]) {
		[fm createDirectoryAtPath:kCRSTargetDir withIntermediateDirectories:YES attributes:nil error:nil];
		pid_t pid;
		const char *args[] = {"bash", "-c", "chmod 755 /var/mobile/Library/CallServices/Greetings 2>/dev/null; chmod 755 /var/mobile/Library/CallServices/Greetings/default 2>/dev/null", NULL};
		posix_spawn(&pid, "/bin/bash", NULL, NULL, (char *const *)args, NULL);
	}
}

static void cyanide_applyMuteCallRecord(BOOL mute) {
	cyanide_crsEnsureDirs();
	NSData *silentData = cyanide_silentAudioData();
	if (!silentData) return;
	NSFileManager *fm = [NSFileManager defaultManager];
	for (size_t i = 0; i < sizeof(kCRSFileNames) / sizeof(kCRSFileNames[0]); i++) {
		NSString *fileName = @(kCRSFileNames[i]);
		NSString *filePath = [kCRSTargetDir stringByAppendingPathComponent:fileName];
		NSString *backupPath = [kCRSBackupDir stringByAppendingPathComponent:[fileName stringByAppendingString:@".orig"]];
		if (mute) {
			if (![fm fileExistsAtPath:backupPath] && [fm fileExistsAtPath:filePath])
				[fm copyItemAtPath:filePath toPath:backupPath error:nil];
			[silentData writeToFile:filePath options:NSDataWritingAtomic error:nil];
		} else {
			if ([fm fileExistsAtPath:backupPath]) {
				[fm removeItemAtPath:filePath error:nil];
				[fm copyItemAtPath:backupPath toPath:filePath error:nil];
			}
		}
	}
}

// ============================================================================
// Cyanide — 禁用 OTA 更新
// ============================================================================

static NSString *const kOTADisabledPlistPath = @"/var/db/com.apple.xpc.launchd/disabled.plist";

static NSArray *cyanide_otaDaemonLabels(void) {
	return @[
		@"com.apple.mobile.softwareupdated",
		@"com.apple.OTATaskingAgent",
		@"com.apple.softwareupdateservicesd",
		@"com.apple.mobile.NRDUpdated",
	];
}

static void cyanide_applyDisableOTA(BOOL disabled) {
	NSError *readError = nil;
	NSMutableDictionary *plist = nil;
	NSData *data = [NSData dataWithContentsOfFile:kOTADisabledPlistPath options:NSDataReadingMappedAlways error:&readError];
	if (data.length == 0) {
		plist = [NSMutableDictionary dictionary];
	} else {
		plist = [[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:nil error:&readError] mutableCopy];
		if (![plist isKindOfClass:[NSMutableDictionary class]]) plist = [NSMutableDictionary dictionary];
	}
	BOOL changed = NO;
	for (NSString *label in cyanide_otaDaemonLabels()) {
		if (disabled) {
			if (![plist[label] boolValue]) { plist[label] = @YES; changed = YES; }
		} else {
			if (plist[label]) { [plist removeObjectForKey:label]; changed = YES; }
		}
	}
	if (!changed) return;
	NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
	if (outData.length == 0) return;
	if (![outData writeToFile:kOTADisabledPlistPath atomically:YES]) {
		pid_t pid;
		const char *args[] = {"bash", "-c", "chmod 644 /var/db/com.apple.xpc.launchd/disabled.plist 2>/dev/null; cat > /var/db/com.apple.xpc.launchd/disabled.plist", NULL};
		posix_spawn(&pid, "/bin/bash", NULL, NULL, (char *const *)args, NULL);
		[outData writeToFile:kOTADisabledPlistPath atomically:YES];
	}
}

// ============================================================================
// Cyanide — Watch 配对兼容
// ============================================================================

static NSString *const kNRPlistPath = @"/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist";
static NSString *const kNRKeyMax = @"maxPairingCompatibilityVersion";
static NSString *const kNRKeyMin = @"minPairingCompatibilityVersion";
static NSString *const kNRKeyMinChipID = @"minPairingCompatibilityVersionWithChipID";
static NSString *const kNRKeyMinQuick = @"minQuickSwitchCompatibilityVersion";

static void cyanide_applyNanoRegistry(BOOL apply) {
	NSError *error = nil;
	NSMutableDictionary *plist = nil;
	NSData *data = [NSData dataWithContentsOfFile:kNRPlistPath options:NSDataReadingMappedAlways error:&error];
	if (data.length > 0) {
		plist = [[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:nil error:&error] mutableCopy];
	}
	if (![plist isKindOfClass:[NSMutableDictionary class]]) plist = [NSMutableDictionary dictionary];
	if (apply) {
		plist[kNRKeyMax] = @99;
		plist[kNRKeyMin] = @23;
		plist[kNRKeyMinChipID] = @23;
		plist[kNRKeyMinQuick] = @99;
	} else {
		[plist removeObjectForKey:kNRKeyMax];
		[plist removeObjectForKey:kNRKeyMin];
		[plist removeObjectForKey:kNRKeyMinChipID];
		[plist removeObjectForKey:kNRKeyMinQuick];
	}
	NSData *outData = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
	if (outData.length == 0) return;
	[outData writeToFile:kNRPlistPath atomically:YES];
	notify_post("com.apple.nanoregistry.pairingcompatibilityversion");
}

// ============================================================================
// Cyanide — 隐藏 HomeBar（Logos hooks）
// ============================================================================
%group CyanideHideHomeBar

%hook SBFloatingDockController
- (void)_setHomeAffordanceHidden:(BOOL)hidden {
	%orig(g_cyanideHideHomeBar ? YES : hidden);
}
- (void)setWantsHomeGestureHidden:(BOOL)hidden {
	%orig(g_cyanideHideHomeBar ? YES : hidden);
}
%end

%hook CSHomeAffordanceView
- (void)setHidden:(BOOL)hidden {
	%orig(g_cyanideHideHomeBar ? YES : hidden);
}
- (void)setAlpha:(CGFloat)alpha {
	%orig(g_cyanideHideHomeBar ? 0.0 : alpha);
}
%end

%end

// ============================================================================
// iPad 功能 — Dock / 分屏 / 网格切换器
// ============================================================================
%group SystemproFloatingDock

%hook SBFloatingDockController
+ (BOOL)isFloatingDockSupported {
	return YES;
}
%end

%hook SBFloatingDockSuggestionsModel
- (void)_setRecentsEnabled:(BOOL)enabled {
	%orig(g_recentApp);
}
%end

%hook SBFloatingDockBehaviorAssertion
- (BOOL)gesturePossible {
	if (!g_inAppDock) return NO;
	return %orig;
}
%end

%hook SBIconListView
- (NSUInteger)iconRowsForCurrentOrientation {
	NSUInteger rows = %orig;
	if (rows < 4) return rows;
	return rows + 1;
}
%end

%end

%group SystemproIPadMultitask

@interface FBApplicationInfo
@property (nonatomic, retain, readonly) NSURL *executableURL;
@end

@interface SBApplicationInfo : FBApplicationInfo
@end

@interface SBApplication
@property (nonatomic, readonly) SBApplicationInfo *info;
@end

%hook SBPlatformController
- (NSInteger)medusaCapabilities {
	return 2;
}
%end

%hook SBMainWorkspace
- (BOOL)isMedusaEnabled {
	return YES;
}
%end

%hook SBApplication
- (BOOL)isMedusaCapable {
	NSString *path = [self.info.executableURL.path stringByDeletingLastPathComponent];
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
	NSArray *orientations = info[@"UISupportedInterfaceOrientations"];
	if ([orientations indexOfObject:@"UIInterfaceOrientationPortrait"] == NSNotFound) {
		return NO;
	}
	return YES;
}

- (BOOL)mainSceneWantsFullscreen {
	return g_screenMode != 0;
}
%end

%end

%group SystemproGridSwitcher
%hook SBAppSwitcherSettings
- (void)setSwitcherStyle:(NSInteger)style {
	%orig(2);
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

		// Cyanide — 隐藏 HomeBar
		if (NSClassFromString(@"SBFloatingDockController")) {
			%init(CyanideHideHomeBar);
		}

		// iPad 功能
		if (g_iPadDock && NSClassFromString(@"SBFloatingDockController")) {
			%init(SystemproFloatingDock);
			if (g_iPadMultitask && NSClassFromString(@"SBMainWorkspace")) {
				%init(SystemproIPadMultitask);
			}
		}

		if (g_newSwitcher && NSClassFromString(@"SBAppSwitcherSettings")) {
			%init(SystemproGridSwitcher);
		}

		if (NSClassFromString(@"SBRootFolderView")) {
			%init(SystemBoxHomeScreenHooks);
		}
		if (NSClassFromString(@"SBHWidgetWrapperView") || NSClassFromString(@"SBHWidgetContainerView")) {
			%init(SystemBoxWidgetHooks);
		}
		if (NSClassFromString(@"SBFolderView")) {
			%init(SystemBoxFolderHooks);
		}
		if (NSClassFromString(@"SBDeviceApplicationSceneStatusBarBreadcrumbProvider") || NSClassFromString(@"UIStatusBarBatteryPercentItemView")) {
			%init(SystemBoxStatusBarHooks);
		}
		if (NSClassFromString(@"SBHomeGrabberView")) {
			%init(SystemBoxLockScreenHooks);
		}
		if (NSClassFromString(@"SBMainDisplayPolicyAggregator") || NSClassFromString(@"SBTodayViewController")) {
			%init(SystemBoxTodayViewHooks);
		}
		if (NSClassFromString(@"SBAlertItemsController") || NSClassFromString(@"SBChargingSystemApertureElementProvider")) {
			%init(SystemBoxAlertHooks);
		}
		if (NSClassFromString(@"SSScreenshotsWindowRootViewController") || NSClassFromString(@"SBDarkeningImageView")) {
			%init(SystemBoxScreenshotPreviewHooks);
		}
		if (NSClassFromString(@"SBFluidSwitcherViewController") || NSClassFromString(@"SBHUnlockSettings")) {
			%init(SystemBoxAnimationHooks);
		}
		if (NSClassFromString(@"SBRootFolderControllerConfiguration") || NSClassFromString(@"SBIconListFlowLayout")) {
			%init(SystemBoxFolderGridHooks);
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			systemBoxInstallGestures();
		});

		// 监听静音开关状态变化		// 监听静音开关状态变化
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
