// SystemBox 功能合并到 Systempro
// 适配：所有 com.wkk.systembox → com.huayuarc.systempro
// 排除：Systempro 已有的重叠功能（通知不亮屏、透明Dock、禁相机/手电、
//       禁App资源库、彻关WiFi/BT、低电锁屏、自动面容、禁图标飞入等）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Preferences Domain

static NSString *const kSystemBoxPrefsDomain = @"com.huayuarc.systempro";
static NSString *const kSystemBoxPrefsChangedNotification = @"com.huayuarc.systempro.prefschanged";

#pragma mark - Global Cached Flags

// Hide
static BOOL g_hideHomeBar = NO;
static BOOL g_hideHomePageDots = NO;
static BOOL g_hideHomeIconLabels = NO;
static BOOL g_hideIconDotLabels = NO;
static BOOL g_hideWidgetLabels = NO;
static BOOL g_hideAllBadges = NO;
static BOOL g_hideStatusBarBreadcrumb = NO;
static BOOL g_hideLockScreenControlCenterGrabber = NO;

// Disable
static BOOL g_disableTodayView = NO;
static BOOL g_disableHomePullDownSearch = NO;
static BOOL g_disableTodayViewPullDownSearch = NO;
static BOOL g_disableAppLibraryPullDown = NO;
static BOOL g_disableHomeScreenLongPress = NO;
static BOOL g_disableLockScreenLongPress = NO;
static BOOL g_disableOpenFolderBackground = NO;
static BOOL g_disableScreenshotPreview = NO;

// General
static BOOL g_doubleTapToLock = NO;
static BOOL g_longPressToLock = NO;
static BOOL g_killBackgroundLongPress = NO;
static BOOL g_hideChargingAlert = NO;
static BOOL g_hideLowBatteryAlert = NO;
static BOOL g_noLockAfterRespring = NO;
static BOOL g_dontLockAfterCrash = NO;
static BOOL g_enableFolder4x4 = NO;
static BOOL g_iconsFlyIn = NO;
static BOOL g_fakeBatteryPercent = NO;
static BOOL g_forceZoomToSystemAperture = NO;
static BOOL g_magicInteractionAnimation = NO;
static BOOL g_transparentDock = NO;
static BOOL g_closeFolderAfterAppLaunch = NO;
static BOOL g_adaptiveBadges = NO;
static BOOL g_openAppsAsPad = NO;
static BOOL g_screenRecordingDND = NO;
static BOOL g_springBoardRestartAnimation = NO;
static BOOL g_touch3DAcceleration = NO;
static double g_homeIconScale = 1.0;

// Status Bar
static BOOL g_statusBarDateTimeEnabled = NO;
static BOOL g_colorizeVPNStatusBar = NO;
static BOOL g_vpnStatusBarIcon = NO;
static BOOL g_silentStatusBarIcon = NO;
static BOOL g_silentNotifs = NO;

// Connectivity
static BOOL g_systemBoxForceAirplaneMode = NO;

// Gesture
static BOOL g_homePullDownNotificationCenter = NO;
static BOOL g_homePullDownControlCenter = NO;
static BOOL g_homePullUpNotificationCenter = NO;
static BOOL g_homePullUpControlCenter = NO;

// Low Power
static BOOL g_lowPowerOnLock = NO;

// Other
static BOOL g_enabled = YES;

#pragma mark - Gesture Target Classes

// Private framework class forward declarations
@interface SBControlCenterController : NSObject
+ (id)sharedInstance;
- (void)presentAnimated:(BOOL)animated completion:(id)completion;
@end

@interface SBNotificationCenterController : NSObject
+ (id)sharedInstance;
- (void)presentAnimated:(BOOL)animated completion:(id)completion;
@end

@interface SBLockScreenManager : NSObject
+ (id)sharedInstance;
- (void)_simulateLockButtonPress;
@end

