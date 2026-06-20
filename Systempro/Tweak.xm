#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <BluetoothManager/BluetoothManager.h>

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
static NSString *const kDisconnectWiFiBTKey  = @"disconnectWiFiBT";
static NSString *const kLowPowerOnLockKey   = @"lowPowerOnLock";
static NSString *const kLockWhenFaceDownKey = @"lockWhenFaceDown";
static NSString *const kDisablePasteAlertKey  = @"disablePasteAlert";
static NSString *const kNotifyPrefsChanged = @"com.huayuarc.systempro.prefschanged";
static NSString *const kNotifyRespring     = @"com.huayuarc.systempro.respring";

// blockMode 值
typedef NS_ENUM(NSInteger, LSBlockMode) {
	LSBlockModeLowPower = 0,  // 低电模式
	LSBlockModeSilent   = 1,  // 静音模式
	LSBlockModeAlways   = 2,  // 始终不亮
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
static BOOL      g_rightToLeftAppOpen         = NO;
static BOOL      g_disconnectWiFiBT           = NO;
static BOOL      g_lowPowerOnLock             = NO;
static BOOL      g_lockWhenFaceDown           = NO;
static BOOL      g_disablePasteAlert          = NO;
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
		g_rightToLeftAppOpen         = [prefs[kRightToLeftAppOpenKey] boolValue];
		g_disconnectWiFiBT           = [prefs[kDisconnectWiFiBTKey] boolValue];
		g_lowPowerOnLock             = [prefs[kLowPowerOnLockKey] boolValue];
		g_lockWhenFaceDown           = [prefs[kLockWhenFaceDownKey] boolValue];
		g_disablePasteAlert          = [prefs[kDisablePasteAlertKey] boolValue];
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
// 开关 K1：从右到左打开应用动画 — 修改 App Switcher 图标锚点位置
// ============================================================================
%group FluidSwitcherHooks

%hook SBFluidSwitcherViewController

// 将图标 frame 的 x 原点设到屏幕右侧，使打开动画从右向左划入
- (CGRect)_iconImageFrameForIconView:(id)iconView {
	CGRect frame = %orig;
	if (g_rightToLeftAppOpen) {
		CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
		frame.origin.x = screenW - frame.size.width;
	}
	return frame;
}

// 调整图标视图获取，传递 nil 让系统从右侧重新计算布局
- (id)_iconViewForDisplayItem:(id)displayItem isVisible:(BOOL *)isVisible {
	if (g_rightToLeftAppOpen) {
		// 置空 displayItem 触发器从右侧重建
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
// 屏蔽 iOS 粘贴弹窗
// ============================================================================
@interface NSObject (SBUserNotificationAlertPasteHack)
- (void)_setActivated:(BOOL)activated;
- (void)_sendResponseAndCleanUp:(BOOL)cleanUp;
@end

%group PasteAlertHooks

%hook SBAlertItemsController

- (void)activateAlertItem:(id)alert {
	if (!g_disablePasteAlert) { %orig; return; }
	if ([alert isKindOfClass:NSClassFromString(@"SBUserNotificationAlert")]) {
		NSString *source = [alert valueForKey:@"_alertSource"];
		if ([source isEqualToString:@"pasted"]) {
			[alert _setActivated:NO];
			if ([alert respondsToSelector:@selector(_sendResponseAndCleanUp:)]) {
				[alert _sendResponseAndCleanUp:YES];
			}
			return;
		}
	}
	%orig;
}

%end

%hook DRPasteAnnouncer

- (void)announcePaste:(id)arg {
	if (!g_disablePasteAlert) { %orig; return; }
}

- (void)announcePaste:(id)arg replyHandler:(id)handler {
	if (!g_disablePasteAlert) { %orig; return; }
}

- (void)announceDeniedPaste {
	if (!g_disablePasteAlert) { %orig; return; }
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

static void onRespring(CFNotificationCenterRef center,
					   void *observer,
					   CFNotificationName name,
					   const void *object,
					   CFDictionaryRef userInfo) {
	// 防重入
	if (g_isRespringing) return;
	g_isRespringing = true;

	// 使用 sbreload 命令正常注销，避免 exit(0) 在 roothide 下导致无限循环
	dispatch_async(dispatch_get_main_queue(), ^{
		// libroothide 已加载到 SpringBoard 进程，运行时查找 jbroot 符号
		char *(*jbroot_fn)(const char *) = (char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
		if (!jbroot_fn) return;  // 安全兜底

		pid_t pid;
		const char *sbreload = jbroot_fn("/usr/bin/sbreload");
		const char *argv[] = {"sbreload", NULL};
		posix_spawn(&pid, sbreload, NULL, NULL, (char **)argv, NULL);
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

		// 屏蔽粘贴弹窗 — SBAlertItemsController 是 SpringBoard 类
		if (NSClassFromString(@"SBAlertItemsController")) {
			%init(PasteAlertHooks);
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
