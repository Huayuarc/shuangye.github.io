#import <UIKit/UIKit.h>
#import <math.h>
#import <string.h>
#import <notify.h>
#import <dlfcn.h>
#import <spawn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <stdatomic.h>
#include <rootless.h>
// 系统级全局 EQ：Core Audio 输出层 DSP（AudioUnit 渲染回调包裹）
#import <AudioToolbox/AudioUnit.h>
#import <AudioToolbox/AudioComponent.h>
#import <AudioToolbox/AudioFormat.h>
#import <SpringBoard/SBIconListView.h>
#import <SpringBoard/SBIconController.h>
// 仅导入需要的 AVFAudio 头文件（避免引入 AVFoundation 伞头导致的 setResponse: 冲突）
#import <AVFAudio/AVAudioSession.h>
#import <AVFAudio/AVAudioUnitEQ.h>
#import <AVFAudio/AVAudioUnitSampler.h>
#import <AVFAudio/AVAudioUnitReverb.h>

// 供网格后台动画平滑度优化（修正.x）使用：声明动画参数方法
@interface SBFluidSwitcherAnimationSettings : NSObject
- (void)setResponse:(double)response;
- (void)setDampingRatio:(double)ratio;
@end

// 供手势修正（修正.x）使用：SBHomeGesturePanGestureRecognizer 为私有类，补全声明
@interface SBHomeGesturePanGestureRecognizer : UIGestureRecognizer
@end

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

static BOOL g_cowHideHomeBar = NO;
static BOOL g_cowHideNotificationBackground = NO;
static BOOL g_cowHideNotificationShadow = NO;

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

// iPad Dock / 应用内 Dock / 最近应用
static BOOL g_iPadDock = YES;
static BOOL g_inAppDock = NO;
static BOOL g_recentApp = NO;

// ========== Dock 图标数量 + 主屏幕网格 ==========
static NSInteger g_dockIconCount = 5;
static const NSInteger kDockMinCount = 5;
static const NSInteger kDockMaxCount = 10;
static BOOL g_homeGridEnabled = NO;
static NSInteger g_homeGridColumns = 4;
static NSInteger g_homeGridRows = 6;

static BOOL g_doubleTapToLock = NO;
static BOOL g_zeroWakeAnimation = NO;
static BOOL g_zeroBacklightFade = NO;

// === Randy 功能 ===
static BOOL g_hideKeyboardGlobe = NO;     // 隐藏键盘地球图标
static BOOL g_hideKeyboardDictation = NO;  // 隐藏键盘语音图标
static BOOL g_bypassChargerCheck = NO;     // 绕过非原装充电器检测

// 自动解锁面容ID
static BOOL g_autoDismissFaceID = NO;

// 去除录屏和直播三秒倒计时（作者：LaYii-LE⚕️管理）
static BOOL g_noRecordingCountdown = NO;

// ========== AtmosForce 音频增强功能（移植自 AtmosForce）==========
static BOOL g_audioEnabled = YES;           // 音频增强总开关
static BOOL g_forceDolby = YES;             // 强制杜比解码
static BOOL g_enableSpatialAudio = YES;     // 空间音频渲染
static BOOL g_bassBoost = YES;              // 低音增强
static float g_masterGain = 6.0f;           // 主增益 (dB)
static float g_globalGain = 3.0f;           // EQ 全局增益 (dB)
static float g_stereoPan = 0.0f;            // 声道平衡 (-1.0 ~ 1.0)
static float g_trebleBoost = 4.0f;          // 高音增强 (dB)
static float g_bassGain = 5.0f;             // 低音增益 (dB)

// ========== 移植自 EQE 的 10 段参数均衡器 ==========
// 滤波器设计参考 EQE 开源 core/filter(RBJ Cookbook biquad)
// 第 1 段 LowShelf(对应 EQE lowshelf)、中间 8 段 Parametric(对应 EQE eq/peaking)、第 10 段 HighShelf(对应 EQE highshelf)
static BOOL g_eq10Band = YES;                    // 10 段 EQ 总开关
static int   g_eqPreset = 0;                     // 0平坦 1重低音 2高音清晰 3流行 4摇滚 5人声
static float g_eqGlobalQ = 2.0f;                 // 全局 Q(对应 EQE filter/base 默认 Q=2)
static float g_eqBandGains[10] = {0,0,0,0,0,0,0,0,0,0};

static const float kEQFreqs[10] = {32,64,125,250,500,1000,2000,4000,8000,16000};
static const AVAudioUnitEQFilterType kEQTypes[10] = {
    AVAudioUnitEQFilterTypeLowShelf,               // 32Hz
    AVAudioUnitEQFilterTypeParametric,             // 64Hz
    AVAudioUnitEQFilterTypeParametric,             // 125Hz
    AVAudioUnitEQFilterTypeParametric,             // 250Hz
    AVAudioUnitEQFilterTypeParametric,             // 500Hz
    AVAudioUnitEQFilterTypeParametric,             // 1kHz
    AVAudioUnitEQFilterTypeParametric,             // 2kHz
    AVAudioUnitEQFilterTypeParametric,             // 4kHz
    AVAudioUnitEQFilterTypeParametric,             // 8kHz
    AVAudioUnitEQFilterTypeHighShelf               // 16kHz
};
static NSHashTable *g_eqRegistry;                 // 弱引用 EQ 实例,prefs 更新时重应用曲线

// ========== 系统级全局 EQ（Core Audio 输出层 DSP，作用于所有 App）==========
static BOOL g_systemWideEQ = NO;          // 系统级全局 EQ 开关(pref: globalEQSystemWide,默认关)
static atomic_int g_eqDirtyVersion = 0;   // EQ 参数版本号:prefs 更新后递增,render 线程检测到即重算系数
#define SDR_MAX_EQ_UNITS     24           // 可同时包裹的输出 AudioUnit 上限
#define SDR_MAX_EQ_CHANNELS  8            // 每单元最多处理的声道数(超出部分直通)
#define SDR_EQ_BANDS         10           // 10 段 biquad

// Q -> 带宽(octave)换算,移植自 EQE core/filter/how_filters_work.txt 的 RBJ 公式
// Apple 的 Parametric 基于 Butterworth 模拟原型,故使用无预畸变公式(精确对应)
static float EQBandwidthFromQ(float q) {
    return 2.0f * asinhf(1.0f / (2.0f * q)) / logf(2.0f);
}