@interface SBMainSwitcherControllerCoordinator : NSObject
+ (id)sharedInstanceIfExists;
- (NSArray *)displayItems;
- (void)_deleteAppLayoutsMatchingBundleIdentifier:(NSString *)bundleID;
@end

@interface SBDisplayItem : NSObject
- (NSString *)applicationBundleIdentifier;
@end

@interface _PMLowPowerMode : NSObject
+ (id)powerMode;
- (BOOL)setPowerMode:(long long)mode fromSource:(int)source;
@end

@interface DNDModeAssertionService : NSObject
+ (id)sharedInstance;
- (id)takeModeAssertionWithDetails:(id)details error:(id *)error;
- (void)invalidateAllActiveModeAssertionsWithError:(id *)error;
@end

@interface DNDModeAssertionDetails : NSObject
+ (id)userRequestedAssertionDetailsWithIdentifier:(NSString *)identifier modeIdentifier:(NSString *)modeID lifetime:(id)lifetime;
@end

@interface SBFluidSwitcherAnimationSettings : NSObject
+ (id)centralAnimationSettings;
@end

#pragma mark SBHomePullDownControlCenterGestureTarget

@interface SBHomePullDownControlCenterGestureTarget : NSObject <UIGestureRecognizerDelegate> {
    BOOL _didPresent;
}
@property (nonatomic, assign) BOOL didPresent;
- (void)handleHomePullDown:(UIGestureRecognizer *)gesture;
@end

@implementation SBHomePullDownControlCenterGestureTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return g_homePullDownControlCenter && !g_homePullDownNotificationCenter;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!g_homePullDownControlCenter) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:gestureRecognizer.view];
    CGPoint translation = [pan translationInView:gestureRecognizer.view];
    if (velocity.y > 120.0 && fabs(translation.x) * 1.25 <= fabs(velocity.y)) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (void)handleHomePullDown:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        [[NSClassFromString(@"SBControlCenterController") sharedInstance] presentAnimated:YES completion:nil];
        _didPresent = YES;
    }
}

- (void)setDidPresent:(BOOL)didPresent { _didPresent = didPresent; }
- (BOOL)didPresent { return _didPresent; }
@end

#pragma mark SBHomePullUpNotificationCenterGestureTarget

@interface SBHomePullUpNotificationCenterGestureTarget : NSObject <UIGestureRecognizerDelegate> {
    BOOL _didPresent;
}
@property (nonatomic, assign) BOOL didPresent;
- (void)handleHomePullUpNC:(UIGestureRecognizer *)gesture;
@end

@implementation SBHomePullUpNotificationCenterGestureTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return g_homePullUpNotificationCenter && !g_homePullUpControlCenter;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!g_homePullUpNotificationCenter) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:gestureRecognizer.view];
    CGPoint translation = [pan translationInView:gestureRecognizer.view];
    if (velocity.y < -120.0 && fabs(translation.x) * 1.25 <= fabs(velocity.y)) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (void)handleHomePullUpNC:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        [[NSClassFromString(@"SBNotificationCenterController") sharedInstance] presentAnimated:YES completion:nil];
        _didPresent = YES;
    }
}

- (void)setDidPresent:(BOOL)didPresent { _didPresent = didPresent; }
- (BOOL)didPresent { return _didPresent; }
@end

#pragma mark SBHomePullUpControlCenterGestureTarget

@interface SBHomePullUpControlCenterGestureTarget : NSObject <UIGestureRecognizerDelegate> {
    BOOL _didPresent;
}
@property (nonatomic, assign) BOOL didPresent;
- (void)handleHomePullUpCC:(UIGestureRecognizer *)gesture;
@end

@implementation SBHomePullUpControlCenterGestureTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return g_homePullUpControlCenter && !g_homePullUpNotificationCenter;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!g_homePullUpControlCenter) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:gestureRecognizer.view];
    CGPoint translation = [pan translationInView:gestureRecognizer.view];
    if (velocity.y < -120.0 && fabs(translation.x) * 1.25 <= fabs(velocity.y)) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (void)handleHomePullUpCC:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        [[NSClassFromString(@"SBControlCenterController") sharedInstance] presentAnimated:YES completion:nil];
        _didPresent = YES;
    }
}

