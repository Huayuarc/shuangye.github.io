// Jade - Control Center Replacement
// Tweak.x - Main hooking entry point

#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <ControlCenterUIKit/ControlCenterUIKit.h>
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
static NSUserDefaults *connectivityPrefs;
static NSUserDefaults *slidersPrefs;
static NSUserDefaults *powerPrefs;
static NSUserDefaults *homeGesturePrefs;
static NSUserDefaults *modulesPrefs;

static JadeCardViewController *jadeCardViewController;
static JadeMainViewController *jadeMainViewController;
static BOOL isHomeGestureDismissalAllowed = YES;
static BOOL isHomeGestureEnabled = NO;

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
    // Our custom UI is layered on top
    if (!jadeCardViewController) {
        jadeCardViewController = [[JadeCardViewController alloc] init];
    }
    jadeCardViewController.isPresented = YES;
    if (jadeCardViewController) {
        [jadeCardViewController reloadModules];
        [jadeCardViewController reloadButtons];
    }
}

- (void)dismissAnimated:(BOOL)animated withCompletionHandler:(id)completion {
    %orig;
    jadeCardViewController.isPresented = NO;
    [jadeCardViewController closeModules];
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
    return YES;
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
        prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        connectivityPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.connectivity"];
        slidersPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.sliders"];
        powerPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.power"];
        homeGesturePrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.homegesture"];
        modulesPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.modules"];

        isHomeGestureEnabled = [prefs boolForKey:@"homeGestureEnabled"];
        isHomeGestureDismissalAllowed = [prefs boolForKey:@"isHomeGestureDismissalAllowed"];

        NSLog(@"[Nightwind] -> Jade loaded successfully");
    }
}
