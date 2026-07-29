#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#include <rootless.h>
static BOOL isOnSpringBoard;
static double SwitcherDismiss;

// static Class CASpringAnimationClass = Nil;
// static Class SBFAnimationSettingsClass = Nil;

static BOOL isSpeedEnable;
static BOOL isBounceEnable;
static int Speedvalue;
static int Bouncevalue;
static BOOL isFineTuneSpeedEnable;
static BOOL isFineTuneBounceEnable;
static double FineTuneSpeedValue;
static double FineTuneBounceValue;

static BOOL isFolderAnimationEnabled;
static BOOL isFolderAnimationBounceEnabled;
// static double FolderInitialVelocityValue;
// static double FolderSpeedValue;
// static double FolderStiffnessValue;
static double FolderMassValue;
static double FolderDampingValue;

static BOOL inAppAnimationEnabled;
static BOOL inAppAnimationBounceEnabled;
// static double InitialVelocityValue;
// static double VelocityValue;
// static double StiffnessValue;
static double MassValue;
static double DampingValue;
static double DurationValue;

static BOOL isScreenwakeEnable;
static BOOL isScreensleepEnable;
static double Screensleepvalue;
static double Screenwakevalue;

static BOOL isNoiconflyEnable;
static BOOL isNoiconshakingEnable;
static BOOL isNoiconZoominSwitcher;
static BOOL isNoWallZoominSwitcher;
static BOOL isInstantFolder;

// ========== Systempro 移植功能全局变量 ==========
// 通知不亮锁屏
static BOOL g_lsBlockEnabled = NO;
static NSInteger g_lsBlockMode = 2; // 0=低电 1=静音 2=始终
// 静音状态（监听 ringerState）
static BOOL g_isRingerSilent = NO;

static BOOL g_disableAppLibrary = NO;
static BOOL g_disableFlashlight = NO;
static BOOL g_disableCamera = NO;
static BOOL g_disableLockScreenCamera = NO;
static BOOL g_disableCameraShutterSound = NO;
static BOOL g_removeUnlockDelay = NO;
static BOOL g_inCallUnlocked = NO;
static NSInteger g_appOpenAnimationDirection = 0; // 0=禁用, 1=右到左, 2=左到右, 3=上到下, 4=下到上
static BOOL g_disconnectWiFiBT = NO;
static BOOL g_lockWhenFaceDown = NO;
static BOOL g_proMotion120Enabled = NO;
// ==============================================

