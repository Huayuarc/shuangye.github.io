// Jade - Control Center Replacement
// Tweak.x - Main hooking entry point

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "JadeMainViewController.h"
#import "JadeCardViewController.h"
#import "JadeWeatherHandler.h"
#import "JadeBatteryPill.h"
#import "JadeTimePill.h"
#import "JadeBrightnessSlider.h"
#import "JadeVolumeSlider.h"
#import "JadeBatteryDevice.h"
#import "JadeBatteryModule.h"
#import "JadeCurrentUptimeModule.h"
#import "JadeFavoriteModulesCaddy.h"
#import "JadeFullWidthModule.h"
#import "JadeMainModulesCaddy.h"
#import "JadeMediaModule.h"
#import "JadePowerModule.h"
#import "JadePowerModuleButton.h"
#import "JadeSmallModule.h"
#import "JadeWeatherModule.h"
#import "JadeConnectivityButton.h"
#import "JadeConnectivityModule.h"
#import "JadeSlidersModule.h"

// Preferences
static NSUserDefaults *prefs;
static UIWindow *jadeWindow;

static JadeCardViewController *jadeCardViewController;
static JadeMainViewController *jadeMainViewController;
static BOOL isHomeGestureDismissalAllowed = YES;
static BOOL isHomeGestureEnabled = NO;
static BOOL tweakEnabled = YES;

static BOOL JadePreferenceBool(NSString *key, BOOL defaultValue) {
    id value = [prefs objectForKey:key];
    return value ? [value boolValue] : defaultValue;
}

static UIWindow *JadeActiveWindow(void) {
    if (@available(iOS 13.0, *)) {
        UIWindow *fallbackWindow = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (!fallbackWindow) fallbackWindow = window;
                if (window.isKeyWindow) return window;
            }
        }
        return fallbackWindow;
    }

    NSArray *windows = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([UIApplication.sharedApplication respondsToSelector:@selector(windows)]) {
        windows = [UIApplication.sharedApplication performSelector:@selector(windows)];
    }
#pragma clang diagnostic pop
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) return window;
    }
    return windows.firstObject;
}

static void JadeLoadPrefs(void) {
    [prefs synchronize];
    tweakEnabled = JadePreferenceBool(@"tweakEnabled", YES);
    isHomeGestureEnabled = JadePreferenceBool(@"homeGestureEnabled", NO);
    isHomeGestureDismissalAllowed = JadePreferenceBool(@"isHomeGestureDismissalAllowed", YES);
}

static void JadeDismissOverlay(BOOL animated) {
    if (!jadeMainViewController || !jadeWindow) return;

    [jadeMainViewController dismissAnimated:animated completion:^{
        jadeWindow.hidden = YES;
        jadeWindow.rootViewController = nil;
        jadeWindow = nil;
    }];
}

static void JadePrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    JadeLoadPrefs();
    if (!tweakEnabled) {
        JadeDismissOverlay(NO);
    }
}

static void JadePresentOverlay(BOOL animated) {
    JadeLoadPrefs();
    if (!tweakEnabled) return;

    if (!jadeCardViewController) {
        jadeCardViewController = [[JadeCardViewController alloc] init];
    }

    if (!jadeMainViewController) {
        jadeMainViewController = [[JadeMainViewController alloc] initWithCardViewController:jadeCardViewController];
    }

    UIWindow *activeWindow = JadeActiveWindow();
    if (!activeWindow) return;

    if (!jadeWindow) {
        if (@available(iOS 13.0, *)) {
            if (activeWindow.windowScene) {
                jadeWindow = [[UIWindow alloc] initWithWindowScene:activeWindow.windowScene];
            }
        }

        if (!jadeWindow) {
            jadeWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }

        jadeWindow.windowLevel = UIWindowLevelStatusBar + 1000.0;
        jadeWindow.backgroundColor = UIColor.clearColor;
        jadeWindow.hidden = NO;
        jadeWindow.rootViewController = jadeMainViewController;
    }

    jadeWindow.frame = UIScreen.mainScreen.bounds;
    jadeMainViewController.view.frame = jadeWindow.bounds;
    jadeMainViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    jadeCardViewController.isPresented = YES;
    [jadeCardViewController reloadModules];
    [jadeCardViewController reloadButtons];
    [jadeMainViewController presentAnimated:animated completion:nil];
}

static void JadeLoadPrivateFrameworks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *frameworkPaths[] = {
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls",
            "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",
            "/System/Library/PrivateFrameworks/Weather.framework/Weather",
            "/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",
            "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
            "/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration",
            "/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI",
            "/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit",
            "/System/Library/PrivateFrameworks/MaterialKit.framework/MaterialKit",
            "/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",
        };

        size_t frameworkCount = sizeof(frameworkPaths) / sizeof(frameworkPaths[0]);
        for (size_t index = 0; index < frameworkCount; index++) {
            dlopen(frameworkPaths[index], RTLD_LAZY);
        }
    });
}

// Forward declarations
@interface JadeCardViewController (Private)
- (void)reloadModules;
- (void)reloadButtons;
- (void)closeModules;
- (void)updateCellularStateIfNeeded;
@end

// --- CCUIModularControlCenterViewController Hooks ---
// The main control center view controller - we replace it with our own

// Hook SBControlCenterController to present our view instead
%hook SBControlCenterController

- (void)presentAnimated:(BOOL)animated withCompletionHandler:(id)completion {
    %orig;
    JadePresentOverlay(animated);
}

- (void)dismissAnimated:(BOOL)animated withCompletionHandler:(id)completion {
    %orig;
    jadeCardViewController.isPresented = NO;
    [jadeCardViewController closeModules];
    JadeDismissOverlay(animated);
}

%end

// Hook CCUIModularControlCenterOverlayViewController
%hook CCUIModularControlCenterOverlayViewController

- (BOOL)isHomeGestureDismissalAllowed {
    return isHomeGestureDismissalAllowed;
}

%end

// Hook CCUIModularControlCenterViewController
%hook CCUIModularControlCenterViewController

- (BOOL)isHomeGestureDismissalAllowed {
    return isHomeGestureDismissalAllowed;
}

%end

// Hook CCUIModuleCollectionViewController to modify module presentation
%hook CCUIModuleCollectionViewController

- (void)viewDidLoad {
    %orig;
}

- (void)willOpenExpandedModuleForControlCenterViewController:(id)controller {
    %orig;
    [jadeCardViewController setModuleExpanded:YES];
}

- (void)didCloseExpandedModuleForControlCenterViewController:(id)controller {
    %orig;
    [jadeCardViewController setModuleExpanded:NO];
}

%end

// Hook SBMainSwitcherViewController or related for home gesture
%hook SBFluidSwitcherGestureManager

- (BOOL)allowHorizontalSwipesOutsideTrapezoid {
    if (isHomeGestureEnabled) return YES;
    return %orig;
}

%end

// Hook CCUIContentModuleContainerViewController
%hook CCUIContentModuleContainerViewController

- (void)setExpanded:(BOOL)expanded {
    %orig;
    [jadeCardViewController setModuleExpanded:expanded];
}

%end

// Initialize preferences
%ctor {
    @autoreleasepool {
        JadeLoadPrivateFrameworks();

        prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        JadeLoadPrefs();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        JadePrefsChanged,
                                        CFSTR("com.huayuarc.jadeprefs/ReloadPrefs"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        NSLog(@"[Nightwind] -> Jade loaded successfully");
    }
}