- (void)setDidPresent:(BOOL)didPresent { _didPresent = didPresent; }
- (BOOL)didPresent { return _didPresent; }
@end

#pragma mark SBHomePullDownNotificationCenterGestureTarget

@interface SBHomePullDownNotificationCenterGestureTarget : NSObject <UIGestureRecognizerDelegate> {
    BOOL _didPresent;
}
@property (nonatomic, assign) BOOL didPresent;
- (void)handleHomePullDownNC:(UIGestureRecognizer *)gesture;
@end

@implementation SBHomePullDownNotificationCenterGestureTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return g_homePullDownNotificationCenter && !g_homePullDownControlCenter;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!g_homePullDownNotificationCenter) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:gestureRecognizer.view];
    CGPoint translation = [pan translationInView:gestureRecognizer.view];
    if (velocity.y > 120.0 && fabs(translation.x) * 1.25 <= fabs(velocity.y)) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return NO;
}

- (void)handleHomePullDownNC:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        [[NSClassFromString(@"SBNotificationCenterController") sharedInstance] presentAnimated:YES completion:nil];
        _didPresent = YES;
    }
}

- (void)setDidPresent:(BOOL)didPresent { _didPresent = didPresent; }
- (BOOL)didPresent { return _didPresent; }
@end

#pragma mark SBDoubleTapLockGestureTarget

@interface SBDoubleTapLockGestureTarget : NSObject <UIGestureRecognizerDelegate>
- (void)handleDoubleTapToLock:(UIGestureRecognizer *)gesture;
@end

@implementation SBDoubleTapLockGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch { return g_doubleTapToLock; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer { return g_doubleTapToLock; }
- (void)handleDoubleTapToLock:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        id lockScreenManager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if ([lockScreenManager respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [lockScreenManager performSelector:@selector(_simulateLockButtonPress)];
        }
    }
}
@end

#pragma mark SBLongPressLockGestureTarget

@interface SBLongPressLockGestureTarget : NSObject <UIGestureRecognizerDelegate>
- (void)handleLongPressToLock:(UIGestureRecognizer *)gesture;
@end

@implementation SBLongPressLockGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch { return g_longPressToLock; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer { return g_longPressToLock; }
- (void)handleLongPressToLock:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        id lockScreenManager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if ([lockScreenManager respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [lockScreenManager performSelector:@selector(_simulateLockButtonPress)];
        }
    }
}
@end

#pragma mark SBKillBackgroundGestureTarget

@interface SBKillBackgroundGestureTarget : NSObject <UIGestureRecognizerDelegate>
- (void)handleKillBackground:(UIGestureRecognizer *)gesture;
@end

@implementation SBKillBackgroundGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch { return g_killBackgroundLongPress; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer { return g_killBackgroundLongPress; }
- (void)handleKillBackground:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        id switcherController = [NSClassFromString(@"SBMainSwitcherControllerCoordinator") sharedInstanceIfExists];
        if (switcherController) {
            NSArray *displayItems = [switcherController valueForKey:@"displayItems"];
            for (id item in displayItems) {
                NSString *bundleID = [item applicationBundleIdentifier];
                BOOL shouldKill = YES;
                NSArray *whitelist = [[NSUserDefaults standardUserDefaults] arrayForKey:@"killBackgroundWhitelist"];
                for (NSString *whitelistedID in whitelist) {
                    if ([bundleID isEqualToString:whitelistedID]) {
                        shouldKill = NO;
                        break;
                    }
                }
                if (shouldKill) {
                    [switcherController performSelector:@selector(_deleteAppLayoutsMatchingBundleIdentifier:) withObject:bundleID];
                }
            }
        }
    }
}
@end

#pragma mark - Preferences Reload Helper