void preferencesthings(){ //pref starts to look THICC
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"];

    //app close/open values
    isSpeedEnable = (prefs && [prefs objectForKey:@"isSpeedEnable"] ? [[prefs valueForKey:@"isSpeedEnable"] boolValue] : NO );
    isBounceEnable = (prefs && [prefs objectForKey:@"isBounceEnable"] ? [[prefs valueForKey:@"isBounceEnable"] boolValue] : NO );
    Speedvalue = (prefs && [prefs objectForKey:@"Speedvalue"] ? [[prefs valueForKey:@"Speedvalue"] integerValue] : 1 );
    Bouncevalue = (prefs && [prefs objectForKey:@"Bouncevalue"] ? [[prefs valueForKey:@"Bouncevalue"] integerValue] : 1 );
    isFineTuneSpeedEnable = (prefs && [prefs objectForKey:@"isFineTuneSpeedEnable"] ? [[prefs valueForKey:@"isFineTuneSpeedEnable"] boolValue] : NO );
    isFineTuneBounceEnable = (prefs && [prefs objectForKey:@"isFineTuneBounceEnable"] ? [[prefs valueForKey:@"isFineTuneBounceEnable"] boolValue] : NO );
    FineTuneSpeedValue = (prefs && [prefs objectForKey:@"FineTuneSpeedValue"] ? [[prefs valueForKey:@"FineTuneSpeedValue"] doubleValue] : 1 );
    FineTuneBounceValue = (prefs && [prefs objectForKey:@"FineTuneBounceValue"] ? [[prefs valueForKey:@"FineTuneBounceValue"] doubleValue] : 1 );

    //screen sleep/wake values
    isScreenwakeEnable = (prefs && [prefs objectForKey:@"isScreenwakeEnable"] ? [[prefs valueForKey:@"isScreenwakeEnable"] boolValue] : NO );
    isScreensleepEnable = (prefs && [prefs objectForKey:@"isScreensleepEnable"] ? [[prefs valueForKey:@"isScreensleepEnable"] boolValue] : NO );
    Screensleepvalue = (prefs && [prefs objectForKey:@"Screensleepvalue"] ? [[prefs valueForKey:@"Screensleepvalue"] doubleValue] : 0.01 );
    Screenwakevalue = (prefs && [prefs objectForKey:@"Screenwakevalue"] ? [[prefs valueForKey:@"Screenwakevalue"] doubleValue] : 2 );

    //folder values
    isFolderAnimationEnabled = (prefs && [prefs objectForKey:@"isFolderAnimationEnabled"] ? [[prefs valueForKey:@"isFolderAnimationEnabled"] boolValue] : NO );
    isFolderAnimationBounceEnabled = (prefs && [prefs objectForKey:@"isFolderBounceEnabled"] ? [[prefs valueForKey:@"isFolderBounceEnabled"] boolValue] : NO );
    // FolderInitialVelocityValue
    // FolderSpeedValue = (prefs && [prefs objectForKey:@"FolderVelocityValue"] ? [[prefs valueForKey:@"FolderVelocityValue"] doubleValue] : 1 );
    FolderDampingValue = (prefs && [prefs objectForKey:@"FolderDampingValue"] ? [[prefs valueForKey:@"FolderDampingValue"] doubleValue] : 0 );
    FolderMassValue = (prefs && [prefs objectForKey:@"FolderMassValue"] ? [[prefs valueForKey:@"FolderMassValue"] doubleValue] : 0 );
    // FolderStiffnessValue = (prefs && [prefs objectForKey:@"FolderStiffnessValue"] ? [[prefs valueForKey:@"FolderStiffnessValue"] doubleValue] : 1 );
    
    //extra
    isNoiconflyEnable = (prefs && [prefs objectForKey:@"nofly"] ? [[prefs valueForKey:@"nofly"] boolValue] : NO );
    isNoiconZoominSwitcher = (prefs && [prefs objectForKey:@"nozoom"] ? [[prefs valueForKey:@"nozoom"] boolValue] : NO );
    isNoWallZoominSwitcher = (prefs && [prefs objectForKey:@"noWPzoom"] ? [[prefs valueForKey:@"noWPzoom"] boolValue] : NO );
    isNoiconshakingEnable = (prefs && [prefs objectForKey:@"noshaking"] ? [[prefs valueForKey:@"noshaking"] boolValue] : NO );
    isInstantFolder = (prefs && [prefs objectForKey:@"InstantFolder"] ? [[prefs valueForKey:@"InstantFolder"] boolValue] : NO );

    // ========== Systempro 移植功能 ==========
    g_lsBlockEnabled = (prefs && [prefs objectForKey:@"lsBlockEnabled"] ? [[prefs valueForKey:@"lsBlockEnabled"] boolValue] : NO );
    g_lsBlockMode = (prefs && [prefs objectForKey:@"lsBlockMode"] ? [[prefs valueForKey:@"lsBlockMode"] integerValue] : 2 );
    g_disableAppLibrary = (prefs && [prefs objectForKey:@"disableAppLibrary"] ? [[prefs valueForKey:@"disableAppLibrary"] boolValue] : NO );
    g_disableFlashlight = (prefs && [prefs objectForKey:@"disableFlashlight"] ? [[prefs valueForKey:@"disableFlashlight"] boolValue] : NO );
    g_disableCamera = (prefs && [prefs objectForKey:@"disableCamera"] ? [[prefs valueForKey:@"disableCamera"] boolValue] : NO );
    g_disableLockScreenCamera = (prefs && [prefs objectForKey:@"disableLockScreenCamera"] ? [[prefs valueForKey:@"disableLockScreenCamera"] boolValue] : NO );
    g_disableCameraShutterSound = (prefs && [prefs objectForKey:@"disableCameraShutterSound"] ? [[prefs valueForKey:@"disableCameraShutterSound"] boolValue] : NO );
    g_removeUnlockDelay = (prefs && [prefs objectForKey:@"removeUnlockDelay"] ? [[prefs valueForKey:@"removeUnlockDelay"] boolValue] : NO );
    g_inCallUnlocked = (prefs && [prefs objectForKey:@"inCallUnlocked"] ? [[prefs valueForKey:@"inCallUnlocked"] boolValue] : NO );
    g_appOpenAnimationDirection = (prefs && [prefs objectForKey:@"appOpenAnimationDirection"] ? [[prefs valueForKey:@"appOpenAnimationDirection"] integerValue] : 0 );
    g_disconnectWiFiBT = (prefs && [prefs objectForKey:@"disconnectWiFiBT"] ? [[prefs valueForKey:@"disconnectWiFiBT"] boolValue] : NO );
    g_lockWhenFaceDown = (prefs && [prefs objectForKey:@"lockWhenFaceDown"] ? [[prefs valueForKey:@"lockWhenFaceDown"] boolValue] : NO );
    g_proMotion120Enabled = (prefs && [prefs objectForKey:@"proMotion120Enabled"] ? [[prefs valueForKey:@"proMotion120Enabled"] boolValue] : NO );
    // 兜底枚举值
    if (g_lsBlockMode < 0 || g_lsBlockMode > 2) g_lsBlockMode = 2;
    if (g_appOpenAnimationDirection < 0 || g_appOpenAnimationDirection > 4) g_appOpenAnimationDirection = 0;
}

