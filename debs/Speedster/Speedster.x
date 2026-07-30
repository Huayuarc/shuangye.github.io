#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
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
static NSArray *g_proMotion120Blacklist = nil; // 120Hz 排除应用列表（Bundle ID）

// ========== 新增 Systempro 移植功能全局变量 ==========
// Cyanide 系统工具
static BOOL g_cyanideMuteCallRecord = NO;
static BOOL g_cyanideDisableOTA = NO;
static BOOL g_cyanideNanoRegistry = NO;
static BOOL g_cyanideHideHomeBar = NO;

// 禁用企业签名验证
static BOOL g_disableSignatureCheck = NO;

// 透明 Dock 背景
static BOOL g_transparentDock = NO;

// Dock 隐藏 App 资源库占位视图（修复 iPad Dock+禁用App资源库时右侧残留空白方框）
static BOOL g_hideDockAppLibraryPlaceholder = YES;

// iPad Dock / 应用内 Dock / 最近应用
static BOOL g_iPadDock = YES;
static BOOL g_inAppDock = NO;
static BOOL g_recentApp = NO;

// iPad 分屏/侧拉
static BOOL g_iPadMultitask = NO;
static NSInteger g_screenMode = 0;

// iPhone 仿 iPad 网格后台
static BOOL g_gridSwitcherEnabled = NO;
static CGFloat g_gridScale = 0.3;
static CGFloat g_gridHorizontalSpacing = 10;
static CGFloat g_gridVerticalSpacing = 80;

// 画中画
static BOOL g_pictureInPicture = NO;

// 自动解锁面容ID
static BOOL g_autoDismissFaceID = NO;

// 关闭锁屏/解锁声音
static BOOL g_disableLockSound = NO;