static void reloadPreferences() {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSystemBoxPrefsDomain];
    [prefs synchronize];

    g_enabled = [prefs boolForKey:@"enabled"];

    // Hide
    g_hideHomeBar = g_enabled && [prefs boolForKey:@"sb_hideHomeBar"];
    g_hideHomePageDots = g_enabled && [prefs boolForKey:@"sb_hideHomePageDots"];
    g_hideHomeIconLabels = g_enabled && [prefs boolForKey:@"sb_hideHomeIconLabels"];
    g_hideIconDotLabels = g_enabled && [prefs boolForKey:@"sb_hideIconDotLabels"];
    g_hideWidgetLabels = g_enabled && [prefs boolForKey:@"sb_hideWidgetLabels"];
    g_hideAllBadges = g_enabled && [prefs boolForKey:@"sb_hideAllBadges"];
    g_hideStatusBarBreadcrumb = g_enabled && [prefs boolForKey:@"sb_hideStatusBarBreadcrumb"];
    g_hideLockScreenControlCenterGrabber = g_enabled && [prefs boolForKey:@"sb_hideLockScreenControlCenterGrabber"];

    // Disable
    g_disableTodayView = g_enabled && [prefs boolForKey:@"sb_disableTodayView"];
    g_disableHomePullDownSearch = g_enabled && [prefs boolForKey:@"sb_disableHomePullDownSearch"];
    g_disableTodayViewPullDownSearch = g_enabled && [prefs boolForKey:@"sb_disableTodayViewPullDownSearch"];
    g_disableAppLibraryPullDown = g_enabled && [prefs boolForKey:@"sb_disableAppLibraryPullDown"];
    g_disableHomeScreenLongPress = g_enabled && [prefs boolForKey:@"sb_disableHomeScreenLongPress"];
    g_disableLockScreenLongPress = g_enabled && [prefs boolForKey:@"sb_disableLockScreenLongPress"];
    g_disableOpenFolderBackground = g_enabled && [prefs boolForKey:@"sb_disableOpenFolderBackground"];
    g_disableScreenshotPreview = g_enabled && [prefs boolForKey:@"sb_disableScreenshotPreview"];

    // General
    g_doubleTapToLock = g_enabled && [prefs boolForKey:@"sb_doubleTapToLock"];
    g_longPressToLock = g_enabled && [prefs boolForKey:@"sb_longPressToLock"];
    g_killBackgroundLongPress = g_enabled && [prefs boolForKey:@"sb_killBackgroundLongPress"];
    g_hideChargingAlert = g_enabled && [prefs boolForKey:@"sb_hideChargingAlert"];
    g_hideLowBatteryAlert = g_enabled && [prefs boolForKey:@"sb_hideLowBatteryAlert"];
    g_noLockAfterRespring = g_enabled && [prefs boolForKey:@"sb_noLockAfterRespring"];
    g_dontLockAfterCrash = g_enabled && [prefs boolForKey:@"sb_dontLockAfterCrash"];
    g_enableFolder4x4 = g_enabled && [prefs boolForKey:@"sb_enableFolder4x4"];
    g_iconsFlyIn = g_enabled && [prefs boolForKey:@"sb_iconsFlyIn"];
    g_forceZoomToSystemAperture = g_enabled && [prefs boolForKey:@"sb_forceZoomToSystemAperture"];
    g_magicInteractionAnimation = g_enabled && [prefs boolForKey:@"sb_magicInteractionAnimation"];
    g_closeFolderAfterAppLaunch = g_enabled && [prefs boolForKey:@"sb_closeFolderAfterAppLaunch"];
    g_adaptiveBadges = g_enabled && [prefs boolForKey:@"sb_adaptiveBadges"];
    g_openAppsAsPad = g_enabled && [prefs boolForKey:@"sb_openAppsAsPad"];
    g_screenRecordingDND = g_enabled && [prefs boolForKey:@"sb_screenRecordingDND"];
    g_springBoardRestartAnimation = g_enabled && [prefs boolForKey:@"sb_springBoardRestartAnimation"];
    g_touch3DAcceleration = g_enabled && [prefs boolForKey:@"sb_touch3DAcceleration"];
    g_homeIconScale = g_enabled ? [prefs doubleForKey:@"sb_homeIconScale"] : 1.0;
    if (g_homeIconScale <= 0) g_homeIconScale = 1.0;

    // Status Bar
    g_statusBarDateTimeEnabled = g_enabled && [prefs boolForKey:@"sb_statusBarDateTimeEnabled"];
    g_colorizeVPNStatusBar = g_enabled && [prefs boolForKey:@"sb_colorizeVPNStatusBar"];
    g_vpnStatusBarIcon = g_enabled && [prefs boolForKey:@"sb_vpnStatusBarIcon"];
    g_silentStatusBarIcon = g_enabled && [prefs boolForKey:@"sb_silentStatusBarIcon"];
    g_silentNotifs = g_enabled && [prefs boolForKey:@"sb_silentNotifs"];

    // Connectivity
    g_systemBoxForceAirplaneMode = g_enabled && [prefs boolForKey:@"sb_systemBoxForceAirplaneMode"];

    // Gesture
    g_homePullDownNotificationCenter = g_enabled && [prefs boolForKey:@"sb_homePullDownNotificationCenter"];
    g_homePullDownControlCenter = g_enabled && [prefs boolForKey:@"sb_homePullDownControlCenter"];
    g_homePullUpNotificationCenter = g_enabled && [prefs boolForKey:@"sb_homePullUpNotificationCenter"];
    g_homePullUpControlCenter = g_enabled && [prefs boolForKey:@"sb_homePullUpControlCenter"];

    NSString *fakePercent = [prefs stringForKey:@"sb_fakeBatteryPercent"];
    g_fakeBatteryPercent = g_enabled && fakePercent && fakePercent.length > 0 && ![fakePercent isEqualToString:@"0"];

    NSLog(@"SystemBox: Preferences reloaded (enabled=%d)", g_enabled);
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadPreferences();
}