void inAppSpeedPreferences(){
    NSMutableDictionary *prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:[NSString stringWithUTF8String:ROOT_PATH_VAR("/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist")]];

    //in-app values
    inAppAnimationEnabled = (prefs && [prefs objectForKey:@"InAppAnimationEnabled"] ? [[prefs valueForKey:@"InAppAnimationEnabled"] boolValue] : NO );
    inAppAnimationBounceEnabled = (prefs && [prefs objectForKey:@"isInAppBounceEnabled"] ? [[prefs valueForKey:@"isInAppBounceEnabled"] boolValue] : NO );
    // InitialVelocityValue
    // VelocityValue = (prefs && [prefs objectForKey:@"VelocityValue"] ? [[prefs valueForKey:@"VelocityValue"] doubleValue] : 1 );
    DampingValue = (prefs && [prefs objectForKey:@"DampingValue"] ? [[prefs valueForKey:@"DampingValue"] doubleValue] : 0 );
    MassValue = (prefs && [prefs objectForKey:@"DurationMassValue"] ? [[prefs valueForKey:@"DurationMassValue"] doubleValue] : 0 );
    // StiffnessValue = (prefs && [prefs objectForKey:@"StiffnessValue"] ? [[prefs valueForKey:@"StiffnessValue"] doubleValue] : 1 );
    DurationValue = (prefs && [prefs objectForKey:@"DurationMassValue"] ? [[prefs valueForKey:@"DurationMassValue"] doubleValue] : 0 );
}

//reverse number to make sliders go from left to right lol
static double reverseSpeedSliderValue(double input){
    double total = 0.45;
    return total - input;
}

static double reverseBounceSliderValue(double input){
    double total = 1.1;
    return total - input;
}

static double reverseTurnOffSpeed(double input){
    double total = 0.91;
    return total - input;
}

static double reverseAppSpeedSliderValue(double input){
    double total = 1.0;
    return total - input;
}

static double reverseFolderSliderValue(double input){
    double total = 1.0;
    return total - input;
}