// Cyanide 功能前向声明（定义在文件后半部分）
static void cyanide_applyDisableOTA(BOOL disabled);
static void cyanide_applyMuteCallRecord(BOOL mute);
static void cyanide_applyNanoRegistry(BOOL apply);
static void sdr_refreshCowabungaAppearance(void);
static void sdr_refreshSpringBoardFeatures(void);


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
    g_cowHideHomeBar = (prefs && [prefs objectForKey:@"cowHideHomeBar"] ? [[prefs valueForKey:@"cowHideHomeBar"] boolValue] : NO );
    g_cowHideNotificationBackground = (prefs && [prefs objectForKey:@"cowHideNotificationBackground"] ? [[prefs valueForKey:@"cowHideNotificationBackground"] boolValue] : NO );
    g_cowHideNotificationShadow = (prefs && [prefs objectForKey:@"cowHideNotificationShadow"] ? [[prefs valueForKey:@"cowHideNotificationShadow"] boolValue] : NO );
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
    g_iPadDock = (prefs && [prefs objectForKey:@"ipadDock"] ? [[prefs valueForKey:@"ipadDock"] boolValue] : YES );
    g_inAppDock = (prefs && [prefs objectForKey:@"inAppDock"] ? [[prefs valueForKey:@"inAppDock"] boolValue] : NO );
    g_recentApp = (prefs && [prefs objectForKey:@"recentApp"] ? [[prefs valueForKey:@"recentApp"] boolValue] : NO );
    g_autoDismissFaceID = (prefs && [prefs objectForKey:@"autoDismissFaceID"] ? [[prefs valueForKey:@"autoDismissFaceID"] boolValue] : NO );
    g_noRecordingCountdown = (prefs && [prefs objectForKey:@"noRecordingCountdown"] ? [[prefs valueForKey:@"noRecordingCountdown"] boolValue] : NO );

    // ========== AtmosForce 音频增强功能偏好读取 ==========
    g_audioEnabled = (prefs && [prefs objectForKey:@"audioEnabled"] ? [[prefs valueForKey:@"audioEnabled"] boolValue] : YES );
    g_forceDolby = (prefs && [prefs objectForKey:@"forceDolby"] ? [[prefs valueForKey:@"forceDolby"] boolValue] : YES );
    g_enableSpatialAudio = (prefs && [prefs objectForKey:@"enableSpatial"] ? [[prefs valueForKey:@"enableSpatial"] boolValue] : YES );
    g_bassBoost = (prefs && [prefs objectForKey:@"bassBoost"] ? [[prefs valueForKey:@"bassBoost"] boolValue] : YES );
    g_masterGain = (prefs && [prefs objectForKey:@"masterGain"] ? [[prefs valueForKey:@"masterGain"] floatValue] : 6.0f );
    g_globalGain = (prefs && [prefs objectForKey:@"globalGain"] ? [[prefs valueForKey:@"globalGain"] floatValue] : 3.0f );
    g_stereoPan = (prefs && [prefs objectForKey:@"stereoPan"] ? [[prefs valueForKey:@"stereoPan"] floatValue] : 0.0f );
    g_trebleBoost = (prefs && [prefs objectForKey:@"trebleBoost"] ? [[prefs valueForKey:@"trebleBoost"] floatValue] : 4.0f );
    g_bassGain = (prefs && [prefs objectForKey:@"bassGain"] ? [[prefs valueForKey:@"bassGain"] floatValue] : 5.0f );

    // ========== EQE 10 段 EQ 偏好读取(直读 plist,避免 NSUserDefaults 缓存)==========
    NSDictionary *eqPrefs = [NSDictionary dictionaryWithContentsOfFile:
        [NSString stringWithUTF8String:ROOT_PATH_VAR("/var/mobile/Library/Preferences/com.hoangdus.speedsterprefs.plist")]];
    g_eq10Band  = (eqPrefs && [eqPrefs objectForKey:@"eq10Band"] ? [[eqPrefs valueForKey:@"eq10Band"] boolValue] : YES);
    g_eqPreset  = (eqPrefs && [eqPrefs objectForKey:@"eqPreset"] ? [[eqPrefs valueForKey:@"eqPreset"] intValue] : 0);
    g_eqGlobalQ = (eqPrefs && [eqPrefs objectForKey:@"eqGlobalQ"] ? [[eqPrefs valueForKey:@"eqGlobalQ"] floatValue] : 2.0f);
    for (int i = 0; i < 10; i++) {
        NSString *key = [NSString stringWithFormat:@"eqBand%d", i];
        g_eqBandGains[i] = (eqPrefs && [eqPrefs objectForKey:key] ? [[eqPrefs valueForKey:key] floatValue] : 0.0f);
    }
    // 对已注册的 EQ 实例重新应用曲线(真热更新:getter 只在 app 调用时触发,需主动重入)
    if (g_eq10Band && g_eqRegistry) {
        for (AVAudioUnitEQ *eq in [g_eqRegistry allObjects]) {
            [eq bands];
        }
    }

    // ========== 系统级全局 EQ 开关 + 参数版本号递增 ==========
    // 版本号递增后,所有输出单元的 render 线程会在下一帧检测到并重算滤波器系数(实时热更新)
    g_systemWideEQ = (prefs && [prefs objectForKey:@"globalEQSystemWide"] ? [[prefs valueForKey:@"globalEQSystemWide"] boolValue] : NO);
    atomic_fetch_add_explicit(&g_eqDirtyVersion, 1, memory_order_release);

    // ========== Dock 图标数量 / 主屏幕网格偏好 ==========
    g_dockIconCount = (prefs && [prefs objectForKey:@"dockIconCount"] ? [[prefs valueForKey:@"dockIconCount"] integerValue] : 5 );
    if (g_dockIconCount < kDockMinCount) g_dockIconCount = kDockMinCount;
    if (g_dockIconCount > kDockMaxCount) g_dockIconCount = kDockMaxCount;
    g_homeGridEnabled = (prefs && [prefs objectForKey:@"homeGridEnabled"] ? [[prefs valueForKey:@"homeGridEnabled"] boolValue] : NO );
    g_homeGridColumns = (prefs && [prefs objectForKey:@"homeGridColumns"] ? [[prefs valueForKey:@"homeGridColumns"] integerValue] : 4 );
    g_homeGridRows = (prefs && [prefs objectForKey:@"homeGridRows"] ? [[prefs valueForKey:@"homeGridRows"] integerValue] : 6 );
    if (g_homeGridColumns < 3) g_homeGridColumns = 3;
    if (g_homeGridColumns > 8) g_homeGridColumns = 8;
    if (g_homeGridRows < 4) g_homeGridRows = 4;
    if (g_homeGridRows > 10) g_homeGridRows = 10;

    g_doubleTapToLock = (prefs && [prefs objectForKey:@"doubleTapToLock"] ? [[prefs valueForKey:@"doubleTapToLock"] boolValue] : NO );
    g_zeroWakeAnimation = (prefs && [prefs objectForKey:@"zeroWakeAnimation"] ? [[prefs valueForKey:@"zeroWakeAnimation"] boolValue] : NO );
    g_zeroBacklightFade = (prefs && [prefs objectForKey:@"zeroBacklightFade"] ? [[prefs valueForKey:@"zeroBacklightFade"] boolValue] : NO );

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

    if (isOnSpringBoard) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sdr_refreshCowabungaAppearance();
            sdr_refreshSpringBoardFeatures();
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

static char kSDRCowOriginalAlphaKey;
static char kSDRCowOriginalShadowOpacityKey;

