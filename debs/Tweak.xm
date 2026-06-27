#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>
#import <BluetoothManager/BluetoothManager.h>
#import <objc/runtime.h>

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

// ===== Cyanide 移植功能键 =====
static NSString *const kDoubleTapToLockKey  = @"doubleTapToLock";
static NSString *const kDoubleTapToWakeKey  = @"doubleTapToWake";
static NSString *const kDisableIconFlyInKey = @"disableIconFlyIn";
static NSString *const kZeroWakeAnimationKey = @"zeroWakeAnimation";
// ===== App Switcher Grid 增强 =====
// 模式: 0=off(deck), 1=grid, 2=auto
static int      g_switcherStyle        = 0;
static int      g_switcherColumns      = 4;      // 3-6 列
static CGFloat  g_switcherInsetTop     = 0;
static CGFloat  g_switcherInsetBottom  = 0;
static CGFloat  g_switcherInsetLeft    = 0;
static CGFloat  g_switcherInsetRight   = 0;
static NSString *const kSwitcherStyleKey    = @"switcherStyle";
static NSString *const kSwitcherColumnsKey  = @"switcherColumns";
static NSString *const kSwitcherInsetTopKey    = @"switcherInsetTop";
static NSString *const kSwitcherInsetBottomKey = @"switcherInsetBottom";
static NSString *const kSwitcherInsetLeftKey   = @"switcherInsetLeft";
static NSString *const kSwitcherInsetRightKey  = @"switcherInsetRight";
static NSString *const kHideAppLabelsKey    = @"hideAppLabels";
static NSString *const kCCRecordNoDelayKey  = @"ccRecordNoDelay";

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
// 锁屏自动低电 — 记录锁屏前低电模式状态
static BOOL      g_isLPMOnBeforeLock          = NO;

// ===== Cyanide 移植功能全局变量 =====
static BOOL      g_doubleTapToLock     = NO;
static BOOL      g_doubleTapToWake     = NO;
static BOOL      g_disableIconFlyIn    = NO;
static BOOL      g_zeroWakeAnimation   = NO;
static BOOL      g_hideAppLabels       = NO;

// ===== 录屏去延迟 =====
static BOOL      g_ccRecordNoDelay               = NO;
static BOOL      g_ccRecordNoDelayHooksInited    = NO;

// 双击锁屏 — 跟踪已添加的手势，防止重复添加
static UITapGestureRecognizer *g_doubleTapRecognizer = nil;
static BOOL      g_springBoardDidFinishLaunching = NO;
static BOOL      g_doubleTapInstallScheduled = NO;

// ===== 自定义动画速度 =====
static float g_animationSpeed = 1.0f;
static int g_animationSpeedIdx = 2; // 索引 0-4
// 速度倍率映射表：索引 → 实际倍率
static const float kAnimationSpeedValues[] = {0.25f, 0.5f, 1.0f, 2.0f, 4.0f};
static NSString *const kAnimationSpeedKey = @"animationSpeed";