#pragma mark - Hook: SBDockView (Transparent Dock)

%hook SBDockView
- (void)layoutSubviews {
    %orig;
    if (g_transparentDock) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)((id)self, @selector(setBackgroundAlpha:), 0.0);
    }
}
%end

#pragma mark - Hook: SBRootFolderView (Page Dots)

%hook SBRootFolderView
- (void)setPageControlHidden:(BOOL)hidden {
    if (g_hideHomePageDots) {
        %orig(YES);
    } else {
        %orig(hidden);
    }
}
- (void)layoutSubviews {
    %orig;
    if (g_hideHomePageDots) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)((id)self, @selector(setPageControlHidden:), YES);
    }
}
%end

%hook SBIconListPageControl
- (void)setHidden:(BOOL)hidden {
    if (g_hideHomePageDots) {
        %orig(YES);
    } else {
        %orig(hidden);
    }
}
%end

#pragma mark - Hook: SBRootFolderController (Today View)

%hook SBRootFolderController
- (void)setTodayViewPageHidden:(BOOL)hidden {
    %orig(g_disableTodayView ? YES : hidden);
}
%end

#pragma mark - Hook: SBIconView (Icon Labels + Adaptive Badges)

%hook SBIconView
- (void)setLabelHidden:(BOOL)hidden {
    %orig(g_hideHomeIconLabels ? YES : hidden);
}
%end

#pragma mark - Hook: SBIconDotLabelAccessoryView

%hook SBIconDotLabelAccessoryView
- (void)setHidden:(BOOL)hidden {
    %orig(g_hideIconDotLabels ? YES : hidden);
}
%end

#pragma mark - Hook: SBHWidgetContainerView (Widget Labels)