// ==============================================

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
    g_proMotion120Enabled = (prefs && [prefs objectForKey:@"proMotion120Enabled"] ? [[prefs valueForKey:@"proMotion120Enabled"] boolValue] : NO );
    {
        // 新版：NSArray 格式（由 AppBlacklistController 写入）
        // 旧版兼容：逗号分隔字符串
        id raw = (prefs && [prefs objectForKey:@"proMotion120Blacklist"] ? [prefs valueForKey:@"proMotion120Blacklist"] : nil);
        if ([raw isKindOfClass:[NSArray class]]) {
            NSArray *list = (NSArray *)raw;
            g_proMotion120Blacklist = (list.count > 0) ? [list copy] : nil;
        } else if ([raw isKindOfClass:[NSString class]]) {
            NSString *str = (NSString *)raw;
            if (str.length > 0) {
                NSMutableArray *list = [NSMutableArray array];
                for (NSString *item in [str componentsSeparatedByString:@","]) {
                    NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmed.length > 0) [list addObject:trimmed];
                }
                g_proMotion120Blacklist = (list.count > 0) ? [list copy] : nil;
            } else {
                g_proMotion120Blacklist = nil;
            }
        } else {
            g_proMotion120Blacklist = nil;
        }
    }

    // ========== 新增 Systempro 移植功能偏好读取 ==========
    // Cyanide 系统工具
    g_cyanideMuteCallRecord = (prefs && [prefs objectForKey:@"cyanide_muteCallRecord"] ? [[prefs valueForKey:@"cyanide_muteCallRecord"] boolValue] : NO );
    g_cyanideDisableOTA = (prefs && [prefs objectForKey:@"cyanide_disableOTA"] ? [[prefs valueForKey:@"cyanide_disableOTA"] boolValue] : NO );
    g_cyanideNanoRegistry = (prefs && [prefs objectForKey:@"cyanide_nanoRegistry"] ? [[prefs valueForKey:@"cyanide_nanoRegistry"] boolValue] : NO );
    g_cyanideHideHomeBar = (prefs && [prefs objectForKey:@"cyanide_hideHomeBar"] ? [[prefs valueForKey:@"cyanide_hideHomeBar"] boolValue] : NO );
    g_disableSignatureCheck = (prefs && [prefs objectForKey:@"disableSignatureCheck"] ? [[prefs valueForKey:@"disableSignatureCheck"] boolValue] : NO );
    g_transparentDock = (prefs && [prefs objectForKey:@"transparentDock"] ? [[prefs valueForKey:@"transparentDock"] boolValue] : NO );
    g_hideDockAppLibraryPlaceholder = (prefs && [prefs objectForKey:@"hideDockAppLibraryPlaceholder"] ? [[prefs valueForKey:@"hideDockAppLibraryPlaceholder"] boolValue] : YES );
    g_iPadDock = (prefs && [prefs objectForKey:@"ipadDock"] ? [[prefs valueForKey:@"ipadDock"] boolValue] : YES );
    g_inAppDock = (prefs && [prefs objectForKey:@"inAppDock"] ? [[prefs valueForKey:@"inAppDock"] boolValue] : NO );
    g_recentApp = (prefs && [prefs objectForKey:@"recentApp"] ? [[prefs valueForKey:@"recentApp"] boolValue] : NO );
    g_iPadMultitask = (prefs && [prefs objectForKey:@"iPadMultitask"] ? [[prefs valueForKey:@"iPadMultitask"] boolValue] : NO );
    g_screenMode = (prefs && [prefs objectForKey:@"screenMode"] ? [[prefs valueForKey:@"screenMode"] integerValue] : 0 );
    g_gridSwitcherEnabled = (prefs && [prefs objectForKey:@"gridSwitcherEnabled"] ? [[prefs valueForKey:@"gridSwitcherEnabled"] boolValue] : NO );
    g_gridScale = (prefs && [prefs objectForKey:@"gridScale"] ? [[prefs valueForKey:@"gridScale"] doubleValue] : 0.3 );
    g_gridHorizontalSpacing = (prefs && [prefs objectForKey:@"gridHorizontalSpacing"] ? [[prefs valueForKey:@"gridHorizontalSpacing"] doubleValue] : 10 );
    g_gridVerticalSpacing = (prefs && [prefs objectForKey:@"gridVerticalSpacing"] ? [[prefs valueForKey:@"gridVerticalSpacing"] doubleValue] : 80 );
    g_pictureInPicture = (prefs && [prefs objectForKey:@"pictureInPicture"] ? [[prefs valueForKey:@"pictureInPicture"] boolValue] : NO );
    g_autoDismissFaceID = (prefs && [prefs objectForKey:@"autoDismissFaceID"] ? [[prefs valueForKey:@"autoDismissFaceID"] boolValue] : NO );
    g_disableLockSound = (prefs && [prefs objectForKey:@"disableLockSound"] ? [[prefs valueForKey:@"disableLockSound"] boolValue] : NO );

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
// 120Hz ProMotion 强制高刷（改进版 v3 — 解决滑动掉帧问题）
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

@interface CAMetalLayer (Private)
@property (assign) NSUInteger maximumDrawableCount;
@end

@interface CADisplayPreferences : NSObject
@property (nonatomic, assign) double preferredRefreshRate;
@end
@interface CAMutableDisplayPreferences : CADisplayPreferences
@end

@interface CADynamicFrameRateSource : NSObject
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (CAFrameRateRange)preferredFrameRateRange;
@end

@interface CAFrameRateRangeGroup : NSObject
- (CAFrameRateRange)arbitratedRange;
@end

// 核心辅助函数：生成 120Hz 优先的帧率范围，保留原始 minimum 让系统能动态降帧
static CAFrameRateRange makeHighFPSRange(CAFrameRateRange orig) {
	CAFrameRateRange r;
	r.minimum = (orig.minimum > 0 && orig.minimum < 120) ? orig.minimum : 30.0f;
	r.maximum = TARGET_FPS;
	r.preferred = TARGET_FPS;
	return r;
}

// 轻量级运行循环观察者：确保 CA 渲染提交使用高帧率
// 替代旧的持久化 CADisplayLink（避免 GPU 空转发热）
@interface SpeedsterProMotionKicker : NSObject
+ (instancetype)sharedKicker;
- (void)startKicking;
- (void)stopKicking;
@end