//App Open animation and bouncing
%hook SBFFluidBehaviorSettings
    -(void)setResponse:(double)arg1{ //App open and close speed
        if(isSpeedEnable){
            if(!isFineTuneSpeedEnable){
                //Change speed value base on selector pos
                switch (Speedvalue){
                case 1:
                    %orig(0.37);
                    SwitcherDismiss = 0.2;
                    break;
                case 2: 
                    %orig(0.25);
                    SwitcherDismiss = 0.17;
                    break;
                case 3:
                    %orig(0.19);
                    SwitcherDismiss = 0.15;
                    break;
                case 4:
                    %orig(0.1);
                    SwitcherDismiss = 0.12;
                    break;
                case 5:   
                    %orig(0.07);
                    SwitcherDismiss = 0.1;
                    break;   
                default:
                    %orig;
                    SwitcherDismiss = -1;    
                    break;
                }
            }else{
                //Fine Tune Mode
                %orig(reverseSpeedSliderValue(FineTuneSpeedValue));
                //Check Speed Value and change SpringBoard and Switcher Dismiss speed accordingly
                if (reverseSpeedSliderValue(FineTuneSpeedValue) < 0.4 && reverseSpeedSliderValue(FineTuneSpeedValue) >= 0.37){
                    SwitcherDismiss = 0.2;
                    //SpringboardSpeed = 1.1;
                }else if(reverseSpeedSliderValue(FineTuneSpeedValue) < 0.37 && reverseSpeedSliderValue(FineTuneSpeedValue) >= 0.25){
                    SwitcherDismiss = 0.17;
                    //SpringboardSpeed = 1.3;
                }else if(reverseSpeedSliderValue(FineTuneSpeedValue) < 0.25 && reverseSpeedSliderValue(FineTuneSpeedValue) >= 0.19){
                    SwitcherDismiss = 0.15;
                    //SpringboardSpeed = 1.5;
                }else if(reverseSpeedSliderValue(FineTuneSpeedValue) < 0.19 && reverseSpeedSliderValue(FineTuneSpeedValue) >= 0.1){
                    SwitcherDismiss = 0.12;
                    //SpringboardSpeed = 1.75;
                }else if(reverseSpeedSliderValue(FineTuneSpeedValue) < 0.1){
                    SwitcherDismiss = 0.1;
                    //SpringboardSpeed = 2;                    
                }
            }            
        }else{
            %orig;
            SwitcherDismiss = -1;
            //SpringboardSpeed = -1;
        }
    }
    -(void)setDampingRatio:(double)arg1{ //App open and close bouncing (has a small side effect on iOS 13 and above with stock volume hud)
        if(isBounceEnable){
            if(!isFineTuneBounceEnable){
                switch (Bouncevalue){
                    case 1:
                        %orig(0.9);
                        break;
                    case 2:
                        %orig(0.8);
                        break;
                    case 3:
                        %orig(0.6);
                        break;
                    case 4:
                        %orig(0.4);
                        break;
                    case 5:
                        %orig(0.2);
                        break;
                    default:
                        %orig;
                        break;    
                }
            }else{
                %orig(reverseBounceSliderValue(FineTuneBounceValue));
            }
        }else{
            %orig;
        }
    }

%end

//Springboard speed (mostly for folder but might affect something else on springboard too)
%hook SBFAnimationSettings

    //folder starting speed
    // -(void)setInitialVelocity:(double)arg1{
    //     %orig;
    // }

    // -(void)setSpeed:(double)arg1{
    //     if(isInstantFolder){
    //         %orig(arg1);        
    //     }else{
    //         if (isFolderAnimationEnabled){
    //             %orig(arg1*FolderSpeedValue);
    //         }else{
    //             %orig;
    //         }
    //     }
    // }

    -(void)setDamping:(double)arg1{
        if(isInstantFolder){
            %orig;
        }else{
            if(isFolderAnimationEnabled && isFolderAnimationBounceEnabled){
                %orig(arg1*reverseFolderSliderValue(FolderDampingValue));
            }else{
                %orig;
            }
        }
    }

    //folder mass
    -(void)setMass:(double)arg1{
        if(isInstantFolder){
            %orig(arg1*0.0001);
        }else{
            if(isFolderAnimationEnabled){
                %orig(arg1*reverseFolderSliderValue(FolderMassValue));
            }else{
                %orig;
            }
        }
    }

    // -(void)setStiffness:(double)arg1{
    //     if(isInstantFolder){
    //         %orig;
    //     }else{
    //         if(isFolderAnimationEnabled){
    //             %orig(arg1*FolderStiffnessValue);
    //         }else{
    //             %orig;
    //         }
    //     }
    // }