%hook SBHWidgetContainerView
- (void)setTitleLabel:(id)label {
    %orig(label);
    if (g_hideWidgetLabels) {
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

#pragma mark - Hook: SBIconBadgeView

%hook SBIconBadgeView
- (void)setHidden:(BOOL)hidden {
    %orig(g_hideAllBadges ? YES : hidden);
}
%end

#pragma mark - Hook: CSHomeAffordanceView (Home Bar)

%hook CSHomeAffordanceView
- (void)setHidden:(BOOL)hidden {
    %orig(g_hideHomeBar ? YES : hidden);
}
%end

#pragma mark - Hook: SBHomeGrabberView (Lock Screen Grabber)

%hook SBHomeGrabberView
- (void)setHidden:(BOOL)hidden {
    %orig(g_hideLockScreenControlCenterGrabber ? YES : hidden);
}
%end

#pragma mark - Hook: SBFolderView / SBFolderBackgroundView

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

#pragma mark - Hook: SBAlertItemsController (Battery/Charging Alerts)

%hook SBAlertItemsController
- (void)activateAlertItem:(id)item animated:(BOOL)animated {
    if (g_hideLowBatteryAlert) {
        if ([item isKindOfClass:NSClassFromString(@"SBLowPowerAlertItem")]) {
            return;
        }
    }
    if (g_hideChargingAlert) {
        if ([item isKindOfClass:NSClassFromString(@"SBLockScreenBatteryChargingViewController")]) {
            return;
        }
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

#pragma mark - Hook: SBMainDisplayPolicyAggregator (Today View)

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

#pragma mark - Hook: SBTodayViewController

%hook SBTodayViewController
- (void)setTodayViewPageHidden:(BOOL)hidden {
    %orig(g_disableTodayView ? YES : hidden);
}
%end

#pragma mark - Hook: SBHLibrarySearchController (App Library Pull Down)

%hook SBHLibrarySearchController
- (BOOL)spotlightPresenterAllowsPullToSearch {
    if (g_disableAppLibraryPullDown) return NO;
    return %orig;
}
%end

#pragma mark - Hook: SBSearchGesture (Home Pull Down Search)

%hook SBSearchGesture
- (BOOL)searchScrollViewShouldRecognize:(id)scrollView {
    if (g_disableHomePullDownSearch) return NO;
    return %orig(scrollView);
}
%end

#pragma mark - Hook: SBDeviceApplicationSceneStatusBarBreadcrumbProvider

%hook SBDeviceApplicationSceneStatusBarBreadcrumbProvider
- (BOOL)_shouldAddBreadcrumbToActivatingSceneEntity:(id)entity sceneHandle:(id)handle withTransitionContext:(id)context {
    if (g_hideStatusBarBreadcrumb) return NO;
    return %orig(entity, handle, context);
}
%end

#pragma mark - Hook: SBFluidSwitcherViewController (Force Zoom, Magic Animation)

%hook SBFluidSwitcherViewController
- (BOOL)shouldZoomToSystemApertureForEvent:(id)event activeLayout:(id)layout {
    if (g_forceZoomToSystemAperture) return YES;
    return %orig(event, layout);
}
%end

%hook SBSwitcherModifier
- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    if (g_magicInteractionAnimation) {
        id settings = [NSClassFromString(@"SBFluidSwitcherAnimationSettings") performSelector:@selector(centralAnimationSettings)];
        if (settings) {
            [settings setValue:@(0.4) forKey:@"stiffness"];
            [settings setValue:@(0.8) forKey:@"damping"];
        }
    }
    return %orig(update, item);
}
%end

#pragma mark - Hook: SBRootFolderControllerConfiguration (Folder 4x4)

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

#pragma mark - Hook: SBHUnlockSettings (Icons Fly In)

%hook SBHUnlockSettings
- (BOOL)iconsFlyIn {
    if (g_iconsFlyIn) return YES;
    return %orig;
}
%end

#pragma mark - Hook: UIStatusBarBatteryPercentItemView (Fake Battery)

%hook UIStatusBarBatteryPercentItemView
- (id)_percentString {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSystemBoxPrefsDomain];
    [prefs synchronize];
    NSString *fakePercent = [prefs stringForKey:@"sb_fakeBatteryPercent"];
    if (fakePercent && fakePercent.length > 0 && ![fakePercent isEqualToString:@"0"]) {
        return [NSString stringWithFormat:@"%@%%", fakePercent];
    }
    return %orig;
}
%end

#pragma mark - Hook: _UIStatusBar (VPN Colorize)

%hook _UIStatusBar
- (void)_updateWithData:(id)data completionHandler:(id)handler {
    %orig(data, handler);
    if (g_colorizeVPNStatusBar) {
        id vpnItem = [(id)self valueForKey:@"_UIStatusBarIndicatorVPNItem"];
        if (vpnItem) {
            NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSystemBoxPrefsDomain];
            [prefs synchronize];
            CGFloat r = [prefs floatForKey:@"sb_vpnStatusBarColorRed"] / 255.0;
            CGFloat g = [prefs floatForKey:@"sb_vpnStatusBarColorGreen"] / 255.0;
            CGFloat b = [prefs floatForKey:@"sb_vpnStatusBarColorBlue"] / 255.0;
            CGFloat a = [prefs floatForKey:@"sb_vpnStatusBarColorAlpha"];
            if (a == 0) a = 1.0;
            ((void (*)(id, SEL, UIColor *))objc_msgSend)((id)vpnItem, @selector(setActiveColor:), [UIColor colorWithRed:r green:g blue:b alpha:a]);
        }
    }
}
%end

%hook _UIStatusBarCellularNetworkTypeView
- (void)setCellularEntry:(id)entry {
    %orig(entry);
    if (g_colorizeVPNStatusBar) {
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSystemBoxPrefsDomain];
        [prefs synchronize];
        CGFloat r = [prefs floatForKey:@"sb_vpnStatusBarColorRed"] / 255.0;
        CGFloat g = [prefs floatForKey:@"sb_vpnStatusBarColorGreen"] / 255.0;
        CGFloat b = [prefs floatForKey:@"sb_vpnStatusBarColorBlue"] / 255.0;
        CGFloat a = [prefs floatForKey:@"sb_vpnStatusBarColorAlpha"];
        if (a == 0) a = 1.0;
        ((void (*)(id, SEL, UIColor *))objc_msgSend)((id)self, @selector(setTintColor:), [UIColor colorWithRed:r green:g blue:b alpha:a]);
    }
}
%end

