#import <UIKit/UIKit.h>

@interface SBFloatingDockPlatterView : UIView
@property (nonatomic, retain) UIView *backgroundView;
@end

@interface SBIconListGridLayoutConfiguration : NSObject
@property (nonatomic, assign) unsigned long long numberOfPortraitRows;
@end

@interface SBIconListView : UIView
@property (nonatomic, copy) NSString *iconLocation;
@end

@interface SBMainSwitcherControllerCoordinator : UIViewController
+ (instancetype)sharedInstance;
- (BOOL)isAnySwitcherVisible;
@end

@interface SBMainSwitcherViewController : UIViewController
+ (instancetype)sharedInstance;
- (BOOL)isMainSwitcherVisible;
@end

@interface SBFloatingDockController : NSObject
+ (BOOL)isFloatingDockSupported;
- (void)_dismissFloatingDockIfPresentedAnimated:(BOOL)animated completionHandler:(id)completionHandler;
- (void)_presentFloatingDockIfDismissedAnimated:(BOOL)animated completionHandler:(id)completionHandler;
@end

@interface SBFloatingDockBehaviorAssertion : NSObject
@property (nonatomic, readonly) SBFloatingDockController *floatingDockController;
@end

@interface SBHomeScreenViewController : UIViewController
@property (nonatomic, retain) SBFloatingDockBehaviorAssertion *homeScreenFloatingDockAssertion;
@end

@interface SBIconController : UIViewController
+ (instancetype)sharedInstance;
@property (nonatomic, readonly) SBFloatingDockController *floatingDockController;
@property (nonatomic, retain) SBHomeScreenViewController *parentViewController;
@end

@interface SBBestAppSuggestion : NSObject
- (BOOL)isHandoff;
@end

@interface SBFloatingDockSuggestionsModel : NSObject
@property (nonatomic, readonly) SBBestAppSuggestion *currentAppSuggestion;
@end

@interface SpringBoard : UIApplication
- (BOOL)isShowingHomescreen;
@end

static BOOL gFloatingDockEnabled = NO;
static BOOL gDockTransparentBackground = NO;
static BOOL gDockRemoveSeparator = NO;
static BOOL gDockDisableAppLibrary = NO;
static NSInteger gDockStyle = 0;
static NSInteger gDockMaxRecents = 3;
static NSInteger gDockMaxIcons = 4;
static NSInteger gDockVisibility = 0;

static NSInteger SpeedsterDockInteger(NSDictionary *preferences, NSString *key, NSInteger fallback, NSInteger minimum, NSInteger maximum) {
    NSNumber *value = preferences[key];
    NSInteger result = value ? value.integerValue : fallback;
    return MIN(MAX(result, minimum), maximum);
}

static void SpeedsterLoadDockPreferences(void) {
    NSDictionary *preferences = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"] ?: @{};
    gFloatingDockEnabled = [preferences[@"floatingDockEnabled"] boolValue];
    gDockTransparentBackground = [preferences[@"dockTransparentBackground"] boolValue];
    gDockRemoveSeparator = [preferences[@"dockRemoveSeparator"] boolValue];
    gDockDisableAppLibrary = [preferences[@"disableAppLibrary"] boolValue];
    gDockStyle = SpeedsterDockInteger(preferences, @"dockStyle", 0, 0, 3);
    gDockMaxRecents = SpeedsterDockInteger(preferences, @"dockMaxRecents", 3, 1, 10);
    gDockMaxIcons = SpeedsterDockInteger(preferences, @"dockMaxIcons", 4, 1, 10);
    NSInteger dockVisibility = [preferences[@"dockVisibility"] integerValue];
    gDockVisibility = dockVisibility == 1 ? 1 : 0;
}

static void SpeedsterDockPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SpeedsterLoadDockPreferences();
}

static BOOL SpeedsterDockRecentsEnabled(void) {
    return gDockStyle == 0 || gDockStyle == 2;
}

static BOOL SpeedsterDockAppLibraryEnabled(void) {
    return !gDockDisableAppLibrary && (gDockStyle == 1 || gDockStyle == 2);
}

static BOOL SpeedsterDockAllowedInApps(void) {
    return gDockVisibility == 1;
}

static BOOL SpeedsterDockAllowedInSwitcher(void) {
    return gDockVisibility == 0;
}

static BOOL SpeedsterSystemVersionAtLeast16(void) {
    return [[[UIDevice currentDevice] systemVersion] compare:@"16.0" options:NSNumericSearch] != NSOrderedAscending;
}