static inline NSTimeInterval adjustedAnimationDuration(NSTimeInterval duration) {
	return (g_animationSpeed != 1.0f && duration > 0.0) ? duration / g_animationSpeed : duration;
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

		// ===== Cyanide 移植功能 =====
		g_doubleTapToLock     = [prefs[kDoubleTapToLockKey] boolValue];
		g_doubleTapToWake     = [prefs[kDoubleTapToWakeKey] boolValue];
		g_disableIconFlyIn    = [prefs[kDisableIconFlyInKey] boolValue];
		g_zeroWakeAnimation   = [prefs[kZeroWakeAnimationKey] boolValue];
		g_hideAppLabels       = [prefs[kHideAppLabelsKey] boolValue];
		g_ccRecordNoDelay     = [prefs[kCCRecordNoDelayKey] boolValue];

		// ===== App Switcher Grid 增强 =====
		{
			id styleVal = prefs[kSwitcherStyleKey];
			if (styleVal) {
				g_switcherStyle = [styleVal intValue];
			} else {
				// 兼容旧的 appSwitcherGrid 布尔设置
				g_switcherStyle = [prefs[@"appSwitcherGrid"] boolValue] ? 1 : 0;
			}
			if (g_switcherStyle < 0 || g_switcherStyle > 2) g_switcherStyle = 0;
			int cols = (int)[prefs[kSwitcherColumnsKey] integerValue];
			g_switcherColumns = (cols >= 3 && cols <= 6) ? cols : 4;
			g_switcherInsetTop    = [prefs[kSwitcherInsetTopKey] floatValue];
			g_switcherInsetBottom = [prefs[kSwitcherInsetBottomKey] floatValue];
			g_switcherInsetLeft   = [prefs[kSwitcherInsetLeftKey] floatValue];
			g_switcherInsetRight  = [prefs[kSwitcherInsetRightKey] floatValue];
		}

		// ===== 自定义动画速度 =====
		int speedIdx = (int)[prefs[kAnimationSpeedKey] integerValue];
		if (speedIdx < 0 || speedIdx > 4) speedIdx = 2;
		g_animationSpeedIdx = speedIdx;
		g_animationSpeed = kAnimationSpeedValues[speedIdx];

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

// ============================================================================
// ===== Cyanide 移植辅助函数 =====
// ============================================================================

// 双击锁屏 — 向主屏幕视图添加双击手势
static void scheduleDoubleTapGestureInstall(void);

static void installDoubleTapGesture(void) {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			installDoubleTapGesture();
		});
		return;
	}
	if (!g_doubleTapToLock) return;
	if (g_doubleTapRecognizer) return;
	if (!g_springBoardDidFinishLaunching) {
		scheduleDoubleTapGestureInstall();
		return;
	}

	@try {
		Class sbIconController = NSClassFromString(@"SBIconController");
		if (!sbIconController || ![sbIconController respondsToSelector:@selector(sharedInstance)]) return;
		id iconCtrl = [sbIconController performSelector:@selector(sharedInstance)];
		if (!iconCtrl || ![iconCtrl respondsToSelector:@selector(iconManager)]) return;

		// 通过 iconManager 拿到 rootFolderController 的 view
		id iconMgr = [iconCtrl performSelector:@selector(iconManager)];
		if (!iconMgr || ![iconMgr respondsToSelector:@selector(rootFolderController)]) return;
		id rootFC = [iconMgr performSelector:@selector(rootFolderController)];
		if (!rootFC || ![rootFC respondsToSelector:@selector(view)]) return;
		UIView *homeView = [rootFC performSelector:@selector(view)];
		if (!homeView) return;

		UIApplication *application = [UIApplication sharedApplication];
		if (![application respondsToSelector:@selector(_simulateLockButtonPress)]) return;

		g_doubleTapRecognizer = [[UITapGestureRecognizer alloc]
			initWithTarget:application
			action:@selector(_simulateLockButtonPress)];
		g_doubleTapRecognizer.numberOfTapsRequired = 2;
		g_doubleTapRecognizer.cancelsTouchesInView = NO;
		[homeView addGestureRecognizer:g_doubleTapRecognizer];
	} @catch (NSException *exception) {
		g_doubleTapRecognizer = nil;
	}
}

static void removeDoubleTapGesture(void) {
	if (!g_doubleTapRecognizer) return;
	[g_doubleTapRecognizer.view removeGestureRecognizer:g_doubleTapRecognizer];
	g_doubleTapRecognizer = nil;
}

static void scheduleDoubleTapGestureInstall(void) {
	if (!g_doubleTapToLock || g_doubleTapRecognizer || g_doubleTapInstallScheduled) return;
	g_doubleTapInstallScheduled = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		g_doubleTapInstallScheduled = NO;
		installDoubleTapGesture();
	});
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
- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	g_springBoardDidFinishLaunching = YES;
	if (g_doubleTapToLock) {
		scheduleDoubleTapGestureInstall();
	}
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

// Cyanide 移植 — SBFloatingDockController 私有方法声明
@interface SBFloatingDockController : UIViewController
-(void)_setHomeAffordanceHidden:(BOOL)hidden;
-(void)setWantsHomeGestureHidden:(BOOL)hidden;
@end

// 自定义动画速度 — 私有类声明
@interface SBIconAnimationController : NSObject
-(double)animationDuration;
@end

@interface SBCoverSheetAnimationController : NSObject
-(double)animationDuration;
@end

@interface SBUIAnimationController : NSObject
-(double)animationDuration;
@end