#pragma mark - Hook: SBFolderController (Close After App Launch)

%hook SBFolderController
- (void)closeFolderAnimated:(BOOL)animated withCompletion:(id)completion {
    if (g_closeFolderAfterAppLaunch) {
        %orig(YES, completion);
    } else {
        %orig(animated, completion);
    }
}
%end

#pragma mark - Hook: CSCoverSheetViewController (No Lock Respring, Low Power)

%hook CSCoverSheetViewController
- (void)_reallySetUILocked:(BOOL)locked {
    %orig(locked);
    if (g_lowPowerOnLock && locked) {
        id pm = NSClassFromString(@"_PMLowPowerMode");
        if (pm && [pm respondsToSelector:@selector(setPowerMode:fromSource:)]) {
            [pm setPowerMode:locked fromSource:1];
        }
    }
}
- (void)setPasscodeLockVisible:(BOOL)visible animated:(BOOL)animated completion:(id)completion {
    if (g_noLockAfterRespring) {
        %orig(NO, animated, completion);
    } else {
        %orig(visible, animated, completion);
    }
}
%end

#pragma mark - Hook: SBBootDefaults (No Lock)

%hook SBBootDefaults
- (void)setDefaultValues {
    %orig;
    if (g_noLockAfterRespring || g_dontLockAfterCrash) {
        ((void (*)(id, SEL, id, NSString *))objc_msgSend)((id)self, @selector(setValue:forKey:), @(NO), @"isUILocked");
    }
}
%end

#pragma mark - Hook: RPScreenRecorder (Screen Recording DND)

