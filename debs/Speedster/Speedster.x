#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <objc/message.h>
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

// ========== 控制中心手势位置（左下角/右下角上拉打开控制中心）==========
static BOOL g_ccGestureLeft = NO;   // 左下角上拉打开控制中心
static BOOL g_ccGestureRight = NO;  // 右下角上拉打开控制中心

// ========== 新增 Systempro 移植功能全局变量 ==========
// Cyanide 系统工具
static BOOL g_cyanideMuteCallRecord = NO;
static BOOL g_cyanideDisableOTA = NO;
static BOOL g_cyanideNanoRegistry = NO;

// 禁用企业签名验证
static BOOL g_disableSignatureCheck = NO;

// 透明 Dock 背景
static BOOL g_transparentDock = NO;

// iPad Dock / 应用内 Dock / 最近应用
static BOOL g_iPadDock = YES;
static BOOL g_inAppDock = NO;
static BOOL g_recentApp = NO;

// iPhone 仿 iPad 网格后台
static BOOL g_gridSwitcherEnabled = NO;
static CGFloat g_gridScale = 0.3;
static CGFloat g_gridHorizontalSpacing = 10;
static CGFloat g_gridVerticalSpacing = 80;

// === Randy 功能 ===
static BOOL g_hideKeyboardGlobe = NO;     // 隐藏键盘地球图标
static BOOL g_hideKeyboardDictation = NO;  // 隐藏键盘语音图标
static BOOL g_bypassChargerCheck = NO;     // 绕过非原装充电器检测

// 画中画
static BOOL g_pictureInPicture = NO;

// 自动解锁面容ID
static BOOL g_autoDismissFaceID = NO;

// 关闭锁屏/解锁声音
static BOOL g_disableLockSound = NO;

// 去除录屏和直播三秒倒计时（作者：LaYii-LE⚕️管理）
static BOOL g_noRecordingCountdown = NO;