%end

//In-App animation
%hook CASpringAnimation

    //start speed
    // -(void)setInitialVelocity:(double)arg1{
    //     %orig;
    // }

    //speed
    // - (void)setVelocity:(double)arg1{
    //     if(inAppAnimationEnabled){
    //         %orig(arg1 * VelocityValue);
    //     }else{
    //         %orig(arg1);
    //     }
    // }

    // -(void)setStiffness:(double)arg1{
    //     if(inAppAnimationEnabled){
    //         %orig(arg1 * StiffnessValue);
    //     }else{
    //         %orig(arg1);
    //     }
    // }

    //mass
    -(void)setMass:(double)arg1{ //in app speed
        if(inAppAnimationEnabled && !isOnSpringBoard){
            %orig(arg1 * reverseAppSpeedSliderValue(MassValue));
        }else{
            %orig(arg1);
        }
    }

    -(void)setDamping:(double)arg1{
        if((inAppAnimationEnabled && inAppAnimationBounceEnabled) && !isOnSpringBoard){
            %orig(arg1 * reverseAppSpeedSliderValue(DampingValue));
        }else{
            %orig(arg1);
        }
    }

    // - (void)setDuration:(double)arg1{
    //     if(inAppAnimationEnabled && !isOnSpringBoard){
    //         %orig(arg1 * 0.5);
    //     }else{
    //         %orig(arg1);
    //     }
    // }

%end

//In-App animation 2: electric boogaloo
// %hook CAAnimation

//     //duration
//    - (void)setDuration:(double)arg1{ //more in app speed but with more side effect 
//         if ([self isKindOfClass:[CASpringAnimationClass class]]) { //thanks fakeclockup
//             %orig(arg1);
//             return;
//         }
//         if(inAppAnimationEnabled){
//             %orig(arg1 * reverseAppSpeedSliderValue(DurationValue));
//         }else{
//             %orig;
//         }
//     }
    
// %end

//Screen Turn On and Off Speed
%hook SBFWakeAnimationSettings
    -(double)backlightFadeDuration{ //Screen turn off speed
        if(isScreensleepEnable){
            return reverseTurnOffSpeed(Screensleepvalue);
        }else{
            return %orig;
        }
    }
    -(double)speedMultiplierForWake{ //Screen turn on speed (might be glitchy)
        if(isScreenwakeEnable){
            return Screenwakevalue;
        }else{
            return %orig;
        }
    }
    -(double)speedMultiplierForLiftToWake{ //Screen turn on speed but for lift to wake (again might be glitchy)
        if(isScreenwakeEnable){
            return Screenwakevalue;
        }else{
            return %orig;
        }
    }
%end

//Extra extra
%hook SBFluidSwitcherAnimationSettings
    -(void)setWallpaperScaleInSwitcher:(double)arg1{ //Switcher wallpaper zoom out
        if(isNoWallZoominSwitcher){
            %orig(1);
        }else{
            %orig;
        }
    }    

    -(void)setHomeScreenScaleInSwitcher:(double)arg1{ //Switcher homescreen zoom out
        if(isNoiconZoominSwitcher){
            %orig(1);
        }else{
            %orig;
        }
    }

    -(double)emptySwitcherDismissDelay{ //Switcher fix when set speed too high
        if (SwitcherDismiss != -1){
            return SwitcherDismiss;
        }else{
            return %orig;
        }
    }
%end

%hook CSCoverSheetTransitionSettings
    -(BOOL)iconsFlyIn{ //fly in icon when unlock
        if(isNoiconflyEnable){
            return 0;
        }else{
            return 1;
        } 
    }	
%end

%hook SBIconView

    -(void)setEditingAnimationStrength:(CGFloat)arg1{
         if (isNoiconshakingEnable){ 
            %orig(0);
        }else{
            %orig(arg1);
        }
    }

%end

// ============================================================================
// ===== Systempro 移植功能 =====
// ============================================================================

// ============================================================================
// 通知不亮锁屏
// ============================================================================
%group LSBlockHooks