@implementation SpeedsterProMotionKicker {
	CFRunLoopObserverRef _observer;
}
+ (instancetype)sharedKicker {
	static SpeedsterProMotionKicker *k = nil;
	static dispatch_once_t t;
	dispatch_once(&t, ^{ k = [[self alloc] init]; });
	return k;
}
- (void)startKicking {
	if (_observer) return;
	_observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
		kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting,
		YES, 0,
		^(CFRunLoopObserverRef obs, CFRunLoopActivity act) {
			// 每帧在 run loop 等待前触发 CA 提交，维持 120Hz 流水线
			[CATransaction flush];
		});
	CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
}
- (void)stopKicking {
	if (!_observer) return;
	CFRunLoopRemoveObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
	CFRelease(_observer);
	_observer = nil;
}
- (void)dealloc {
	[self stopKicking];
}
@end

// 检查当前应用是否在 120Hz 排除列表中
static BOOL isCurrentAppIn120Blacklist(void) {
    if (!g_proMotion120Blacklist || g_proMotion120Blacklist.count == 0) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) return NO;
    for (NSString *item in g_proMotion120Blacklist) {
        if ([item isEqualToString:bundleID]) return YES;
    }
    return NO;
}

%group ProMotion120Hooks

// === Level 1: 屏幕/设备级别 ===
%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) return TARGET_FPS;
	return %orig;
}
%end

// iOS 15+ 使用 UIWindowScene 控制帧率（比 UIScreen 更优先）
%hook UIWindowScene
- (NSInteger)maximumFramesPerSecond {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) return TARGET_FPS;
	return %orig;
}
%end

// === Level 2: DisplayLink 级别 ===
%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)sel {
	CADisplayLink *link = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
		if ([link respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
			CAFrameRateRange range;
			range.minimum = 30; range.maximum = TARGET_FPS; range.preferred = TARGET_FPS;
			[link setPreferredFrameRateRange:range];
		} else if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
			[link setPreferredFramesPerSecond:0]; // 0 = max
		}
	}
	return link;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
		// 保留调用方设置的 minimum，仅提升 max/preferred
		CAFrameRateRange nr;
		nr.minimum = (range.minimum > 0 && range.minimum < 120) ? range.minimum : 30;
		nr.maximum = TARGET_FPS;
		nr.preferred = TARGET_FPS;
		%orig(nr);
	} else { %orig; }
}
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) { %orig(0); }
	else { %orig; }
}
- (void)setFrameInterval:(NSInteger)interval {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) { %orig(1); }
	else { %orig; }
}
%end

// === Level 3: Metal 渲染管线 ===
%hook CAMetalLayer
- (NSUInteger)maximumDrawableCount {
	NSUInteger orig = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist() && orig < 3) return 3;
	return orig;
}
%end

%hook CAMetalDrawable
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) { %orig(1.0 / TARGET_FPS); }
	else { %orig; }
}
%end

%hook MTLCommandBuffer
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)minimumDuration {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) { %orig(drawable, 1.0 / TARGET_FPS); }
	else { %orig(drawable, minimumDuration); }
}
%end

// === Level 4: 显示偏好 ===
%hook CAMutableDisplayPreferences
- (void)setPreferredRefreshRate:(double)rate {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) { %orig(120.0); }
	else { %orig(rate); }
}
%end

%hook CADisplayPreferences
- (void)setPreferredRefreshRate:(double)rate {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) { %orig(120.0); }
	else { %orig(rate); }
}
%end

%hook CADisplay
- (void)setPreferences:(id)preferences {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist() && preferences) {
		@try {
			if ([preferences respondsToSelector:@selector(setPreferredRefreshRate:)]) {
				[preferences setValue:@(120.0) forKey:@"preferredRefreshRate"];
			}
		} @catch (NSException *exception) {}
	}
	%orig(preferences);
}
%end

// === Level 5: CAContext（层的帧率上下文） ===
%hook CAContext
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
		%orig(makeHighFPSRange(range));
	} else { %orig(range); }
}
- (void)setPreferredFrameRate:(float)rate {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist() && rate >= 60) { %orig(TARGET_FPS); }
	else { %orig(rate); }
}
%end

// === Level 6: 动态帧率仲裁（关键修复） ===
// 不再强制 minimum=120，让系统能根据 GPU 负载动态降帧
%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
		%orig(makeHighFPSRange(range));
	} else { %orig(range); }
}
- (CAFrameRateRange)preferredFrameRateRange {
	CAFrameRateRange range = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
		return makeHighFPSRange(range);
	}
	return range;
}
%end