static BOOL SpeedsterSwitcherVisible(void) {
    if (SpeedsterSystemVersionAtLeast16()) {
        return [[%c(SBMainSwitcherControllerCoordinator) sharedInstance] isAnySwitcherVisible];
    }
    return [[%c(SBMainSwitcherViewController) sharedInstance] isMainSwitcherVisible];
}

static BOOL SpeedsterShowingHomeScreen(void) {
    SpringBoard *springBoard = (SpringBoard *)[%c(SpringBoard) sharedApplication];
    return [springBoard respondsToSelector:@selector(isShowingHomescreen)] && [springBoard isShowingHomescreen];
}

static SBFloatingDockController *SpeedsterFloatingDockController(void) {
    SBIconController *iconController = [%c(SBIconController) sharedInstance];
    if (SpeedsterSystemVersionAtLeast16()) {
        SBFloatingDockController *controller = iconController.parentViewController.homeScreenFloatingDockAssertion.floatingDockController;
        if (controller) return controller;
    }
    return iconController.floatingDockController;
}

static void SpeedsterShowFloatingDock(void) {
    SBFloatingDockController *controller = SpeedsterFloatingDockController();
    if ([controller respondsToSelector:@selector(_presentFloatingDockIfDismissedAnimated:completionHandler:)]) {
        [controller _presentFloatingDockIfDismissedAnimated:YES completionHandler:nil];
    }
}

static void SpeedsterHideFloatingDock(void) {
    if (SpeedsterShowingHomeScreen()) return;
    SBFloatingDockController *controller = SpeedsterFloatingDockController();
    if ([controller respondsToSelector:@selector(_dismissFloatingDockIfPresentedAnimated:completionHandler:)]) {
        [controller _dismissFloatingDockIfPresentedAnimated:YES completionHandler:nil];
    }
}

static void SpeedsterHandleSwitcherTransition(void) {
    if (!gFloatingDockEnabled) return;
    BOOL switcherVisible = SpeedsterSwitcherVisible();
    if (SpeedsterShowingHomeScreen() && !switcherVisible) {
        SpeedsterShowFloatingDock();
    } else if (switcherVisible && !SpeedsterDockAllowedInSwitcher()) {
        SpeedsterHideFloatingDock();
    }
}

%group SpeedsterDockHooks

%hook SBDockView
- (void)setBackgroundAlpha:(CGFloat)alpha {
    %orig(gDockTransparentBackground ? 0.0 : alpha);
}
%end

%hook SBFloatingDockPlatterView
- (void)setBackgroundView:(UIView *)backgroundView {
    %orig;
    self.backgroundView.hidden = gDockTransparentBackground;
}

- (void)didMoveToWindow {
    %orig;
    self.backgroundView.hidden = gDockTransparentBackground;
}
%end

%hook SBFloatingDockController
+ (BOOL)isFloatingDockSupported {
    return gFloatingDockEnabled ? YES : %orig;
}

- (void)_configureFloatingDockBehaviorAssertionForOpenFolder:(id)folder atLevel:(NSUInteger)level {
    if (!gFloatingDockEnabled) %orig;
}
%end

%hook SBFloatingDockView
- (void)updateDividerVisualStyling {
    if (gFloatingDockEnabled && gDockRemoveSeparator) return;
    %orig;
}
%end

%hook SBFloatingDockDefaults
- (void)setRecentsEnabled:(BOOL)enabled {
    %orig(gFloatingDockEnabled ? SpeedsterDockRecentsEnabled() : enabled);
}

- (BOOL)recentsEnabled {
    return gFloatingDockEnabled ? SpeedsterDockRecentsEnabled() : %orig;
}

- (void)setAppLibraryEnabled:(BOOL)enabled {
    %orig(gFloatingDockEnabled ? SpeedsterDockAppLibraryEnabled() : enabled);
}

- (BOOL)appLibraryEnabled {
    return gFloatingDockEnabled ? SpeedsterDockAppLibraryEnabled() : %orig;
}
%end

%hook SBIconListGridLayoutConfiguration
- (unsigned long long)numberOfPortraitColumns {
    unsigned long long columns = %orig;
    if (gFloatingDockEnabled && self.numberOfPortraitRows == 1 && columns == 4) {
        return (unsigned long long)gDockMaxIcons;
    }
    return columns;
}
%end

%hook SBIconListView
- (unsigned long long)maximumIconCount {
    if (gFloatingDockEnabled && [self.iconLocation isEqualToString:@"SBIconLocationDock"]) {
        return (unsigned long long)gDockMaxIcons;
    }
    return %orig;
}
%end