// Cyanide 功能前向声明（定义在文件后半部分）
static void cyanide_applyDisableOTA(BOOL disabled);
static void cyanide_applyMuteCallRecord(BOOL mute);
static void cyanide_applyNanoRegistry(BOOL apply);


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
    // ========== 控制中心手势位置偏好读取 ==========
    g_ccGestureLeft = (prefs && [prefs objectForKey:@"ccGestureLeft"] ? [[prefs valueForKey:@"ccGestureLeft"] boolValue] : NO );
    g_ccGestureRight = (prefs && [prefs objectForKey:@"ccGestureRight"] ? [[prefs valueForKey:@"ccGestureRight"] boolValue] : NO );
    // ========== Randy 功能偏好读取 ==========
    g_hideKeyboardGlobe = (prefs && [prefs objectForKey:@"hideKeyboardGlobe"] ? [[prefs valueForKey:@"hideKeyboardGlobe"] boolValue] : NO );
    g_hideKeyboardDictation = (prefs && [prefs objectForKey:@"hideKeyboardDictation"] ? [[prefs valueForKey:@"hideKeyboardDictation"] boolValue] : NO );
    g_bypassChargerCheck = (prefs && [prefs objectForKey:@"bypassChargerCheck"] ? [[prefs valueForKey:@"bypassChargerCheck"] boolValue] : NO );

    // ========== 新增 Systempro 移植功能偏好读取 ==========
    // Cyanide 系统工具
    g_cyanideMuteCallRecord = (prefs && [prefs objectForKey:@"cyanide_muteCallRecord"] ? [[prefs valueForKey:@"cyanide_muteCallRecord"] boolValue] : NO );
    g_cyanideDisableOTA = (prefs && [prefs objectForKey:@"cyanide_disableOTA"] ? [[prefs valueForKey:@"cyanide_disableOTA"] boolValue] : NO );
    g_cyanideNanoRegistry = (prefs && [prefs objectForKey:@"cyanide_nanoRegistry"] ? [[prefs valueForKey:@"cyanide_nanoRegistry"] boolValue] : NO );
    g_disableSignatureCheck = (prefs && [prefs objectForKey:@"disableSignatureCheck"] ? [[prefs valueForKey:@"disableSignatureCheck"] boolValue] : NO );
    g_transparentDock = (prefs && [prefs objectForKey:@"transparentDock"] ? [[prefs valueForKey:@"transparentDock"] boolValue] : NO );
    g_iPadDock = (prefs && [prefs objectForKey:@"ipadDock"] ? [[prefs valueForKey:@"ipadDock"] boolValue] : YES );
    g_inAppDock = (prefs && [prefs objectForKey:@"inAppDock"] ? [[prefs valueForKey:@"inAppDock"] boolValue] : NO );
    g_recentApp = (prefs && [prefs objectForKey:@"recentApp"] ? [[prefs valueForKey:@"recentApp"] boolValue] : NO );
    g_gridSwitcherEnabled = (prefs && [prefs objectForKey:@"gridSwitcherEnabled"] ? [[prefs valueForKey:@"gridSwitcherEnabled"] boolValue] : NO );
    g_gridScale = (prefs && [prefs objectForKey:@"gridScale"] ? [[prefs valueForKey:@"gridScale"] doubleValue] : 0.3 );
    g_gridHorizontalSpacing = (prefs && [prefs objectForKey:@"gridHorizontalSpacing"] ? [[prefs valueForKey:@"gridHorizontalSpacing"] doubleValue] : 10 );
    g_gridVerticalSpacing = (prefs && [prefs objectForKey:@"gridVerticalSpacing"] ? [[prefs valueForKey:@"gridVerticalSpacing"] doubleValue] : 80 );
    g_pictureInPicture = (prefs && [prefs objectForKey:@"pictureInPicture"] ? [[prefs valueForKey:@"pictureInPicture"] boolValue] : NO );
    g_autoDismissFaceID = (prefs && [prefs objectForKey:@"autoDismissFaceID"] ? [[prefs valueForKey:@"autoDismissFaceID"] boolValue] : NO );
    g_disableLockSound = (prefs && [prefs objectForKey:@"disableLockSound"] ? [[prefs valueForKey:@"disableLockSound"] boolValue] : NO );
    g_noRecordingCountdown = (prefs && [prefs objectForKey:@"noRecordingCountdown"] ? [[prefs valueForKey:@"noRecordingCountdown"] boolValue] : NO );

    // 兜底枚举值
    if (g_lsBlockMode < 0 || g_lsBlockMode > 2) g_lsBlockMode = 2;
    if (g_appOpenAnimationDirection < 0 || g_appOpenAnimationDirection > 4) g_appOpenAnimationDirection = 0;

    // 应用 Cyanide 文件级功能
    if (g_cyanideMuteCallRecord || g_cyanideDisableOTA || g_cyanideNanoRegistry) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            if (g_cyanideDisableOTA) cyanide_applyDisableOTA(YES);
            if (g_cyanideMuteCallRecord) cyanide_applyMuteCallRecord(YES);
            if (g_cyanideNanoRegistry) cyanide_applyNanoRegistry(YES);
        });
    }

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
                double ftValue = reverseSpeedSliderValue(FineTuneSpeedValue);
                %orig(ftValue);
                //Check Speed Value and change SpringBoard and Switcher Dismiss speed accordingly
                if (ftValue < 0.4 && ftValue >= 0.37){
                    SwitcherDismiss = 0.2;
                }else if(ftValue < 0.37 && ftValue >= 0.25){
                    SwitcherDismiss = 0.17;
                }else if(ftValue < 0.25 && ftValue >= 0.19){
                    SwitcherDismiss = 0.15;
                }else if(ftValue < 0.19 && ftValue >= 0.1){
                    SwitcherDismiss = 0.12;
                }else if(ftValue < 0.1){
                    SwitcherDismiss = 0.1;
                }
            }
        }else{
            %orig;
            SwitcherDismiss = -1;
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
%group DockAppLibraryPlaceholderHooks

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
// AudioServices 系统音频层 — 相机快门声兜底拦截
// 已知快门声 SystemSoundID: 1108,1109,1200~1203,1305,1306
// ============================================================================
static void (*orig_AudioServicesPlaySystemSound)(uint32_t inSystemSoundID);
static void hook_AudioServicesPlaySystemSound(uint32_t inSystemSoundID) {
    if (g_disableCameraShutterSound) {
        switch (inSystemSoundID) {
            case 1108: case 1109:
            case 1200: case 1201: case 1202: case 1203:
            case 1305: case 1306:
                return; // 静音拦截
            default:
                break;
        }
    }
    orig_AudioServicesPlaySystemSound(inSystemSoundID);
}

// ============================================================================
// AVCapturePhotoOutput — 捕获输出层快门声拦截
// ============================================================================
%group PhotoOutputShutterHooks

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)settings delegate:(id)delegate {
    if (g_disableCameraShutterSound) {
        if ([settings respondsToSelector:@selector(setShutterSound:)]) {
            ((void (*)(id, SEL, unsigned int))objc_msgSend)(settings, @selector(setShutterSound:), 0);
        }
    }
    %orig;
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

%hook CSLockScreenSettings
- (bool)autoDismissUnlockedLockScreen {
	if (!g_autoDismissFaceID) return %orig;
	return 1;
}
%end

%hook SBLockScreenManager
- (bool)shouldPlayLockSound {
	if (!g_disableLockSound) return %orig;
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
				frame.origin.x = screenSize.width;
				break;
			case 2: // 从左向右
				frame.origin.x = -frame.size.width;
				break;
			case 3: // 从上向下
				frame.origin.y = -frame.size.height;
				break;
			case 4: // 从下向上
				frame.origin.y = screenSize.height;
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
// ===== 新增 Systempro 移植功能 =====
// ============================================================================

// ============================================================================
// 禁用企业签名验证
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
// 透明 Dock 背景
// ============================================================================
%group DockViewHooks

%hook SBDockView
- (void)setBackgroundAlpha:(double)arg1 {
	if (g_transparentDock) {
		%orig(0);
	} else {
		%orig;
	}
}
%end

%end

// ============================================================================
// iPad Dock / 应用内 Dock / 最近应用
// ============================================================================
%group FloatingDockHooks

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

// ============================================================================
// iPhone 仿 iPad 网格后台
// ============================================================================
%group GridSwitcherHooks

%hook SBAppSwitcherSettings
- (void)setSwitcherStyle:(NSInteger)style {
	if (!g_gridSwitcherEnabled) {
		%orig(style);
		return;
	}
	%orig(2);
}

- (void)setGridSwitcherPageScale:(double)scale {
	if (!g_gridSwitcherEnabled) {
		%orig(scale);
		return;
	}
	%orig(g_gridScale);
}

- (void)setGridSwitcherHorizontalInterpageSpacingPortrait:(double)spacing {
	if (!g_gridSwitcherEnabled) {
		%orig(spacing);
		return;
	}
	%orig(g_gridHorizontalSpacing);
}

- (void)setGridSwitcherVerticalNaturalSpacingPortrait:(double)spacing {
	if (!g_gridSwitcherEnabled) {
		%orig(spacing);
		return;
	}
	%orig(g_gridVerticalSpacing);
}
%end

%end

// ============================================================================
// 画中画（强制启用 PiP 能力）
// ============================================================================
#define PIC_IN_PIC_KEY CFSTR("nVh/gwNpy7Jv1NOk00CMrw")

static Boolean (*orig_MGGetBoolAnswer)(CFStringRef string);
static Boolean hook_MGGetBoolAnswer(CFStringRef string) {
	if (CFEqual(string, PIC_IN_PIC_KEY)) {
		return YES;
	}
	return orig_MGGetBoolAnswer(string);
}

// ============================================================================
// 去除录屏和直播三秒倒计时
// 原作者：LaYii-LE⚕️管理
// ============================================================================
%group NoRecordingCountdownHooks

static void _closeControlCenterNoAnimation(void) {
    Class ccCls = objc_getClass("SBControlCenterController");
    if (!ccCls) return;
    id cc = ((id (*)(Class, SEL))objc_msgSend)(ccCls, @selector(sharedInstance));
    if (!cc) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(cc, @selector(dismissAnimated:), NO);
}

%hook RPControlCenterClient
- (void)startRecordingCountdown {
    _closeControlCenterNoAnimation();
    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(startRecordingWithHandler:), nil);
}
%end

%hook NSObject
- (void)performSelector:(SEL)aSelector withObject:(id)object afterDelay:(NSTimeInterval)delay inModes:(NSArray *)modes {
    if (aSelector == @selector(startRecord) || aSelector == @selector(startBroadcast)) {
        _closeControlCenterNoAnimation();
        %orig(aSelector, object, 0.0, modes);
        return;
    }
    %orig;
}
%end
%end

// ============================================================================
// ===== Randy 功能 =====
// ============================================================================

// === 隐藏键盘地球图标 ===
%group HideKeyboardGlobeHooks

%hook UIKeyboardLayoutStar
- (bool)showsInternationalKey {
	if (!g_hideKeyboardGlobe) return %orig;
	return 0;
}
%end

%hook UIKeyboardImpl
- (bool)shouldShowInternationalKey {
	if (!g_hideKeyboardGlobe) return %orig;
	return 0;
}
%end

%end

// === 隐藏键盘语音图标 ===
%group HideKeyboardDictationHooks

%hook UIKeyboardImpl
- (bool)shouldShowDictationKey {
	if (!g_hideKeyboardDictation) return %orig;
	return 0;
}
%end

%hook UIKeyboardLayoutStar
- (bool)showsDictationKey {
	if (!g_hideKeyboardDictation) return %orig;
	return 0;
}
- (bool)shouldShowDictationKey {
	if (!g_hideKeyboardDictation) return %orig;
	return 0;
}
%end

%end

// === 绕过非原装充电器检测 ===
%group BypassChargerHooks

%hook SBUIController
- (BOOL)isConnectedToUnsupportedChargingAccessory {
	if (!g_bypassChargerCheck) return %orig;
	return 0;
}
- (void)setIsConnectedToUnsupportedChargingAccessory:(BOOL)arg1 {
	if (g_bypassChargerCheck) arg1 = 0;
	%orig;
}
%end

%end

// ============================================================================
// Cyanide — 通话录音提示音静音
// ============================================================================
static NSString *const kCRSTargetDir = @"/var/mobile/Library/CallServices/Greetings/default";
static NSString *const kCRSBackupDir = @"/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.callrecord.backup";

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
// ===== 控制中心手势位置（左下角/右下角上拉打开控制中心）=====
// 移植自：HomeGesture 快捷手势（poqw312）
// ============================================================================

// 将触摸点归一化到竖屏坐标系（横屏时交换 x/y）
static CGPoint HGNormalizePointForPortrait(CGPoint point, CGSize screenSize) {
    if (screenSize.width > screenSize.height) {
        return CGPointMake(point.y, point.x);
    }
    return point;
}

// 判断触摸点是否在左下角控制中心区域
static BOOL HGPointIsInBottomLeftCorner(CGPoint point, CGSize screenSize) {
    if (screenSize.width <= 0 || screenSize.height <= 0) return NO;
    CGFloat screenWidth = MIN(screenSize.width, screenSize.height);
    CGFloat screenHeight = MAX(screenSize.width, screenSize.height);
    CGPoint p = HGNormalizePointForPortrait(point, screenSize);
    CGFloat allowedWidth = screenWidth * 0.35; // 稍微放宽一点点响应区域，提高触发成功率
    if (allowedWidth < 100.0) allowedWidth = 100.0;
    if (allowedWidth > 140.0) allowedWidth = 140.0;
    CGFloat allowedHeight = 90.0; // 适当提高一点底部判定高度
    return (p.x >= 0.0 && p.x <= allowedWidth && p.y >= (screenHeight - allowedHeight));
}

// 判断触摸点是否在右下角控制中心区域
static BOOL HGPointIsInBottomRightCorner(CGPoint point, CGSize screenSize) {
    if (screenSize.width <= 0 || screenSize.height <= 0) return NO;
    CGFloat screenWidth = MIN(screenSize.width, screenSize.height);
    CGFloat screenHeight = MAX(screenSize.width, screenSize.height);
    CGPoint p = HGNormalizePointForPortrait(point, screenSize);
    CGFloat allowedWidth = screenWidth * 0.30;
    if (allowedWidth < 96.0) allowedWidth = 96.0;
    if (allowedWidth > 132.0) allowedWidth = 132.0;
    CGFloat allowedHeight = 88.0; // 底部向上 88pt 的范围
    CGFloat rightEdgeStart = screenWidth - allowedWidth;
    return (p.x >= rightEdgeStart && p.x <= screenWidth && p.y >= (screenHeight - allowedHeight));
}

// 判断触摸是否落在任一已启用的角落区域
static BOOL HGIsTouchInActiveCCCorner(NSSet<UITouch *> *touches) {
    UITouch *touch = [touches anyObject];
    if (!touch) return NO;
    UIWindow *window = touch.window;
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    if (window && window.bounds.size.width > 0) {
        screenSize = window.bounds.size;
    }
    CGPoint point = [touch locationInView:window];
    if (g_ccGestureLeft && HGPointIsInBottomLeftCorner(point, screenSize)) return YES;
    if (g_ccGestureRight && HGPointIsInBottomRightCorner(point, screenSize)) return YES;
    return NO;
}

// 1. 指定控制中心呈现边缘（左下角/右下角）
%group CCGesturePositionHooks

%hook CCSControlCenterDefaults
- (unsigned long long)_defaultPresentationGesture {
    if (g_ccGestureLeft) return (unsigned long long)(UIRectEdgeBottom | UIRectEdgeLeft);
    if (g_ccGestureRight) return (unsigned long long)(UIRectEdgeBottom | UIRectEdgeRight);
    return %orig;
}
%end

%hook SBControlCenterController
- (unsigned long long)presentingEdge {
    if (g_ccGestureLeft) return (unsigned long long)(UIRectEdgeBottom | UIRectEdgeLeft);
    if (g_ccGestureRight) return (unsigned long long)(UIRectEdgeBottom | UIRectEdgeRight);
    return %orig;
}
%end

%end

// 2. 解决角落手势冲突：阻止 Home/后台手势在角落区域抢占触发
%group CCGestureConflictHooks

// 控制中心边缘手势仅响应目标角落区域
%hook UIScreenEdgePanGestureRecognizer
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (isOnSpringBoard && (g_ccGestureLeft || g_ccGestureRight)) {
        UIRectEdge activeEdge = g_ccGestureLeft ? (UIRectEdgeBottom | UIRectEdgeLeft) : (UIRectEdgeBottom | UIRectEdgeRight);
        if (self.edges == activeEdge && !HGIsTouchInActiveCCCorner(touches)) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
    %orig;
}
%end

// 阻止 Home/后台手势在角落区域抢占触发
%hook SBHomeGesturePanGestureRecognizer
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (HGIsTouchInActiveCCCorner(touches)) {
        ((UIGestureRecognizer *)self).state = UIGestureRecognizerStateFailed;
        return;
    }
    %orig;
}
%end