@interface SBFolderController : UIViewController
-(double)animationDuration;
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
// ===== Cyanide 移植功能 Group =====
// ============================================================================

// ============================================================================
// 2. Disable Icon Fly-In — 禁用锁屏图标飞入动画
// 移植自 Cyanide: tweaks/darksword_tweaks.m → darksword_tweak_disable_icon_fly_in_in_session
// ============================================================================
%group IconFlyInHooks

%hook SBCoverSheetPresentationManager
- (double)_iconFlyInTension {
	if (g_disableIconFlyIn) return 1000000.0;
	return %orig;
}
- (double)_iconFlyInFriction {
	if (g_disableIconFlyIn) return 1000000.0;
	return %orig;
}
- (double)_iconFlyInInteractiveResponseMin {
	if (g_disableIconFlyIn) return 0.0001;
	return %orig;
}
- (double)_iconFlyInInteractiveResponseMax {
	if (g_disableIconFlyIn) return 0.0001;
	return %orig;
}
- (double)_iconFlyInInteractiveDampingRatioMin {
	if (g_disableIconFlyIn) return 1.0;
	return %orig;
}
- (double)_iconFlyInInteractiveDampingRatioMax {
	if (g_disableIconFlyIn) return 1.0;
	return %orig;
}
%end

%end

// ============================================================================
// 3. Zero Wake Animation — 零唤醒动画（瞬间解锁）
// 移植自 Cyanide: tweaks/darksword_tweaks.m → darksword_tweak_zero_wake_animation_in_session
// ============================================================================
%group ZeroWakeHooks

%hook SBScreenWakeAnimationController
- (double)_backlightFadeDuration {
	if (g_zeroWakeAnimation) return 0.0;
	return %orig;
}
- (double)speedMultiplierForWake {
	if (g_zeroWakeAnimation) return 1000.0;
	return %orig;
}
- (double)_speedMultiplierForLiftToWake {
	if (g_zeroWakeAnimation) return 1000.0;
	return %orig;
}
%end

// 辅助: 让解锁后的回弹动画也消失 — hook SBIconController 动画速度
%hook SBIconController
- (double)maxScrollDuration {
	if (g_zeroWakeAnimation) return 0.0;
	return %orig;
}
%end

%end

// ============================================================================
// 7. Double Tap to Wake — 锁屏界面双击亮屏
// 原理: 修改 SBTapToWakeController 使其需要双击才能唤醒屏幕。
// 第一次点击被消费掉（不触发唤醒），第二次点击在 0.5 秒内才真正唤醒。
// ============================================================================
%group DoubleTapToWakeHooks

static int      g_wakeTapCount    = 0;
static CFTimeInterval g_lastWakeTapTime = 0;

%hook SBTapToWakeController
- (void)handleTapToWakeEvent:(id)arg1 {
	if (!g_doubleTapToWake) {%orig; return;}

	CFTimeInterval now = CACurrentMediaTime();
	if (now - g_lastWakeTapTime > 0.5) {
		// 第一次点击（或超时重置）— 消费掉，不唤醒
		g_wakeTapCount    = 1;
		g_lastWakeTapTime = now;
		return;
	}

	// 双击检测到 — 放行，触发真正的唤醒
	g_wakeTapCount    = 0;
	g_lastWakeTapTime = 0;
	%orig;
}
%end

%end

// ============================================================================
// 4. App Switcher Grid — 应用切换器网格布局（增强版）
// 移植自 Cyanide: tweaks/appswitchergrid.m
// 增强: 多模式选择、列数调整、卡片边距、调试日志
// switcherStyle: 0=off(deck), 1=grid, 2=auto(optional)
// ============================================================================
%group AppSwitcherGridHooks

%hook SBAppSwitcherSettings
- (long long)switcherStyle {
	// 0=deck, 1=optional, 2=grid
	if (g_switcherStyle == 1) return 2;  // 强制网格
	if (g_switcherStyle == 2) return 1;  // 自动(optional)
	return %orig;  // 停用=返回原始值(deck)
}
- (long long)numberOfColumns {
	if (g_switcherStyle != 0) return g_switcherColumns;
	return %orig;
}
%end