%hook SBNCScreenController
- (bool)canTurnOnScreenForNotificationRequest:(id)arg1 {
	if (!g_lsBlockEnabled) return %orig;
	return 0;
}
- (void)_turnOnScreen {
	if (!g_lsBlockEnabled) { %orig; return; }
}
%end

%hook SBLockScreenNotificationListController
- (void)_turnOnScreen {
	if (!g_lsBlockEnabled) { %orig; return; }
}
%end

%end

// ============================================================================
// 禁用 App 资源库
// ============================================================================
%group AppLibraryHooks

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

%end

// ============================================================================
// 禁用锁屏快捷操作（手电筒/相机图标）
// ============================================================================
%group LockScreenQuickHooks

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

%end

// ============================================================================
// 禁用锁屏相机按钮
// ============================================================================
%group LockScreenCameraHooks

%hook SpringBoard
- (bool)lockScreenCameraSupported {
	if (g_disableLockScreenCamera) return 0;
	return %orig;
}
%end

%end

// ============================================================================
// 禁用相机快门声
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
// 移除解锁动画延迟 / 锁屏来电拒接按钮
// ============================================================================
%group ExtraSystemHooks

%hook SBLockScreenView
- (void)_startAnimatingSlideToUnlockWithDelay:(double)arg1 {
	if (!g_removeUnlockDelay) { %orig; return; }
	arg1 = 0;
	%orig;
}
%end

%hook PHInCallUIUtilities
- (bool)isSpringBoardLocked {
	if (!g_inCallUnlocked) return %orig;
	return 0;
}
%end

%end

// ============================================================================
// 应用打开动画方向
// ============================================================================
%group FluidSwitcherDirectionHooks

%hook SBFluidSwitcherViewController
- (CGRect)_iconImageFrameForIconView:(id)iconView {
	CGRect frame = %orig;
	if (g_appOpenAnimationDirection != 0) {
		CGSize screenSize = [UIScreen mainScreen].bounds.size;
		switch (g_appOpenAnimationDirection) {
			case 1: // 从右向左
				frame.origin.x = screenSize.width - frame.size.width;
				break;
			case 2: // 从左向右
				frame.origin.x = 0;
				break;
			case 3: // 从上向下
				frame.origin.y = 0;
				break;
			case 4: // 从下向上
				frame.origin.y = screenSize.height - frame.size.height;
				break;
			default:
				break;
		}
	}
	return frame;
}

- (id)_iconViewForDisplayItem:(id)displayItem isVisible:(BOOL *)isVisible {
	if (g_appOpenAnimationDirection != 0) {
		return %orig(nil, isVisible);
	}
	return %orig(displayItem, isVisible);
}
%end

%end

// ============================================================================
// 彻关 Wi-Fi / 蓝牙
// ============================================================================
@interface BluetoothManager : NSObject
- (BOOL)setPowered:(BOOL)powered;
- (void)postNotification:(NSString *)notification;
@end

@interface WFWiFiStateMonitor : NSObject
@end

@interface WFControlCenterStateMonitor : WFWiFiStateMonitor
@end

@interface WFControlCenterStateMonitor (Addition)
@property (assign) BOOL forceAirplaneMode;
@end

@interface UIApplication (LockButton)
- (void)_simulateLockButtonPress;
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
// 设备朝下自动锁屏
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
// 120Hz ProMotion 强制高刷（移植自 ProMotion120）
// ============================================================================
#define TARGET_FPS 120

static BOOL deviceSupports120Hz(void) {
	static BOOL checked = NO;
	static BOOL supported = NO;
	if (!checked) {
		@autoreleasepool {
			Class CADisplayClass = NSClassFromString(@"CADisplay");
			if (CADisplayClass) {
				id mainDisplay = [CADisplayClass performSelector:@selector(mainDisplay)];
				if (mainDisplay) {
					NSArray *modes = [mainDisplay valueForKey:@"availableModes"];
					for (id mode in modes) {
						double rate = [[mode valueForKey:@"refreshRate"] doubleValue];
						if (rate >= 119.0) { supported = YES; break; }
					}
				}
			}
		}
		checked = YES;
	}
	return supported;
}