%hook CAFrameRateRangeGroup
- (CAFrameRateRange)arbitratedRange {
	CAFrameRateRange range = %orig;
	if (deviceSupports120Hz() && g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
		return makeHighFPSRange(range);
	}
	return range;
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
// 隐藏 HomeBar
// ============================================================================
%group HideHomeBarHooks

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
// Dock 隐藏 App 资源库占位视图
// 修复开启 iPad Dock + 禁用 App 资源库后，Dock 最右侧残留空白方框
// ============================================================================
%group DockAppLibraryPlaceholderHooks

%hook SBDockAppLibraryIconView
- (void)setHidden:(BOOL)hidden {
	if (g_disableAppLibrary && g_hideDockAppLibraryPlaceholder) {
		%orig(YES);
		return;
	}
	%orig(hidden);
}
- (void)setAlpha:(CGFloat)alpha {
	if (g_disableAppLibrary && g_hideDockAppLibraryPlaceholder) {
		%orig(0.0);
		return;
	}
	%orig(alpha);
}
%end

%hook SBFloatingDockView
- (void)layoutSubviews {
	%orig;
	if (g_disableAppLibrary && g_hideDockAppLibraryPlaceholder) {
		for (UIView *sub in [(UIView *)self subviews]) {
			if ([NSStringFromClass(sub.class) isEqualToString:@"SBDockAppLibraryIconView"]) {
				sub.hidden = YES;
				sub.alpha = 0;
				sub.frame = CGRectZero;
			}
		}
	}
}
%end

%end

// ============================================================================
// iPad 分屏/侧拉
// ============================================================================
@interface FBApplicationInfo : NSObject
@property (nonatomic, retain, readonly) NSURL *executableURL;
@end

@interface SBApplicationInfo : FBApplicationInfo
@end

@interface SBApplication : NSObject
@property (nonatomic, readonly) SBApplicationInfo *info;
@end

%group IPadMultitaskHooks

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
// 应用样式 - iPad 布局（横屏时强制 Regular SizeClass）
// ============================================================================
%group IPadAppStyleHooks

%hook UITraitCollection
+ (id)traitCollectionWithHorizontalSizeClass:(NSInteger)horizontalSizeClass {
	if (UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation)) {
		return %orig(2);
	}
	return %orig;
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
            // 用轻量级 CFRunLoopObserver 替代旧的持久化 CADisplayLink
            // 避免 GPU 空转发热导致降频掉帧
            if (g_proMotion120Enabled && !isCurrentAppIn120Blacklist()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[SpeedsterProMotionKicker sharedKicker] startKicking];
                });
            }
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

        // 隐藏 HomeBar
        if (NSClassFromString(@"SBFloatingDockController")) {
            %init(HideHomeBarHooks);
        }

        // iPad Dock / 应用内 Dock / 最近应用
        if (g_iPadDock && NSClassFromString(@"SBFloatingDockController")) {
            %init(FloatingDockHooks);
        }

        // Dock 隐藏 App 资源库占位视图（需 SBFloatingDockView 存在）
        if (g_hideDockAppLibraryPlaceholder && NSClassFromString(@"SBFloatingDockView")) {
            %init(DockAppLibraryPlaceholderHooks);
        }

        // iPad 分屏/侧拉
        if (g_iPadMultitask && NSClassFromString(@"SBMainWorkspace")) {
            %init(IPadMultitaskHooks);
        }

        // iPhone 仿 iPad 网格后台
        if (g_gridSwitcherEnabled && NSClassFromString(@"SBAppSwitcherSettings")) {
            %init(GridSwitcherHooks);
        }

        // 应用样式 - iPad 布局（仅在非 SpringBoard 进程中启用）
        if (g_screenMode == 0 && !isOnSpringBoard && NSClassFromString(@"UITraitCollection")) {
            %init(IPadAppStyleHooks);
        }

        // 画中画（使用 dlsym 运行时解析 MGGetBoolAnswer）
        if (g_pictureInPicture) {
            void *mgHandle = dlsym(RTLD_DEFAULT, "MGGetBoolAnswer");
            if (mgHandle) {
                MSHookFunction(mgHandle, (void *)hook_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
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