// 通过 SBFluidSwitcherViewController 调整卡片布局
%hook SBFluidSwitcherViewController
- (void)viewDidAppear:(BOOL)arg1 {
	%orig;
	if (g_switcherStyle != 0) {
		// 调试日志 — 实时输出当前布局参数
		NSLog(@"[Systempro] SwitcherGrid active: style=%d cols=%d "
			"insets{T:%.0f,B:%.0f,L:%.0f,R:%.0f}",
			g_switcherStyle, g_switcherColumns,
			g_switcherInsetTop, g_switcherInsetBottom,
			g_switcherInsetLeft, g_switcherInsetRight);
	}
}
- (void)_layoutSubviews {
	%orig;
	if (g_switcherStyle == 0) return;

	// 应用卡片边距调整 — 修改 switcherScrollView 的 contentInset
	UIScrollView *scrollView = [(id)self valueForKey:@"_switcherScrollView"];
	if (!scrollView) return;

	UIEdgeInsets insets = scrollView.contentInset;
	BOOL changed = NO;
	if (insets.top != g_switcherInsetTop)    { insets.top = g_switcherInsetTop;    changed = YES; }
	if (insets.bottom != g_switcherInsetBottom) { insets.bottom = g_switcherInsetBottom; changed = YES; }
	if (insets.left != g_switcherInsetLeft)  { insets.left = g_switcherInsetLeft;  changed = YES; }
	if (insets.right != g_switcherInsetRight){ insets.right = g_switcherInsetRight;changed = YES; }
	if (changed) {
		scrollView.contentInset = insets;
	}
}
%end

%end

// ============================================================================
// 5. Hide App Labels — 隐藏主屏幕应用图标标签
// 移植自 Cyanide: tweaks/sbcustomizer.m → hideLabels 参数
// ============================================================================
%group HideAppLabelsHooks

%hook SBIconView
- (void)setLabelHidden:(BOOL)hidden {
	if (g_hideAppLabels) {
		%orig(YES);
		return;
	}
	%orig;
}
- (BOOL)isLabelHidden {
	if (g_hideAppLabels) return YES;
	return %orig;
}
%end

%end

// ============================================================================
// 6. 自定义系统动画速度 — 控制 SpringBoard 全局动画速度
// 速度倍率: 0.25x(极慢) 0.5x(慢) 1x(正常) 2x(快) 4x(极快)
// ============================================================================
%group AnimationSpeedHooks

// UIKit 动画入口 — 不依赖 SpringBoard 私有类，确保设置始终生效
%hook UIView
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations {
	%orig(adjustedAnimationDuration(duration), animations);
}
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
	%orig(adjustedAnimationDuration(duration), animations, completion);
}
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(UIViewAnimationOptions)options animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
	%orig(adjustedAnimationDuration(duration), delay, options, animations, completion);
}
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay usingSpringWithDamping:(CGFloat)dampingRatio initialSpringVelocity:(CGFloat)velocity options:(UIViewAnimationOptions)options animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
	%orig(adjustedAnimationDuration(duration), delay, dampingRatio, velocity, options, animations, completion);
}
%end

// UIWindow._speed 影响窗口内 CALayer 动画速度
%hook UIWindow
- (CGFloat)_speed {
	if (g_animationSpeed != 1.0f) return g_animationSpeed;
	return %orig;
}
%end

%end

%group IconAnimationSpeedHooks
%hook SBIconAnimationController
- (double)animationDuration {
	return adjustedAnimationDuration(%orig);
}
%end
%end

%group CoverSheetAnimationSpeedHooks
%hook SBCoverSheetAnimationController
- (double)animationDuration {
	return adjustedAnimationDuration(%orig);
}
%end
%end

%group SBUIAnimationSpeedHooks
%hook SBUIAnimationController
- (double)animationDuration {
	return adjustedAnimationDuration(%orig);
}
%end
%end

%group FolderAnimationSpeedHooks
%hook SBFolderController
- (double)animationDuration {
	return adjustedAnimationDuration(%orig);
}
%end
%end

// ============================================================================
// 录屏去延迟 — Hook ReplayKit 控制中心模块跳过 3 秒倒计时
// 移植自 CCRecordNoDelay by LaYii
// 原理: NSBundle -load 检测 ReplayKitModule.bundle 加载后，
//        懒初始化 CCRecordNoDelayHooks，hook 倒计时方法。
// ============================================================================

// 录屏去延迟 Hook — %group 必须定义在 %init 引用之前
%group CCRecordNoDelayHooks