static BOOL shouldApplyGeneralHighFPSHooks(void) {
	return g_proMotion120Enabled && !isOnSpringBoard;
}

#ifndef __IPHONE_15_0
typedef struct { float minimum; float maximum; float preferred; } CAFrameRateRange;
#endif

@interface CADisplayMode : NSObject
@property (nonatomic, readonly) double refreshRate;
@end

@interface CADisplay : NSObject
+ (CADisplay *)mainDisplay;
@property (nonatomic, readonly) NSArray *availableModes;
- (void)setPreferences:(id)preferences;
@end

@interface ProMotion120PersistentSource : NSObject
@property (nonatomic, strong) CADisplayLink *persistentLink;
+ (instancetype)sharedInstance;
- (void)startPersistentRefresh;
@end

@implementation ProMotion120PersistentSource
+ (instancetype)sharedInstance {
	static ProMotion120PersistentSource *source = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ source = [[self alloc] init]; });
	return source;
}
- (void)startPersistentRefresh {
	if (self.persistentLink) return;
	self.persistentLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(persistentTick:)];
	if ([self.persistentLink respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
		CAFrameRateRange range;
		range.minimum = 10; range.maximum = TARGET_FPS; range.preferred = TARGET_FPS;
		[self.persistentLink setPreferredFrameRateRange:range];
	}
	[self.persistentLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)persistentTick:(CADisplayLink *)link {}
@end

%group ProMotion120Hooks

%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
	if (deviceSupports120Hz() && g_proMotion120Enabled) return TARGET_FPS;
	return %orig;
}
%end

%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)sel {
	CADisplayLink *link = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks()) {
		if ([link respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
			CAFrameRateRange range;
			range.minimum = 10; range.maximum = TARGET_FPS; range.preferred = TARGET_FPS;
			[link setPreferredFrameRateRange:range];
		} else if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
			[link setPreferredFramesPerSecond:0];
		}
	}
	return link;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks()) {
		CAFrameRateRange newRange;
		newRange.minimum = (range.minimum > 0 && range.minimum <= TARGET_FPS) ? range.minimum : 10;
		newRange.preferred = TARGET_FPS;
		newRange.maximum = TARGET_FPS;
		if (newRange.minimum > TARGET_FPS) newRange.minimum = 10;
		%orig(newRange);
	} else { %orig; }
}
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks()) { %orig(0); }
	else { %orig; }
}
- (void)setFrameInterval:(NSInteger)interval {
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks()) { %orig(1); }
	else { %orig; }
}
%end

@interface CAMetalLayer (Private)
@property (assign) NSUInteger maximumDrawableCount;
@end

%hook CAMetalLayer
- (NSUInteger)maximumDrawableCount {
	NSUInteger orig = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks() && orig < 3) return 3;
	return orig;
}
%end

%hook CAMetalDrawable
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks()) { %orig(1.0 / TARGET_FPS); }
	else { %orig; }
}
%end

%hook MTLCommandBuffer
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)minimumDuration {
	if (deviceSupports120Hz() && g_proMotion120Enabled && shouldApplyGeneralHighFPSHooks()) { %orig(drawable, 1.0 / TARGET_FPS); }
	else { %orig(drawable, minimumDuration); }
}
%end

@interface CADisplayPreferences : NSObject
@property (nonatomic, assign) double preferredRefreshRate;
@end
@interface CAMutableDisplayPreferences : CADisplayPreferences
@end

%hook CAMutableDisplayPreferences
- (void)setPreferredRefreshRate:(double)rate {
	if (deviceSupports120Hz() && g_proMotion120Enabled) { %orig(120.0); }
	else { %orig(rate); }
}
%end

%hook CADisplayPreferences
- (void)setPreferredRefreshRate:(double)rate {
	if (deviceSupports120Hz() && g_proMotion120Enabled) { %orig(120.0); }
	else { %orig(rate); }
}
%end