static id sdr_safeValueForKey(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIView *sdr_viewForKey(id object, NSString *key) {
    id value = sdr_safeValueForKey(object, key);
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

static void sdr_setViewSuppressed(UIView *view, BOOL suppressed);

static void sdr_setKeyedViewsSuppressed(id object, NSArray<NSString *> *keys, BOOL suppressed) {
    for (NSString *key in keys) {
        sdr_setViewSuppressed(sdr_viewForKey(object, key), suppressed);
    }
}

static void sdr_setViewSuppressed(UIView *view, BOOL suppressed) {
    if (!view) return;
    NSNumber *originalAlpha = objc_getAssociatedObject(view, &kSDRCowOriginalAlphaKey);
    if (suppressed) {
        if (!originalAlpha) {
            objc_setAssociatedObject(view, &kSDRCowOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.alpha = 0.0;
    } else if (originalAlpha) {
        view.alpha = originalAlpha.doubleValue;
        objc_setAssociatedObject(view, &kSDRCowOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void sdr_setShadowSuppressed(UIView *view, BOOL suppressed) {
    if (!view) return;
    NSNumber *originalOpacity = objc_getAssociatedObject(view.layer, &kSDRCowOriginalShadowOpacityKey);
    if (suppressed) {
        if (!originalOpacity) {
            objc_setAssociatedObject(view.layer, &kSDRCowOriginalShadowOpacityKey, @(view.layer.shadowOpacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.layer.shadowOpacity = 0.0f;
    } else if (originalOpacity) {
        view.layer.shadowOpacity = originalOpacity.floatValue;
        objc_setAssociatedObject(view.layer, &kSDRCowOriginalShadowOpacityKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void sdr_applyHomeGrabberAppearance(UIView *view) {
    sdr_setViewSuppressed(view, g_cowHideHomeBar);
    sdr_setViewSuppressed(sdr_viewForKey(view, @"pillView"), g_cowHideHomeBar);
}

static void sdr_applyCoverSheetHomeAffordanceAppearance(UIView *view) {
    sdr_setViewSuppressed(view, g_cowHideHomeBar);
    sdr_setKeyedViewsSuppressed(view, @[
        @"alwaysOnHomeAffordance",
        @"dynamicHomeAffordance",
        @"staticHomeAffordance",
        @"pillView"
    ], g_cowHideHomeBar);
}

static void sdr_applyNotificationAppearance(UIView *view) {
    UIView *platterView = sdr_viewForKey(view, @"platterView");
    sdr_setKeyedViewsSuppressed(view, @[
        @"backgroundView",
        @"backgroundMaterialView",
        @"stackDimmingOverlayView",
        @"stackDimmingView"
    ], g_cowHideNotificationBackground);
    sdr_setKeyedViewsSuppressed(platterView, @[
        @"backgroundView",
        @"backgroundMaterialView",
        @"materialView"
    ], g_cowHideNotificationBackground);

    UIView *shadowView = sdr_viewForKey(platterView, @"shadowView") ?: sdr_viewForKey(view, @"shadowView");
    sdr_setViewSuppressed(shadowView, g_cowHideNotificationShadow);
    sdr_setShadowSuppressed(shadowView ?: platterView ?: view, g_cowHideNotificationShadow);
}

static void sdr_applyCowabungaAppearanceToView(UIView *view) {
    if (!view) return;
    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"SBHomeGrabberView"]) {
        sdr_applyHomeGrabberAppearance(view);
    } else if ([className isEqualToString:@"CSHomeAffordanceView"]) {
        sdr_applyCoverSheetHomeAffordanceAppearance(view);
    } else if ([className isEqualToString:@"CSAlwaysOnHomeAffordancePillView"]) {
        sdr_setViewSuppressed(view, g_cowHideHomeBar);
    } else if ([className isEqualToString:@"NCNotificationShortLookView"]) {
        sdr_applyNotificationAppearance(view);
    } else if ([className isEqualToString:@"NCNotificationLongLookView"] ||
               [className isEqualToString:@"NCNotificationSummaryPlatterView"] ||
               [className isEqualToString:@"NCNotificationSummaryPlatterContainingView"]) {
        sdr_applyNotificationAppearance(view);
    } else if ([className isEqualToString:@"NCMaterialView"]) {
        sdr_setViewSuppressed(view, g_cowHideNotificationBackground);
    }

    for (UIView *subview in view.subviews) {
        sdr_applyCowabungaAppearanceToView(subview);
    }
}

static void sdr_refreshCowabungaAppearance(void) {
    if (!isOnSpringBoard) return;
    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            sdr_applyCowabungaAppearanceToView(window);
            [window setNeedsLayout];
        }
    }
}

%group CowabungaSpringBoardAppearanceHooks

%hook SBHomeGrabberView
- (void)layoutSubviews {
    %orig;
    sdr_applyHomeGrabberAppearance((UIView *)self);
}
%end

%hook CSHomeAffordanceView
- (void)layoutSubviews {
    %orig;
    sdr_applyCoverSheetHomeAffordanceAppearance((UIView *)self);
}
%end

%hook NCNotificationShortLookView
- (void)layoutSubviews {
    %orig;
    sdr_applyNotificationAppearance((UIView *)self);
}
%end

%hook NCNotificationLongLookView
- (void)layoutSubviews {
    %orig;
    sdr_applyNotificationAppearance((UIView *)self);
}
%end

%hook NCNotificationSummaryPlatterView
- (void)layoutSubviews {
    %orig;
    sdr_applyNotificationAppearance((UIView *)self);
}
%end

%hook NCNotificationSummaryPlatterContainingView
- (void)layoutSubviews {
    %orig;
    sdr_applyNotificationAppearance((UIView *)self);
}
%end

%hook NCMaterialView
- (void)layoutSubviews {
    %orig;
    sdr_setViewSuppressed((UIView *)self, g_cowHideNotificationBackground);
}
%end

%hook CSAlwaysOnHomeAffordancePillView
- (void)layoutSubviews {
    %orig;
    sdr_setViewSuppressed((UIView *)self, g_cowHideHomeBar);
}
%end

%end

static char kSDRAppLibraryPluralControllersKey;
static char kSDRAppLibrarySingularControllerKey;
static char kSDRDoubleTapRecognizerKey;

static id sdr_sendObjectNoArguments(id object, const char *selectorName) {
    if (!object || !selectorName) return nil;
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void sdr_setDoubleIvar(id object, const char *ivarName, double value) {
    if (!object || !ivarName) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    memcpy(bytes + offset, &value, sizeof(value));
}

static id sdr_getObjectIvar(id object, const char *ivarName) {
    if (!object || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (!ivar) return nil;
    return object_getIvar(object, ivar);
}

static void sdr_configureWakeSettings(id settings, BOOL isWake) {
    if (!settings) return;
    if (g_zeroBacklightFade || (g_zeroWakeAnimation && isWake)) {
        sdr_setDoubleIvar(settings, "_backlightFadeDuration", 0.0);
    }
    if (!g_zeroWakeAnimation || !isWake) return;
    sdr_setDoubleIvar(settings, "_speedMultiplierForWake", 1000.0);
    sdr_setDoubleIvar(settings, "_speedMultiplierForLiftToWake", 1000.0);
    id contentSettings = sdr_getObjectIvar(settings, "_contentWakeSettings");
    sdr_setDoubleIvar(contentSettings, "_duration", 0.0);
    sdr_setDoubleIvar(contentSettings, "_speed", 1000.0);
    sdr_setDoubleIvar(contentSettings, "_delay", 0.0);
}

@interface SDRDoubleTapLockController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedInstance;
- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation SDRDoubleTapLockController
+ (instancetype)sharedInstance {
    static SDRDoubleTapLockController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [SDRDoubleTapLockController new];
    });
    return controller;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer {
    if (!g_doubleTapToLock || recognizer.state != UIGestureRecognizerStateRecognized) return;
    UIApplication *application = [UIApplication sharedApplication];
    SEL selector = sel_registerName("_simulateLockButtonPress");
    if ([application respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(application, selector);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (!g_doubleTapToLock) return NO;
    UIView *view = touch.view;
    while (view && view != gestureRecognizer.view) {
        NSString *className = NSStringFromClass(view.class);
        if ([view isKindOfClass:[UIControl class]] ||
            [className containsString:@"IconView"] ||
            [className containsString:@"Dock"] ||
            [className containsString:@"Widget"]) {
            return NO;
        }
        view = view.superview;
    }
    return YES;
}
@end

static void sdr_updateDoubleTapRecognizer(UIView *rootView) {
    if (!rootView) return;
    UITapGestureRecognizer *recognizer = objc_getAssociatedObject(rootView, &kSDRDoubleTapRecognizerKey);
    if (!recognizer) {
        SDRDoubleTapLockController *controller = [SDRDoubleTapLockController sharedInstance];
        recognizer = [[UITapGestureRecognizer alloc] initWithTarget:controller action:@selector(handleDoubleTap:)];
        recognizer.numberOfTapsRequired = 2;
        recognizer.cancelsTouchesInView = NO;
        recognizer.delaysTouchesBegan = NO;
        recognizer.delegate = controller;
        [rootView addGestureRecognizer:recognizer];
        objc_setAssociatedObject(rootView, &kSDRDoubleTapRecognizerKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    recognizer.enabled = g_doubleTapToLock;
}

static void sdr_applyAppLibraryState(id object) {
    if (!object) return;
    SEL pluralGetter = sel_registerName("trailingCustomViewControllers");
    SEL pluralSetter = sel_registerName("setTrailingCustomViewControllers:");
    SEL singularGetter = sel_registerName("trailingCustomViewController");
    SEL singularSetter = sel_registerName("setTrailingCustomViewController:");
    if (g_disableAppLibrary) {
        if ([object respondsToSelector:pluralGetter]) {
            id pluralControllers = ((id (*)(id, SEL))objc_msgSend)(object, pluralGetter);
            if ([pluralControllers respondsToSelector:@selector(count)] && [pluralControllers count] > 0) {
                objc_setAssociatedObject(object, &kSDRAppLibraryPluralControllersKey, pluralControllers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if ([object respondsToSelector:singularGetter]) {
            id singularController = ((id (*)(id, SEL))objc_msgSend)(object, singularGetter);
            if (singularController) {
                objc_setAssociatedObject(object, &kSDRAppLibrarySingularControllerKey, singularController, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if ([object respondsToSelector:pluralSetter]) {
            ((void (*)(id, SEL, id))objc_msgSend)(object, pluralSetter, @[]);
        }
        if ([object respondsToSelector:singularSetter]) {
            ((void (*)(id, SEL, id))objc_msgSend)(object, singularSetter, nil);
        }
        return;
    }

    id pluralControllers = objc_getAssociatedObject(object, &kSDRAppLibraryPluralControllersKey);
    if (pluralControllers && [object respondsToSelector:pluralSetter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, pluralSetter, pluralControllers);
    }
    id singularController = objc_getAssociatedObject(object, &kSDRAppLibrarySingularControllerKey);
    if (singularController && [object respondsToSelector:singularSetter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, singularSetter, singularController);
    }
}

static NSString *sdr_iconLocationForListView(id listView) {
    if (!listView) return nil;
    SEL selector = sel_registerName("iconLocation");
    if (![listView respondsToSelector:selector]) return nil;
    id location = ((id (*)(id, SEL))objc_msgSend)(listView, selector);
    return [location isKindOfClass:[NSString class]] ? location : nil;
}

static BOOL sdr_isRootHomeIconListView(id listView) {
    NSString *location = sdr_iconLocationForListView(listView);
    if (location.length > 0) {
        return [location isEqualToString:@"SBIconLocationRoot"] ||
               [location isEqualToString:@"SBIconLocationRootWithWidgets"];
    }
    Class rootListClass = NSClassFromString(@"SBRootIconListView");
    return rootListClass && [listView isKindOfClass:rootListClass];
}

static BOOL sdr_isDockIconListView(id listView) {
    NSString *location = sdr_iconLocationForListView(listView);
    if (location.length > 0) {
        return [location isEqualToString:@"SBIconLocationDock"];
    }
    Class dockListClass = NSClassFromString(@"SBDockIconListView");
    return dockListClass && [listView isKindOfClass:dockListClass];
}

static BOOL sdr_isLandscapeIconListView(UIView *listView) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *windowScene = listView.window.windowScene;
        if (windowScene) return UIInterfaceOrientationIsLandscape(windowScene.interfaceOrientation);
    }
    return CGRectGetWidth(listView.bounds) > CGRectGetHeight(listView.bounds);
}

static SBHIconGridSize sdr_adjustedGridSizeForListView(SBIconListView *listView, SBHIconGridSize gridSize) {
    if (sdr_isDockIconListView(listView)) {
        gridSize.columns = (uint16_t)g_dockIconCount;
        return gridSize;
    }
    if (!g_homeGridEnabled || !sdr_isRootHomeIconListView(listView)) return gridSize;
    if (sdr_isLandscapeIconListView(listView)) {
        gridSize.columns = (uint16_t)g_homeGridRows;
        gridSize.rows = (uint16_t)g_homeGridColumns;
    } else {
        gridSize.columns = (uint16_t)g_homeGridColumns;
        gridSize.rows = (uint16_t)g_homeGridRows;
    }
    return gridSize;
}

static void sdr_refreshIconListViews(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:NSClassFromString(@"SBIconListView")]) {
        SEL layoutSelector = sel_registerName("_layoutIconsNow");
        if ([view respondsToSelector:layoutSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(view, layoutSelector);
        }
        [view setNeedsLayout];
    }
    for (UIView *subview in view.subviews) {
        sdr_refreshIconListViews(subview);
    }
}

static void sdr_refreshSpringBoardFeatures(void) {
    if (!isOnSpringBoard) return;
    Class iconControllerClass = NSClassFromString(@"SBIconController");
    id iconController = sdr_sendObjectNoArguments(iconControllerClass, "sharedInstance");
    id iconManager = sdr_sendObjectNoArguments(iconController, "iconManager");
    id rootFolderController = sdr_sendObjectNoArguments(iconManager, "rootFolderController");
    if (!rootFolderController) rootFolderController = sdr_sendObjectNoArguments(iconController, "rootFolderController");
    id rootFolderView = sdr_sendObjectNoArguments(rootFolderController, "rootFolderView");
    if (!rootFolderView) rootFolderView = sdr_sendObjectNoArguments(rootFolderController, "contentView");
    if (!rootFolderView) rootFolderView = sdr_sendObjectNoArguments(rootFolderController, "view");

    sdr_applyAppLibraryState(rootFolderController);
    sdr_applyAppLibraryState(rootFolderView);
    if ([rootFolderView isKindOfClass:[UIView class]]) {
        sdr_updateDoubleTapRecognizer(rootFolderView);
    }

    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            sdr_refreshIconListViews(window);
            [window setNeedsLayout];
        }
    }
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
        if (g_zeroBacklightFade || g_zeroWakeAnimation) {
            return 0.0;
        }
        if(isScreensleepEnable){
            return reverseTurnOffSpeed(Screensleepvalue);
        }else{
            return %orig;
        }
    }
    -(double)speedMultiplierForWake{ //Screen turn on speed (might be glitchy)
        if (g_zeroWakeAnimation) {
            return 1000.0;
        }
        if(isScreenwakeEnable){
            return Screenwakevalue;
        }else{
            return %orig;
        }
    }
    -(double)speedMultiplierForLiftToWake{ //Screen turn on speed but for lift to wake (again might be glitchy)
        if (g_zeroWakeAnimation) {
            return 1000.0;
        }
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
            return %orig;
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

%group WakeAnimationHooks

%hook SBScreenWakeAnimationController
- (id)_animationSettingsForBacklightChangeSource:(NSInteger)source isWake:(BOOL)isWake {
    id settings = %orig;
    sdr_configureWakeSettings(settings, isWake);
    return settings;
}
%end

%end

%group DoubleTapLockHooks

%hook SBRootFolderView
- (void)didMoveToWindow {
    %orig;
    sdr_applyAppLibraryState(self);
    sdr_updateDoubleTapRecognizer((UIView *)self);
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
// iPad Dock / 应用内 Dock / 最近应用
// ============================================================================
%group FloatingDockHooks

%hook SBFloatingDockController
+ (BOOL)isFloatingDockSupported {
    if (g_iPadDock) return YES;
    return %orig;
}
%end

%hook SBFloatingDockSuggestionsModel
- (void)_setRecentsEnabled:(BOOL)enabled {
    %orig(g_iPadDock ? g_recentApp : enabled);
}
%end

%hook SBFloatingDockBehaviorAssertion
- (BOOL)gesturePossible {
    if (!g_iPadDock) return %orig;
    if (!g_inAppDock) return NO;
    return %orig;
}
%end

%end

// ============================================================================
// Dock 图标数量 + 主屏幕网格
// 仅修改根主屏和标准 Dock，避免污染文件夹及 App 资源库布局配置
// ============================================================================
%group IconGridHooks

%hook SBIconListView
- (NSUInteger)iconRowsForCurrentOrientation {
    NSUInteger rows = %orig;
    if (!sdr_isRootHomeIconListView(self)) return rows;
    if (g_homeGridEnabled) {
        return sdr_isLandscapeIconListView((UIView *)self) ? g_homeGridColumns : g_homeGridRows;
    }
    if (g_iPadDock && rows >= 4) return rows + 1;
    return rows;
}

- (NSUInteger)iconColumnsForCurrentOrientation {
    NSUInteger columns = %orig;
    if (sdr_isDockIconListView(self)) return g_dockIconCount;
    if (g_homeGridEnabled && sdr_isRootHomeIconListView(self)) {
        return sdr_isLandscapeIconListView((UIView *)self) ? g_homeGridRows : g_homeGridColumns;
    }
    return columns;
}

- (SBHIconGridSize)iconGridSizeForClass:(SBHIconGridSizeClass)iconGridSizeClass {
    SBHIconGridSize gridSize = %orig;
    return sdr_adjustedGridSizeForListView(self, gridSize);
}

- (NSUInteger)maximumIconCount {
    if (sdr_isDockIconListView(self)) return g_dockIconCount;
    if (g_homeGridEnabled && sdr_isRootHomeIconListView(self)) {
        return (NSUInteger)(g_homeGridColumns * g_homeGridRows);
    }
    return %orig;
}

- (NSUInteger)maxIcons {
    if (sdr_isDockIconListView(self)) return g_dockIconCount;
    if (g_homeGridEnabled && sdr_isRootHomeIconListView(self)) {
        return (NSUInteger)(g_homeGridColumns * g_homeGridRows);
    }
    return %orig;
}
%end

%end
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
        [self setState:UIGestureRecognizerStateFailed];
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
// ===== AtmosForce 音频增强功能（移植自 AtmosForce）=====
// 强制杜比解码 / 空间音频 / EQ 均衡器 / 低音高音增强 / 主增益 / 声道平衡
// ============================================================================
%group AtmosForceHooks

%hook AVAudioSession

- (BOOL)isDolbyDigitalEncoderAvailable {
    if (!g_audioEnabled) return %orig;
    return g_forceDolby ? YES : %orig;
}

- (BOOL)isDolbyAtmosAvailable {
    if (!g_audioEnabled) return %orig;
    return g_forceDolby ? YES : %orig;
}

// 强制开启多声道立体声渲染支持
- (NSInteger)maximumOutputChannelCount {
    if (!g_audioEnabled) return %orig;
    return g_forceDolby ? 8 : %orig; // 解锁 7.1 环绕声通道能力
}

// 强制开启空间音频渲染模式
- (BOOL)setSpatialAudioEnabled:(BOOL)enabled error:(NSError **)outError {
    if (!g_audioEnabled) return %orig;
    return %orig(g_enableSpatialAudio ? YES : enabled, outError);
}

%end

%hook AVAudioUnitEQ

- (float)globalGain {
    // 系统级全局 EQ 开启时,增益由输出层 DSP 统一处理,这里直通避免双重增益
    if (g_systemWideEQ) return %orig;
    if (!g_audioEnabled) return %orig;
    return g_globalGain;
}

// 确保 EQ 至少有 10 段(对应 EQE 多段滤波器设计),并注册实例以便热更新
- (instancetype)initWithNumberOfBands:(NSUInteger)numberOfBands {
    NSUInteger n = (g_audioEnabled && g_eq10Band && !g_systemWideEQ) ? MAX(numberOfBands, 10) : numberOfBands;
    AVAudioUnitEQ *eq = %orig(n);
    if (eq) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_eqRegistry) [g_eqRegistry addObject:eq];
            [eq bands];   // 立即应用当前曲线
        });
    }
    return eq;
}

// 10 段参数均衡器接管(移植自 EQE:LowShelf + Peaking + HighShelf)
- (NSArray<AVAudioUnitEQFilterParameters *> *)bands {
    NSArray<AVAudioUnitEQFilterParameters *> *originalBands = %orig;
    // 系统级全局 EQ 开启时,曲线由输出层 DSP 统一处理,这里直通避免双重 EQ
    if (g_systemWideEQ) return originalBands;
    if (!g_audioEnabled || !originalBands) return originalBands;

    if (g_eq10Band) {
        NSUInteger n = MIN(originalBands.count, 10);
        for (NSUInteger i = 0; i < n; i++) {
            AVAudioUnitEQFilterParameters *param = originalBands[i];
            param.filterType = kEQTypes[i];
            param.frequency  = kEQFreqs[i];
            param.bandwidth  = EQBandwidthFromQ(g_eqGlobalQ);   // LowShelf/HighShelf 忽略此参数
            param.gain       = g_eqBandGains[i];
            param.bypass     = NO;   // 默认 YES,必须显式关闭
        }
    } else {
        // 兼容模式:保留原有的 Bass / Treble 简单调控
        for (AVAudioUnitEQFilterParameters *param in originalBands) {
            // 低频区间增强 (低于 120Hz)
            if (param.frequency < 120.0f && g_bassBoost) {
                param.gain = g_bassGain;
                param.filterType = AVAudioUnitEQFilterTypeParametric;
                param.bandwidth = 1.0f;
            }
            // 高频清晰度增强 (高于 8000Hz)
            else if (param.frequency > 8000.0f) {
                param.gain = g_trebleBoost;
                param.filterType = AVAudioUnitEQFilterTypeParametric;
            }
        }
    }
    return originalBands;
}

%end

%hook AVAudioUnitSampler

- (float)stereoPan {
    // 系统级全局 EQ 开启时,声道平衡由输出层 DSP 统一处理,这里直通避免双重处理
    if (g_systemWideEQ) return %orig;
    if (!g_audioEnabled) return %orig;
    return g_stereoPan;
}

- (float)masterGain {
    // 系统级全局 EQ 开启时,主增益由输出层 DSP 统一处理,这里直通避免双重增益
    if (g_systemWideEQ) return %orig;
    if (!g_audioEnabled) return %orig;
    return g_masterGain;
}

%end

%hook AVAudioUnitReverb

- (void)loadFactoryPreset:(AVAudioUnitReverbPreset)preset {
    if (!g_audioEnabled) {
        %orig;
        return;
    }
    // 当启用杜比强制模式时，使用 LargeHall2 / MediumHall 模拟宽广声场
    if (g_forceDolby) {
        %orig(AVAudioUnitReverbPresetLargeHall2);
    } else {
        %orig;
    }
}

- (float)wetDryMix {
    if (!g_audioEnabled) return %orig;
    // 恰当控制混响干湿比，既有空间延展感又不会模糊人声
    return 15.0f;
}

%end

%hook AVAudioUnitDSPGraph

- (BOOL)loadAudioDSPManager {
    if (!g_audioEnabled) return %orig;
    return YES;
}

- (BOOL)loadAudioUnitDSPGraph {
    if (!g_audioEnabled) return %orig;
    return YES;
}

%end

%end

// ============================================================================
// ===== 系统级全局 EQ（Core Audio 输出层 DSP，作用于所有 App）=====
// 原理:hook AudioUnitSetProperty,当 App 给输出单元(RemoteIO/VoiceProcessingIO/
// GenericOutput)设置 kAudioUnitProperty_SetRenderCallback 时,包一层我们自己的回调:
// 先调用原始回调拿到底层音频,再对缓冲区跑 10 段 RBJ biquad + 全局增益 + 声道平衡。
// 覆盖所有 App(Apple Music/汽水/酷狗/QQ音乐/酷我等),无需它们使用 AVAudioUnitEQ。
// 实时性:prefs 更新后 g_eqDirtyVersion 原子递增,render 线程检测到变化即重算系数。
// 注意:AudioUnitSetProperty 钩子为全局安装(特性默认关闭时零开销直通)。
// ============================================================================

typedef struct {
    AudioUnit unit;                 // 被包裹的输出单元
    UInt32 scope;                   // kAudioUnitScope_Input
    UInt32 element;                 // 0(输出 bus)
    AURenderCallback origProc;      // App 原始渲染回调
    void *origRefCon;               // App 原始回调上下文
    double sampleRate;              // 采样率(wrap 时从 StreamFormat 读取,0=未知回退 44100)
    UInt32 channels;                // 当前检测到的声道数
    int    fmtBytes;                // 每采样字节数(4=Float32, 2=Int16),0=未知/不支持
    int    fmtInterleaved;          // 1=交织(单 buffer 多声道), 0=非交织
    int    appliedVersion;          // 已应用的参数版本号
    // 归一化 biquad 系数 [band][b0,b1,b2,a1,a2]
    float  coefs[SDR_EQ_BANDS][5];
    // 每声道每段的滤波器状态 [ch][band][x1,x2,y1,y2]
    float  state[SDR_MAX_EQ_CHANNELS][SDR_EQ_BANDS][4];
    float  gainLinear;              // (globalGain + masterGain) 的线性值
    float  panL, panR;              // 声道平衡增益(作用于 ch0/ch1)
    int    eqOn;                    // 是否应用 10 段曲线
} SdrEQUnit;

static SdrEQUnit g_eqUnits[SDR_MAX_EQ_UNITS];
static int g_eqUnitCount = 0;

// 归一化 biquad 系数(b0,b1,b2,a0,a1,a2 -> b0/a0,b1/a0,b2/a0,a1/a0,a2/a0)
static void sdr_normalize(float b0, float b1, float b2, float a0, float a1, float a2, float out[5]) {
    if (fabsf(a0) < 1e-12f) {       // 数值兜底:退化为直通
        out[0] = 1.0f; out[1] = 0.0f; out[2] = 0.0f; out[3] = 0.0f; out[4] = 0.0f;
        return;
    }
    float inv = 1.0f / a0;
    out[0] = b0 * inv;
    out[1] = b1 * inv;
    out[2] = b2 * inv;
    out[3] = a1 * inv;
    out[4] = a2 * inv;
}

// RBJ Cookbook 系数(与 AVAudioUnitEQ 曲线一致的 10 段:LowShelf + 8×Peaking + HighShelf)
static void sdr_compute_coefs(SdrEQUnit *u) {
    float sr = (u->sampleRate >= 8000.0 && u->sampleRate <= 768000.0) ? (float)u->sampleRate : 44100.0f;
    float q  = (g_eqGlobalQ >= 0.1f && g_eqGlobalQ <= 20.0f) ? g_eqGlobalQ : 2.0f;
    u->gainLinear = powf(10.0f, (g_globalGain + g_masterGain) * 0.05f);   // dB -> 线性
    float pan = (g_stereoPan < -1.0f) ? -1.0f : (g_stereoPan > 1.0f ? 1.0f : g_stereoPan);
    u->panL = (pan <= 0.0f) ? 1.0f : (1.0f - pan);
    u->panR = (pan >= 0.0f) ? 1.0f : (1.0f + pan);
    u->eqOn = (g_eq10Band && g_audioEnabled) ? 1 : 0;

    for (int i = 0; i < SDR_EQ_BANDS; i++) {
        float gain = g_eqBandGains[i];
        if (gain < -15.0f) gain = -15.0f;
        if (gain > 15.0f)  gain = 15.0f;
        // 增益接近 0 时用直通系数,保证"平坦"预设绝对平坦
        if (fabsf(gain) < 0.05f) {
            sdr_normalize(1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, u->coefs[i]);
            continue;
        }
        float f0 = kEQFreqs[i];
        float A  = powf(10.0f, gain * 0.025f);          // 10^(dB/40)
        float w0 = 2.0f * (float)M_PI * f0 / sr;
        float cw = cosf(w0), sw = sinf(w0);
        float sqA = sqrtf(A);
        float alpha, b0, b1, b2, a0, a1, a2;

        if (i == 0 || i == 9) {
            // LowShelf(32Hz) / HighShelf(16kHz),S=1 → alpha = sin(w0)/2 * sqrt(2)
            alpha = sw * 0.5f * sqrtf(2.0f);
            if (i == 0) {
                b0 = A * ((A + 1.0f) - (A - 1.0f) * cw + 2.0f * sqA * alpha);
                b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw);
                b2 = A * ((A + 1.0f) - (A - 1.0f) * cw - 2.0f * sqA * alpha);
                a0 = (A + 1.0f) + (A - 1.0f) * cw + 2.0f * sqA * alpha;
                a1 = -2.0f * ((A - 1.0f) + (A + 1.0f) * cw);
                a2 = (A + 1.0f) + (A - 1.0f) * cw - 2.0f * sqA * alpha;
            } else {
                b0 = A * ((A + 1.0f) + (A - 1.0f) * cw + 2.0f * sqA * alpha);
                b1 = -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cw);
                b2 = A * ((A + 1.0f) + (A - 1.0f) * cw - 2.0f * sqA * alpha);
                a0 = (A + 1.0f) - (A - 1.0f) * cw + 2.0f * sqA * alpha;
                a1 = 2.0f * ((A - 1.0f) - (A + 1.0f) * cw);
                a2 = (A + 1.0f) - (A - 1.0f) * cw - 2.0f * sqA * alpha;
            }
        } else {
            // Peaking(中间 8 段)
            alpha = sw / (2.0f * q);
            b0 = 1.0f + alpha * A;
            b1 = -2.0f * cw;
            b2 = 1.0f - alpha * A;
            a0 = 1.0f + alpha / A;
            a1 = -2.0f * cw;
            a2 = 1.0f - alpha / A;
        }
        sdr_normalize(b0, b1, b2, a0, a1, a2, u->coefs[i]);
    }
}

// 检测 ioData 格式(Float32/Int16,交织/非交织)并刷新单元状态
static void sdr_detect_format(SdrEQUnit *u, AudioBufferList *ioData, UInt32 frames) {
    if (!ioData || frames == 0 || ioData->mNumberBuffers < 1) return;
    UInt32 nb = ioData->mNumberBuffers;
    UInt32 ch = (nb == 1) ? ioData->mBuffers[0].mNumberChannels : nb;
    if (ch < 1) ch = 1;
    UInt32 bps = ioData->mBuffers[0].mDataByteSize / frames;   // 每 buffer 每帧字节数
    if (nb == 1 && ch > 1) bps /= ch;                          // 交织:除以声道数得每采样字节
    int fmt = 4;
    if (bps == 2) fmt = 2;
    else if (bps != 4) fmt = 0;
    u->channels       = ch;
    u->fmtBytes       = fmt;
    u->fmtInterleaved = (nb == 1) ? 1 : 0;
}

// 级联处理单个声道(10 段 biquad,Direct Form 1)
static void sdr_process_channel(SdrEQUnit *u, int ch, float *data, int stride, UInt32 frames) {
    if (ch >= SDR_MAX_EQ_CHANNELS || !u->eqOn) return;
    for (UInt32 n = 0; n < frames; n++) {
        float x = data[n * stride];
        for (int b = 0; b < SDR_EQ_BANDS; b++) {
            const float *c = u->coefs[b];
            float *s = u->state[ch][b];
            float y = c[0] * x + c[1] * s[0] + c[2] * s[1] - c[3] * s[2] - c[4] * s[3];
            s[1] = s[0]; s[0] = x;
            s[3] = s[2]; s[2] = y;
            x = y;
        }
        data[n * stride] = x;
    }
}

// 对 ioData 应用 EQ + 全局增益 + 声道平衡(仅支持 Float32,其余直通)
static void sdr_process_buffer(SdrEQUnit *u, AudioBufferList *ioData, UInt32 frames) {
    int ch = (int)u->channels;
    if (ch < 1 || u->fmtBytes != 4) return;
    int interleaved = u->fmtInterleaved;
    int nproc = (ch > SDR_MAX_EQ_CHANNELS) ? SDR_MAX_EQ_CHANNELS : ch;

    for (int c = 0; c < ch; c++) {
        float *data;
        int stride;
        if (interleaved) {
            data   = (float *)ioData->mBuffers[0].mData + c;
            stride = ch;
        } else {
            data   = (float *)ioData->mBuffers[c].mData;
            stride = 1;
        }
        if (!data) continue;
        float g = u->gainLinear;
        if (c == 0)      g *= u->panL;
        else if (c == 1) g *= u->panR;
        if (c >= nproc) {            // 超出状态容量:仅增益
            for (UInt32 n = 0; n < frames; n++) data[n * stride] *= g;
            continue;
        }
        if (u->eqOn) sdr_process_channel(u, c, data, stride, frames);
        for (UInt32 n = 0; n < frames; n++) data[n * stride] *= g;
    }
}

// 判断是否为值得包裹的输出单元(rioc/vpio/genr)
static bool sdr_output_unit(AudioUnit inUnit) {
    AudioComponent comp = AudioComponentInstanceGetComponent(inUnit);
    if (!comp) return false;
    AudioComponentDescription desc;
    if (AudioComponentGetDescription(comp, &desc) != noErr) return false;
    switch (desc.componentSubType) {
        case kAudioUnitSubType_RemoteIO:          // 'rioc' 最常见(AVAudioEngine/AUGraph)
        case kAudioUnitSubType_VoiceProcessingIO: // 'vpio' 通话/VoIP
        case kAudioUnitSubType_GenericOutput:     // 'genr' 离线渲染
            return true;
        default:
            return false;
    }
}

// 从单元读取采样率(wrap 时调用一次)
static void sdr_read_unit_format(SdrEQUnit *u) {
    AudioStreamBasicDescription fmt;
    UInt32 size = sizeof(fmt);
    OSStatus st = AudioUnitGetProperty(u->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, u->element, &fmt, &size);
    if (st != noErr || fmt.mSampleRate <= 0.0) {
        size = sizeof(fmt);
        st = AudioUnitGetProperty(u->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, &size);
    }
    u->sampleRate = (st == noErr && fmt.mSampleRate > 0.0) ? fmt.mSampleRate : 0.0;  // 0 -> 回退 44100
}

static SdrEQUnit *sdr_find_or_create_unit(AudioUnit unit, UInt32 scope, UInt32 element) {
    for (int i = 0; i < g_eqUnitCount; i++) {
        if (g_eqUnits[i].unit == unit && g_eqUnits[i].scope == scope && g_eqUnits[i].element == element)
            return &g_eqUnits[i];
    }
    if (g_eqUnitCount >= SDR_MAX_EQ_UNITS) return NULL;
    SdrEQUnit *u = &g_eqUnits[g_eqUnitCount++];
    memset(u, 0, sizeof(*u));
    u->unit = unit;
    u->scope = scope;
    u->element = element;
    u->appliedVersion = -1;   // 首次 render 强制重算系数
    return u;
}

// 我们的渲染回调:先取原始回调数据,再跑 DSP
static OSStatus SdrEQRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                    UInt32 inNumberFrames, AudioBufferList *ioData) {
    SdrEQUnit *u = (SdrEQUnit *)inRefCon;
    OSStatus st = noErr;
    if (u && u->origProc) {
        st = u->origProc(u->origRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    } else if (ioData) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            if (ioData->mBuffers[i].mData && ioData->mBuffers[i].mDataByteSize)
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
    }
    if (!u) return st;
    // 特性关闭时零开销直通(仅调用原始回调)
    if (!g_systemWideEQ || !g_audioEnabled) return st;
    if (!ioData || ioData->mNumberBuffers == 0 || inNumberFrames == 0) return st;
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
        if (ioData->mBuffers[i].mData == NULL) return st;

    // 布局变化时重置滤波器状态,避免声道错位
    UInt32 prevCh = u->channels;
    int prevInter = u->fmtInterleaved;
    sdr_detect_format(u, ioData, inNumberFrames);
    if (!u->fmtBytes) return st;                          // 非 Float32/Int16 直通
    if (u->channels != prevCh || u->fmtInterleaved != prevInter)
        memset(u->state, 0, sizeof(u->state));

    int ver = atomic_load_explicit(&g_eqDirtyVersion, memory_order_acquire);
    if (u->appliedVersion != ver) {
        sdr_compute_coefs(u);
        u->appliedVersion = ver;
    }
    sdr_process_buffer(u, ioData, inNumberFrames);
    return st;
}

// AudioUnitSetProperty 钩子:包裹输出单元的渲染回调
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus hook_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    OSStatus st = orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
    if (st != noErr) return st;
    if (inID != kAudioUnitProperty_SetRenderCallback) return st;
    if (inScope != kAudioUnitScope_Input || inElement != 0) return st;
    if (!g_audioEnabled) return st;                       // 音频总开关关闭时完全不包裹
    if (!sdr_output_unit(inUnit)) return st;
    if (inData == NULL || inDataSize < sizeof(AURenderCallbackStruct)) return st;  // 清除回调:原样处理
    const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)inData;
    if (cb->inputProc == NULL) return st;

    SdrEQUnit *u = sdr_find_or_create_unit(inUnit, inScope, inElement);
    if (!u) return st;
    u->origProc = cb->inputProc;
    u->origRefCon = cb->inputProcRefCon;
    sdr_read_unit_format(u);

    // 装入我们的回调(单层包裹,App 重复设置时更新 origProc 即可)
    AURenderCallbackStruct wrapped;
    wrapped.inputProc = SdrEQRenderCallback;
    wrapped.inputProcRefCon = u;
    orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
    return st;
}

// ============================================================================
// ===== %ctor 构造函数 =====
// ============================================================================
%ctor { //More pref
    @autoreleasepool {
        isOnSpringBoard = [[[NSBundle mainBundle] bundleIdentifier] isEqual:@"com.apple.springboard"];

        // EQ 实例弱引用注册表(用于 prefs 更新时热重应用 10 段曲线)
        g_eqRegistry = [NSHashTable weakObjectsHashTable];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)preferencesthings, CFSTR("com.hoangdus.speedsterprefs-updated"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        preferencesthings();
        inAppSpeedPreferences();

        // ===== Systempro 移植功能初始化 =====
        // 初始化无分组 hooks（Speedster 原有动画功能）
        %init;

        if (isOnSpringBoard) {
            dlopen("/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/CoverSheet.framework/CoverSheet", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/UserNotificationsUIKit.framework/UserNotificationsUIKit", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/PlatterKit.framework/PlatterKit", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/SpringBoardUIServices.framework/SpringBoardUIServices", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/SpotlightUIInternal.framework/SpotlightUIInternal", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
            %init(CowabungaSpringBoardAppearanceHooks);
            Class wakeAnimationControllerClass = NSClassFromString(@"SBScreenWakeAnimationController");
            if (wakeAnimationControllerClass && class_getInstanceMethod(wakeAnimationControllerClass, sel_registerName("_animationSettingsForBacklightChangeSource:isWake:"))) {
                %init(WakeAnimationHooks);
            }
            if (NSClassFromString(@"SBRootFolderView")) {
                %init(DoubleTapLockHooks);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                sdr_refreshCowabungaAppearance();
                sdr_refreshSpringBoardFeatures();
            });
        }

        // 通知不亮锁屏
        %init(LSBlockHooks);

        // 禁用 App 资源库
        Class iconControllerClass = NSClassFromString(@"SBIconController");
        if (iconControllerClass &&
            class_getInstanceMethod(iconControllerClass, sel_registerName("isAppLibraryAllowed")) &&
            class_getInstanceMethod(iconControllerClass, sel_registerName("isAppLibrarySupported"))) {
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


        // Dock 图标数量 + 主屏幕网格
        if (NSClassFromString(@"SBIconListView")) {
            %init(IconGridHooks);
        }

        // iPad Dock / 应用内 Dock / 最近应用
        if (NSClassFromString(@"SBFloatingDockController") &&
            NSClassFromString(@"SBFloatingDockSuggestionsModel") &&
            NSClassFromString(@"SBFloatingDockBehaviorAssertion")) {
            %init(FloatingDockHooks);
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

        // ===== AtmosForce 音频增强功能初始化 =====
        // AVFAudio 框架可能尚未加载，强制加载后同步安装 hooks，确保音频播放前生效
        dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio", RTLD_NOW);
        if (NSClassFromString(@"AVAudioSession")) {
            %init(AtmosForceHooks);
        }

        // ===== 系统级全局 EQ 初始化 =====
        // 全局安装 AudioUnitSetProperty 钩子,包裹所有 App 输出单元的渲染回调。
        // 特性默认关闭时包裹层为纯直通;开启后对所有 App 音频输出实时生效。
        // AudioToolbox 可能尚未加载,先强制加载再 dlsym 取符号。
        dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
        void *auSetProp = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
        if (auSetProp) {
            MSHookFunction(auSetProp, (void *)hook_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty);
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