// 拒绝后台/Switcher 手势在角落区域接收触摸（iOS 13+ 兼容）
%hook SBSystemGestureManager
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (g_ccGestureLeft || g_ccGestureRight) {
        NSString *className = NSStringFromClass([gestureRecognizer class]);
        if ([className containsString:@"HomeGesture"] || [className containsString:@"FluidSwitcher"]) {
            UIWindow *window = touch.window;
            CGSize screenSize = [UIScreen mainScreen].bounds.size;
            if (window && window.bounds.size.width > 0) {
                screenSize = window.bounds.size;
            }
            CGPoint point = [touch locationInView:window];
            if (g_ccGestureLeft && HGPointIsInBottomLeftCorner(point, screenSize)) return NO;
            if (g_ccGestureRight && HGPointIsInBottomRightCorner(point, screenSize)) return NO;
        }
    }
    return %orig;
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
            %init(DockAppLibraryPlaceholderHooks);
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

        // 相机快门声 — AudioServices 系统音频层兜底拦截
        if (g_disableCameraShutterSound) {
            void *audioFunc = dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSound");
            if (audioFunc) {
                MSHookFunction(audioFunc, (void *)hook_AudioServicesPlaySystemSound, (void **)&orig_AudioServicesPlaySystemSound);
            }
        }

        // 相机快门声 — AVCapturePhotoOutput 捕获输出层拦截
        if (NSClassFromString(@"AVCapturePhotoOutput")) {
            %init(PhotoOutputShutterHooks);
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

        // ===== 新增 Systempro 移植功能初始化 =====

        // 禁用企业签名验证
        if (NSClassFromString(@"FBSSignatureValidationService")) {
            %init(SignatureHooks);
        }

        // 透明 Dock 背景
        if (NSClassFromString(@"SBDockView")) {
            %init(DockViewHooks);
        }

        // iPad Dock / 应用内 Dock / 最近应用
        if (g_iPadDock && NSClassFromString(@"SBFloatingDockController")) {
            %init(FloatingDockHooks);
        }

        // iPhone 仿 iPad 网格后台
        if (g_gridSwitcherEnabled && NSClassFromString(@"SBAppSwitcherSettings")) {
            %init(GridSwitcherHooks);
        }

        // 画中画（使用 dlsym 运行时解析 MGGetBoolAnswer）
        if (g_pictureInPicture) {
            void *mgHandle = dlsym(RTLD_DEFAULT, "MGGetBoolAnswer");
            if (mgHandle) {
                MSHookFunction(mgHandle, (void *)hook_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
            }
        }

        // 去除录屏和直播三秒倒计时（作者：LaYii-LE⚕️管理）
        // ❗注意：不能在 %ctor 中检查 RPControlCenterClient 是否存在，因为 ReplayKit 框架此时尚未加载。
        // 必须直接延迟执行，等待 ReplayKit 初始化完成后再 hook。
        if (g_noRecordingCountdown) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                %init(NoRecordingCountdownHooks);
            });
        }

        // ===== Randy 功能初始化 =====
        // 隐藏键盘地球图标（UIKeyboardLayoutStar / UIKeyboardImpl 在 UIKit 进程中）
        if (NSClassFromString(@"UIKeyboardLayoutStar")) {
            %init(HideKeyboardGlobeHooks);
        }
        // 隐藏键盘语音图标
        if (NSClassFromString(@"UIKeyboardImpl")) {
            %init(HideKeyboardDictationHooks);
        }
        // 绕过非原装充电器检测（SBUIController 在 SpringBoard 进程中）
        if (NSClassFromString(@"SBUIController")) {
            %init(BypassChargerHooks);
        }

        // ===== 控制中心手势位置初始化（左下角/右下角上拉打开控制中心）=====
        if (isOnSpringBoard) {
            if (NSClassFromString(@"CCSControlCenterDefaults")) {
                %init(CCGesturePositionHooks);
            }
            if (NSClassFromString(@"SBHomeGesturePanGestureRecognizer")) {
                %init(CCGestureConflictHooks);
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