%hook CADisplay
- (void)setPreferences:(id)preferences {
	if (deviceSupports120Hz() && g_proMotion120Enabled && preferences) {
		@try {
			if ([preferences respondsToSelector:@selector(setPreferredRefreshRate:)]) {
				[preferences setValue:@(120.0) forKey:@"preferredRefreshRate"];
			}
		} @catch (NSException *exception) {}
	}
	%orig(preferences);
}
%end

%hook CAContext
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
	if (deviceSupports120Hz() && g_proMotion120Enabled) {
		CAFrameRateRange newRange = range;
		newRange.maximum = TARGET_FPS;
		if (newRange.preferred >= 60) newRange.preferred = TARGET_FPS;
		%orig(newRange);
	} else { %orig(range); }
}
- (void)setPreferredFrameRate:(float)rate {
	if (deviceSupports120Hz() && g_proMotion120Enabled && rate >= 60) { %orig(TARGET_FPS); }
	else { %orig(rate); }
}
%end

@interface CADynamicFrameRateSource : NSObject
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (CAFrameRateRange)preferredFrameRateRange;
@end
@interface CAFrameRateRangeGroup : NSObject
- (CAFrameRateRange)arbitratedRange;
@end

%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
	if (deviceSupports120Hz() && g_proMotion120Enabled) {
		CAFrameRateRange newRange;
		newRange.minimum = TARGET_FPS; newRange.maximum = TARGET_FPS; newRange.preferred = TARGET_FPS;
		%orig(newRange);
	} else { %orig(range); }
}
- (CAFrameRateRange)preferredFrameRateRange {
	CAFrameRateRange range = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled) {
		range.minimum = TARGET_FPS; range.maximum = TARGET_FPS; range.preferred = TARGET_FPS;
	}
	return range;
}
%end

%hook CAFrameRateRangeGroup
- (CAFrameRateRange)arbitratedRange {
	CAFrameRateRange range = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled) {
		range.minimum = TARGET_FPS; range.maximum = TARGET_FPS; range.preferred = TARGET_FPS;
	}
	return range;
}
%end

%end

// ============================================================================
// ===== %ctor 构造函数 =====
// ============================================================================
%ctor { //More pref
    @autoreleasepool {
        isOnSpringBoard = [[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.apple.springboard"];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)preferencesthings, CFSTR("com.hoangdus.speedsterprefs-updated"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        preferencesthings();
        inAppSpeedPreferences();

        // ===== Systempro 移植功能初始化 =====
        // 初始化无分组 hooks（Speedster 原有动画功能）
        %init;

        // 通知不亮锁屏
        %init(LSBlockHooks);

        // 禁用 App 资源库
        if (NSClassFromString(@"SBIconController")) {
            %init(AppLibraryHooks);
        }

        // 禁用锁屏快捷操作
        if (NSClassFromString(@"CSQuickActionsViewController")) {
            %init(LockScreenQuickHooks);
        }

        // 禁用锁屏相机按钮
        %init(LockScreenCameraHooks);

        // 禁用相机快门声
        if (NSClassFromString(@"AVCaptureIrisStillImageSettings")) {
            %init(CameraShutterHooks);
        }

        // 移除解锁延迟 / 来电拒接
        if (NSClassFromString(@"SBLockScreenView")) {
            %init(ExtraSystemHooks);
        }

        // 应用打开动画方向
        if (NSClassFromString(@"SBFluidSwitcherViewController")) {
            %init(FluidSwitcherDirectionHooks);
        }

        // 彻关 Wi-Fi/蓝牙
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit", RTLD_NOW);
        if (NSClassFromString(@"BluetoothManager") && NSClassFromString(@"WFControlCenterStateMonitor")) {
            %init(DisconnectWiFiBT);
        }

        // 设备朝下自动锁屏
        if (NSClassFromString(@"SBIdleTimerGlobalStateMonitor")) {
            %init(FaceDownLock);
        }

        // ProMotion 120Hz 强制高刷
        if (deviceSupports120Hz()) {
            %init(ProMotion120Hooks);
            if (isOnSpringBoard && g_proMotion120Enabled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[ProMotion120PersistentSource sharedInstance] startPersistentRefresh];
                });
            }
        }

        // 监听静音开关状态
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
    }
}