%hook RPControlCenterMenuModuleViewController
- (void)transitionToCountdownState {
	if (!g_ccRecordNoDelay) { %orig; return; }

	// 获取 _client 实例变量
	Ivar ivar = class_getInstanceVariable(object_getClass(self), "_client");
	if (!ivar) { %orig; return; }
	id client = object_getIvar(self, ivar);
	if (!client) { %orig; return; }

	// 关闭控制中心（无动画）
	Class ccCls = objc_getClass("SBControlCenterController");
	if (ccCls) {
		id cc = ((id (*)(Class, SEL))objc_msgSend)(ccCls, @selector(sharedInstance));
		if (cc) {
			((void (*)(id, SEL, BOOL))objc_msgSend)(cc, @selector(dismissAnimated:), NO);
		}
	}

	// 延迟 100ms 后直接开始录制，跳过倒计时
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
		dispatch_get_main_queue(), ^{
			((void (*)(id, SEL, id))objc_msgSend)(
				client, @selector(startRecordingWithHandler:), nil);
		});
}
%end

%end

// 录屏去延迟 — C 辅助函数（在 %group 外部，Logos 可正确解析 %init）
static void initCCRecordNoDelayHooks(void) {
	@try {
		%init(CCRecordNoDelayHooks);
	} @catch (NSException *e) {
		NSLog(@"[Systempro] CCRecordNoDelayHooks init failed: %@", e);
	}
}

// NSBundle 懒加载检测 — 始终初始化
%group NSBundleHooks

%hook NSBundle
- (BOOL)load {
	BOOL r = %orig;
	if (g_ccRecordNoDelay && !g_ccRecordNoDelayHooksInited &&
		[[self bundlePath] containsString:@"ReplayKitModule.bundle"]) {
		g_ccRecordNoDelayHooksInited = YES;
		initCCRecordNoDelayHooks();
	}
	return r;
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

	// 双击锁屏手势 — 动态添加/移除
	if (g_doubleTapToLock) {
		scheduleDoubleTapGestureInstall();
	} else {
		removeDoubleTapGesture();
	}

	// 录屏去延迟 — 运行时开启后尝试懒初始化 hook
	if (g_ccRecordNoDelay && !g_ccRecordNoDelayHooksInited) {
		initCCRecordNoDelayHooks();
		g_ccRecordNoDelayHooksInited = YES;
	}
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

		// NSBundle 懒加载检测 — 用于 ReplayKit 等动态加载模块的 hook
		%init(NSBundleHooks);

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

		// ===== Cyanide 移植功能初始化 =====

		// 禁用图标飞入动画 — SBCoverSheetPresentationManager iOS 16 上存在
		if (NSClassFromString(@"SBCoverSheetPresentationManager")) {
			%init(IconFlyInHooks);
		}

		// 零唤醒动画 — SBScreenWakeAnimationController iOS 16 上存在
		if (NSClassFromString(@"SBScreenWakeAnimationController")) {
			%init(ZeroWakeHooks);
		}

		// 双击亮屏 — SBTapToWakeController iOS 16 上存在
		if (NSClassFromString(@"SBTapToWakeController")) {
			%init(DoubleTapToWakeHooks);
		}

		// App Switcher Grid — SBAppSwitcherSettings iOS 16 上存在
		if (NSClassFromString(@"SBAppSwitcherSettings")) {
			%init(AppSwitcherGridHooks);
		}

		// 隐藏应用标签 — SBIconView iOS 16 上存在
		if (NSClassFromString(@"SBIconView")) {
			%init(HideAppLabelsHooks);
		}

		// 自定义动画速度 — UIKit hook 始终启用，私有类存在时再追加细分 hook
		%init(AnimationSpeedHooks);
		if (NSClassFromString(@"SBIconAnimationController")) {
			%init(IconAnimationSpeedHooks);
		}
		if (NSClassFromString(@"SBCoverSheetAnimationController")) {
			%init(CoverSheetAnimationSpeedHooks);
		}
		if (NSClassFromString(@"SBUIAnimationController")) {
			%init(SBUIAnimationSpeedHooks);
		}
		if (NSClassFromString(@"SBFolderController")) {
			%init(FolderAnimationSpeedHooks);
		}

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