%hook RPScreenRecorder
- (void)setRecording:(BOOL)recording {
    %orig(recording);
    if (g_screenRecordingDND) {
        id dndService = [NSClassFromString(@"DNDModeAssertionService") sharedInstance];
        if (dndService) {
            if (recording) {
                id details = [NSClassFromString(@"DNDModeAssertionDetails") userRequestedAssertionDetailsWithIdentifier:@"com.apple.donotdisturb.mode.default" modeIdentifier:@"com.apple.donotdisturb.control-center.module" lifetime:nil];
                [dndService takeModeAssertionWithDetails:details error:nil];
            } else {
                [dndService invalidateAllActiveModeAssertionsWithError:nil];
            }
        }
    }
}
%end

#pragma mark - Hook: SSScreenshotsWindowRootViewController (Screenshot Preview)

%hook SSScreenshotsWindowRootViewController
- (void)setHidden:(BOOL)hidden {
    if (g_disableScreenshotPreview) {
        %orig(YES);
    } else {
        %orig(hidden);
    }
}
%end

%hook SBDarkeningImageView
- (void)setHidden:(BOOL)hidden {
    if (g_disableScreenshotPreview) {
        %orig(YES);
    } else {
        %orig(hidden);
    }
}
%end

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        NSLog(@"SystemBox: Loading enhanced features for Systempro...");
        reloadPreferences();

        // Register for preference changes
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            prefsChangedCallback,
            CFSTR("com.huayuarc.systempro.prefschanged"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        // Get the key window for gesture recognizer setup
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            if (!keyWindow) return;

            // Double Tap to Lock
            if (g_doubleTapToLock) {
                SBDoubleTapLockGestureTarget *target = [[SBDoubleTapLockGestureTarget alloc] init];
                UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(handleDoubleTapToLock:)];
                doubleTap.numberOfTapsRequired = 2;
                doubleTap.delegate = target;
                [keyWindow addGestureRecognizer:doubleTap];
            }

            // Long Press to Lock
            if (g_longPressToLock) {
                SBLongPressLockGestureTarget *target = [[SBLongPressLockGestureTarget alloc] init];
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(handleLongPressToLock:)];
                longPress.minimumPressDuration = 0.5;
                longPress.delegate = target;
                [keyWindow addGestureRecognizer:longPress];
            }

            // Kill Background Long Press
            if (g_killBackgroundLongPress) {
                SBKillBackgroundGestureTarget *target = [[SBKillBackgroundGestureTarget alloc] init];
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(handleKillBackground:)];
                longPress.minimumPressDuration = 0.5;
                longPress.delegate = target;
                [keyWindow addGestureRecognizer:longPress];
            }

            // Home Pull Down Notification Center
            if (g_homePullDownNotificationCenter) {
                SBHomePullDownNotificationCenterGestureTarget *target = [[SBHomePullDownNotificationCenterGestureTarget alloc] init];
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(handleHomePullDownNC:)];
                pan.delegate = target;
                [keyWindow addGestureRecognizer:pan];
            }

            // Home Pull Down Control Center
            if (g_homePullDownControlCenter) {
                SBHomePullDownControlCenterGestureTarget *target = [[SBHomePullDownControlCenterGestureTarget alloc] init];
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(handleHomePullDown:)];
                pan.delegate = target;
                [keyWindow addGestureRecognizer:pan];
            }

            // Home Pull Up Notification Center
            if (g_homePullUpNotificationCenter) {
                SBHomePullUpNotificationCenterGestureTarget *target = [[SBHomePullUpNotificationCenterGestureTarget alloc] init];
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(handleHomePullUpNC:)];
                pan.delegate = target;
                [keyWindow addGestureRecognizer:pan];
            }

            // Home Pull Up Control Center
            if (g_homePullUpControlCenter) {
                SBHomePullUpControlCenterGestureTarget *target = [[SBHomePullUpControlCenterGestureTarget alloc] init];
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(handleHomePullUpCC:)];
                pan.delegate = target;
                [keyWindow addGestureRecognizer:pan];
            }

            NSLog(@"SystemBox: Gesture recognizers installed");
        });
    }
}