%hook SBFluidSwitcherViewController
- (BOOL)isFloatingDockGesturePossible {
    return gFloatingDockEnabled ? SpeedsterDockAllowedInApps() : %orig;
}

- (BOOL)isFloatingDockSupported {
    if (!gFloatingDockEnabled) return %orig;
    return SpeedsterSwitcherVisible() ? SpeedsterDockAllowedInSwitcher() : SpeedsterDockAllowedInApps();
}
%end

%hook SBMainSwitcherControllerCoordinator
- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidBeginWithTransitionContext:(id)context {
    %orig;
    SpeedsterHandleSwitcherTransition();
}
%end

%hook SBMainSwitcherViewController
- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidBeginWithTransitionContext:(id)context {
    %orig;
    SpeedsterHandleSwitcherTransition();
}
%end

%end

%group SpeedsterDockRecents16

%hook SBFloatingDockSuggestionsModel
- (BOOL)recentDisplayItemsController:(id)controller shouldAddItem:(id)item {
    if (gFloatingDockEnabled && [self.currentAppSuggestion isHandoff]) return NO;
    return %orig;
}

- (instancetype)initWithMaximumNumberOfSuggestions:(NSUInteger)maximum iconController:(id)iconController recentsController:(id)recentsController recentsDataStore:(id)recentsDataStore recentsDefaults:(id)recentsDefaults floatingDockDefaults:(id)floatingDockDefaults appSuggestionManager:(id)appSuggestionManager applicationController:(id)applicationController {
    return %orig(gFloatingDockEnabled ? (NSUInteger)gDockMaxRecents : maximum, iconController, recentsController, recentsDataStore, recentsDefaults, floatingDockDefaults, appSuggestionManager, applicationController);
}

- (unsigned long long)maxSuggestions {
    return gFloatingDockEnabled ? (unsigned long long)gDockMaxRecents : %orig;
}
%end

%hook SBFloatingDockSuggestionsViewController
- (instancetype)initWithNumberOfRecents:(unsigned long long)numberOfRecents iconController:(id)iconController applicationController:(id)applicationController layoutStateTransitionCoordinator:(id)coordinator suggestionsModel:(id)suggestionsModel iconViewProvider:(id)iconViewProvider {
    return %orig(gFloatingDockEnabled ? (unsigned long long)gDockMaxRecents : numberOfRecents, iconController, applicationController, coordinator, suggestionsModel, iconViewProvider);
}
%end

%end


%group SpeedsterDockRecents15

%hook SBFloatingDockSuggestionsModel
- (BOOL)recentDisplayItemsController:(id)controller shouldAddItem:(id)item {
    if (gFloatingDockEnabled && [self.currentAppSuggestion isHandoff]) return NO;
    return %orig;
}

- (instancetype)initWithMaximumNumberOfSuggestions:(unsigned long long)maximum iconController:(id)iconController recentsController:(id)recentsController recentsDataStore:(id)recentsDataStore recentsDefaults:(id)recentsDefaults floatingDockDefaults:(id)floatingDockDefaults appSuggestionManager:(id)appSuggestionManager analyticsClient:(id)analyticsClient applicationController:(id)applicationController {
    return %orig(gFloatingDockEnabled ? (unsigned long long)gDockMaxRecents : maximum, iconController, recentsController, recentsDataStore, recentsDefaults, floatingDockDefaults, appSuggestionManager, analyticsClient, applicationController);
}

- (unsigned long long)maxSuggestions {
    return gFloatingDockEnabled ? (unsigned long long)gDockMaxRecents : %orig;
}
%end

%hook SBFloatingDockSuggestionsViewController
- (instancetype)initWithNumberOfRecents:(unsigned long long)numberOfRecents iconController:(id)iconController applicationController:(id)applicationController layoutStateTransitionCoordinator:(id)coordinator suggestionsModel:(id)suggestionsModel iconViewProvider:(id)iconViewProvider {
    return %orig(gFloatingDockEnabled ? (unsigned long long)gDockMaxRecents : numberOfRecents, iconController, applicationController, coordinator, suggestionsModel, iconViewProvider);
}
%end

%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        SpeedsterLoadDockPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SpeedsterDockPreferencesChanged, CFSTR("com.hoangdus.speedsterprefs-updated"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(SpeedsterDockHooks);
        if (SpeedsterSystemVersionAtLeast16()) {
            %init(SpeedsterDockRecents16);
        } else {
            %init(SpeedsterDockRecents15);
        }
    }
}
