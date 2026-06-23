// JadeCardViewController.m
// Card-style view controller that hosts all modules in the Jade control center

#import "JadeCardViewController.h"
#import "JadeMainModulesCaddy.h"
#import "JadeFavoriteModulesCaddy.h"
#import "JadeMediaModule.h"
#import "JadeWeatherModule.h"
#import "JadeBatteryModule.h"
#import "JadePowerModule.h"
#import "JadeConnectivityModule.h"
#import "JadeSlidersModule.h"
#import "JadeCurrentUptimeModule.h"
#import "JadeBatteryPill.h"
#import "JadeTimePill.h"
#import "JadeSmallModule.h"
#import "JadeFullWidthModule.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Preferences
static NSString *const kJadePrefsSuite = @"com.huayuarc.jadeprefs";
static NSString *const kJadeModulesPrefsSuite = @"com.huayuarc.jade.modules";
static NSString *const kJadeSmallModulesKey = @"smallModules";
static NSString *const kJadeMainModulesKey = @"mainModules";

static UIInterfaceOrientation JadeCurrentInterfaceOrientation(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive ||
                windowScene.activationState == UISceneActivationStateForegroundInactive) {
                return windowScene.interfaceOrientation;
            }
        }
    }

    return UIInterfaceOrientationPortrait;
}

static id JadeModuleForIdentifier(id repository, SEL selector, NSString *identifier) {
    id (*moduleForIdentifier)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))objc_msgSend;
    return moduleForIdentifier(repository, selector, identifier);
}

// Private framework class forward declarations
@interface _UIBackdropView : UIView
+ (instancetype)backdropViewWithStyle:(long long)style;
- (instancetype)initWithStyle:(long long)style;
@end

@interface MTMaterialView : UIView
+ (instancetype)materialViewWithRecipe:(long long)recipe;
+ (instancetype)materialViewWithRecipeNamed:(NSString *)recipeName;
@end

@interface CCUIContentModuleContainerViewController : UIViewController
- (instancetype)initWithModuleIdentifier:(NSString *)identifier contentModule:(id)module;
@property (nonatomic, assign, getter=isExpanded) BOOL expanded;
@end

@interface JadeCardViewController () <UIScrollViewDelegate>

// Class extension properties mapped to binary ivars
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) UIView *grabber;
@property (nonatomic, strong) NSArray *includedModules;
@property (nonatomic, strong) _UIBackdropView *blurView;
@property (nonatomic, strong) NSDictionary *allModulesDictionary;
@property (nonatomic, strong) NSLayoutConstraint *backgroundImageConstraint;
@property (nonatomic, strong) NSArray *smallModulesID;
@property (nonatomic, strong) NSArray *mainModulesID;
@property (nonatomic, strong) NSArray *smallCaddyModules;
@property (nonatomic, strong) NSArray *mainCaddyModules;

// Internal methods from binary
- (void)_willPresent;
- (void)_closeExpandedModule:(id)sender;
- (void)_didEndTransitionWithContentModuleContainerTransition:(id)transition completed:(BOOL)completed;
- (void)expandModuleWithIdentifier:(NSString *)identifier;
- (void)setMediaPlayerTime:(double)time;
- (void)setPlaying:(BOOL)playing;
- (void)addModuleSettingsIfNeeded;
- (void)dismissModulePresentedContentAnimated:(BOOL)animated completion:(void (^)(void))completion;
- (void)jade_update;

@end

@implementation JadeCardViewController {
    BOOL moduleExpanded;
    BOOL isPresented;
    JadeMediaModule *mediaModule;
    NSArray *includedModules;
    UIScrollView *_scrollView;
    UIView *affordanceView;
    UIImageView *backgroundImageView;
    UIStackView *stackView;
    UIView *_grabber;
    JadeBatteryPill *_batteryPill;
    JadeTimePill *_timePill;
    JadeConnectivityModule *_connectivityModule;
    JadeSlidersModule *_brightnessAndSoundModule;
    JadeFavoriteModulesCaddy *_smallCaddy;
    JadeCurrentUptimeModule *_currentUptimeModule;
    JadePowerModule *_powerModule;
    JadeBatteryModule *_batteryModule;
    JadeWeatherModule *_weatherModule;
    JadeMainModulesCaddy *_mainCaddy;
    NSArray *_smallModulesID;
    NSArray *_mainModulesID;
    NSArray *_smallCaddyModules;
    NSArray *_mainCaddyModules;
    _UIBackdropView *_blurView;
    NSDictionary *_allModulesDictionary;
    NSLayoutConstraint *_backgroundImageConstraint;
    id _moduleRepository;
}

// Synthesize header properties to match binary ivar names
@synthesize mainStackView = stackView;
@synthesize mainModulesCaddy = _mainCaddy;
@synthesize favoriteModulesCaddy = _smallCaddy;
@synthesize slidersModule = _brightnessAndSoundModule;
@synthesize isModuleExpanded = moduleExpanded;
@synthesize connectivityModule = _connectivityModule;
@synthesize currentUptimeModule = _currentUptimeModule;
@synthesize powerModule = _powerModule;
@synthesize batteryModule = _batteryModule;
@synthesize weatherModule = _weatherModule;
@synthesize scrollView = _scrollView;
@synthesize isPresented = isPresented;

// mediaModule and backgroundImageView ivars share the same name as their properties
@synthesize mediaModule = mediaModule;
@synthesize backgroundImageView = backgroundImageView;
@synthesize includedModules = includedModules;
@synthesize grabber = _grabber;
@synthesize blurView = _blurView;
@synthesize allModulesDictionary = _allModulesDictionary;
@synthesize backgroundImageConstraint = _backgroundImageConstraint;
@synthesize smallModulesID = _smallModulesID;
@synthesize mainModulesID = _mainModulesID;
@synthesize smallCaddyModules = _smallCaddyModules;
@synthesize mainCaddyModules = _mainCaddyModules;

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        moduleExpanded = NO;
        isPresented = NO;
        _modulesLoaded = NO;
        _cardCornerRadius = 16.0;
        _cardWidth = 0.0;
        _cardMaxHeight = 500.0;
        _tintColor = [UIColor whiteColor];
        _cardBackgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];

        _smallModulesID = @[];
        _mainModulesID = @[];
        _smallCaddyModules = @[];
        _mainCaddyModules = @[];
        _allModulesDictionary = @{};
        includedModules = @[];

        // Initialize module repository via NSClassFromString
        Class repoClass = NSClassFromString(@"CCSModuleRepository");
        if (repoClass && [repoClass respondsToSelector:@selector(repository)]) {
            _moduleRepository = [repoClass performSelector:@selector(repository)];
        }

        // Initialize module identifiers from preferences
        NSUserDefaults *modulesPrefs = [[NSUserDefaults alloc] initWithSuiteName:kJadeModulesPrefsSuite];
        NSArray *smallIDs = [modulesPrefs arrayForKey:kJadeSmallModulesKey];
        NSArray *mainIDs = [modulesPrefs arrayForKey:kJadeMainModulesKey];
        if (smallIDs) _smallModulesID = [smallIDs copy];
        if (mainIDs) _mainModulesID = [mainIDs copy];

        // Create all module instances
        [self _createModuleInstances];
    }
    return self;
}

- (void)_createModuleInstances {
    // Media Module
    mediaModule = [[JadeMediaModule alloc] init];
    mediaModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Connectivity Module
    _connectivityModule = [[JadeConnectivityModule alloc] init];
    _connectivityModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Brightness & Sound (Sliders) Module
    _brightnessAndSoundModule = [[JadeSlidersModule alloc] init];
    _brightnessAndSoundModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Battery Module
    _batteryModule = [[JadeBatteryModule alloc] init];
    _batteryModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Weather Module
    _weatherModule = [[JadeWeatherModule alloc] init];
    _weatherModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Power Module
    _powerModule = [[JadePowerModule alloc] init];
    _powerModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Current Uptime Module
    _currentUptimeModule = [[JadeCurrentUptimeModule alloc] init];
    _currentUptimeModule.translatesAutoresizingMaskIntoConstraints = NO;

    // Module Caddies
    _mainCaddy = [[JadeMainModulesCaddy alloc] init];
    _mainCaddy.translatesAutoresizingMaskIntoConstraints = NO;

    _smallCaddy = [[JadeFavoriteModulesCaddy alloc] init];
    _smallCaddy.translatesAutoresizingMaskIntoConstraints = NO;

    // Battery Pill and Time Pill
    _batteryPill = [[JadeBatteryPill alloc] init];
    _batteryPill.translatesAutoresizingMaskIntoConstraints = NO;

    _timePill = [[JadeTimePill alloc] init];
    _timePill.translatesAutoresizingMaskIntoConstraints = NO;

    // Grabber handle
    _grabber = [[UIView alloc] init];
    _grabber.translatesAutoresizingMaskIntoConstraints = NO;
    _grabber.backgroundColor = [UIColor colorWithWhite:0.7 alpha:0.8];
    _grabber.layer.cornerRadius = 2.5;
    _grabber.clipsToBounds = YES;

    // Affordance view
    affordanceView = [[UIView alloc] init];
    affordanceView.translatesAutoresizingMaskIntoConstraints = NO;
}

#pragma mark - View Lifecycle (Binary Methods)

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 500)];

    // Card appearance
    view.backgroundColor = _cardBackgroundColor;
    view.layer.cornerRadius = _cardCornerRadius;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;

    // Add blur backdrop using private class
    Class backdropClass = NSClassFromString(@"_UIBackdropView");
    if (backdropClass) {
        _blurView = [[backdropClass alloc] initWithFrame:view.bounds];
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view addSubview:_blurView];
    } else {
        // Fallback: Use MTMaterialView
        Class materialClass = NSClassFromString(@"MTMaterialView");
        if (materialClass) {
            _blurView = (id)[[materialClass alloc] initWithFrame:view.bounds];
            _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [view addSubview:_blurView];
        }
    }

    // Grabber handle
    [_grabber setFrame:CGRectMake(0, 0, 36, 5)];
    [view addSubview:_grabber];

    // Affordance view (tap area for closing)
    [view addSubview:affordanceView];

    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Create scroll view
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.delegate = self;
    scrollView.clipsToBounds = NO;
    _scrollView = scrollView;

    // Create main stack view
    UIStackView *sv = [[UIStackView alloc] init];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.axis = UILayoutConstraintAxisVertical;
    sv.alignment = UIApplication.sharedApplication.userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft ? UIStackViewAlignmentTrailing : UIStackViewAlignmentLeading;
    sv.distribution = UIStackViewDistributionFill;
    sv.spacing = 8.0;
    stackView = sv;

    [scrollView addSubview:sv];
    [self.view addSubview:scrollView];

    // Add modules to stack view
    [self _arrangeModulesInStack];

    // Activate constraints
    [self setupConstraints];

    // Configure card width
    [self configureCardWidth];

    // Set up module appearance
    [self addModuleSettingsIfNeeded];

    // Update card appearance
    [self updateCardAppearance];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Update background image constraints
    if (backgroundImageView && _backgroundImageConstraint) {
        _backgroundImageConstraint.constant = -_scrollView.contentOffset.y;
    }

    // Update grabber position
    CGRect grabberFrame = _grabber.frame;
    grabberFrame.origin.x = (CGRectGetWidth(self.view.bounds) - CGRectGetWidth(grabberFrame)) / 2.0;
    grabberFrame.origin.y = 8.0;
    _grabber.frame = grabberFrame;

    // Update affordance frame
    affordanceView.frame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 40);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self configureCardWidth];
}

#pragma mark - Module Stack Arrangement

- (void)_arrangeModulesInStack {
    // Clear existing arranged subviews
    for (UIView *arrangedView in stackView.arrangedSubviews) {
        [stackView removeArrangedSubview:arrangedView];
        [arrangedView removeFromSuperview];
    }

    // Add modules in order
    // 1. Time Pill
    [stackView addArrangedSubview:_timePill];

    // 2. Battery Pill
    [stackView addArrangedSubview:_batteryPill];

    // 3. Connectivity Module
    [stackView addArrangedSubview:_connectivityModule];

    // 4. Sliders (Brightness & Sound) Module
    [stackView addArrangedSubview:_brightnessAndSoundModule];

    // 5. Small Caddy (Favorite Modules)
    [stackView addArrangedSubview:_smallCaddy];

    // 6. Main Caddy (Main Modules)
    [stackView addArrangedSubview:_mainCaddy];

    // 7. Weather Module
    [stackView addArrangedSubview:_weatherModule];

    // 8. Battery Module
    [stackView addArrangedSubview:_batteryModule];

    // 9. Current Uptime Module
    [stackView addArrangedSubview:_currentUptimeModule];

    // 10. Power Module
    [stackView addArrangedSubview:_powerModule];

    // 11. Media Module
    [stackView addArrangedSubview:mediaModule];
}

#pragma mark - Layout & Constraints

- (void)setupConstraints {
    if (!_scrollView || !stackView) return;

    [NSLayoutConstraint activateConstraints:@[
        // Scroll view constraints
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:40.0],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8.0],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0],

        // Stack view constraints (fill scrollView content)
        [stackView.topAnchor constraintEqualToAnchor:_scrollView.topAnchor],
        [stackView.leadingAnchor constraintEqualToAnchor:_scrollView.leadingAnchor],
        [stackView.trailingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor],
        [stackView.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor],
        [stackView.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor],
    ]];

    // Grabber constraints
    [NSLayoutConstraint activateConstraints:@[
        [_grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8.0],
        [_grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_grabber.widthAnchor constraintEqualToConstant:36.0],
        [_grabber.heightAnchor constraintEqualToConstant:5.0],
    ]];

    // Module-specific constraint setup calls
    [_timePill setupConstraints];
    [_batteryPill setupConstraints];
    [_connectivityModule setupConstraints];
    [_brightnessAndSoundModule setupConstraints];
    [_smallCaddy setupConstraints];
    [_mainCaddy setupConstraints];
    [_weatherModule setupConstraints];
    [_batteryModule setupConstraints];
    [_currentUptimeModule setupConstraints];
    [_powerModule setupConstraints];
    [mediaModule setupConstraints];
}

- (void)configureCardWidth {
    CGFloat screenWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    CGFloat screenHeight = CGRectGetHeight([UIScreen mainScreen].bounds);

    UIInterfaceOrientation orientation = JadeCurrentInterfaceOrientation();
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        _cardWidth = floor(screenHeight * 0.75);
        _cardMaxHeight = screenWidth * 0.9;
    } else {
        _cardWidth = floor(screenWidth * 0.85);
        _cardMaxHeight = screenHeight * 0.65;
    }

    // Apply card width
    CGRect viewFrame = self.view.frame;
    viewFrame.size.width = _cardWidth;
    self.view.frame = viewFrame;
}

- (void)layoutModules {
    // Re-arrange and update module layouts
    [self _arrangeModulesInStack];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

#pragma mark - Appearance

- (void)updateCardAppearance {
    // Update module tint colors
    UIColor *tint = _tintColor ?: [UIColor whiteColor];

    _connectivityModule.moduleTintColor = tint;
    _brightnessAndSoundModule.sliderTintColor = tint;
    _brightnessAndSoundModule.sliderTrackColor = [tint colorWithAlphaComponent:0.2];
    _smallCaddy.moduleTintColor = tint;
    _mainCaddy.moduleTintColor = tint;
    _batteryModule.moduleTintColor = tint;
    _powerModule.moduleTintColor = tint;
    mediaModule.moduleTintColor = tint;

    // Update time pill text color
    [_timePill setTextColor:tint animated:NO];

    // Update battery pill color
    _batteryPill.pillColor = tint;

    // Update weather text color
    _weatherModule.textColor = tint;
    _weatherModule.secondaryTextColor = [tint colorWithAlphaComponent:0.7];

    // Update uptime text colors
    _currentUptimeModule.textColor = tint;
    _currentUptimeModule.valueTextColor = [tint colorWithAlphaComponent:0.8];

    // Apply card background
    self.view.backgroundColor = _cardBackgroundColor;

    // Update corner radius
    self.view.layer.cornerRadius = _cardCornerRadius;
}

#pragma mark - Binary Methods

- (void)jade_update {
    // Trigger full update of all module data
    [self reloadModules];
    [self reloadButtons];
    [self updateCellularStateIfNeeded];
    [self addModuleSettingsIfNeeded];
    [self updateCardAppearance];
}

- (void)_willPresent {
    // Called when about to present - update all modules
    isPresented = YES;

    // Update connectivity states
    [_connectivityModule updateButtonStates];
    [self updateCellularStateIfNeeded];

    // Refresh weather
    [_weatherModule refreshWeather];

    // Refresh battery
    [_batteryModule refreshBatteryData];

    // Refresh uptime
    [_currentUptimeModule refreshUptime];
    [_currentUptimeModule startUpdating];

    // Update media info
    [mediaModule updateMediaInfo];

    // Update time
    [_timePill updateTime];
    [_timePill startUpdating];

    // Update battery level
    [_batteryPill updateBatteryLevel:[UIDevice currentDevice].batteryLevel];
    [_batteryPill updateBatteryState:[UIDevice currentDevice].batteryState == UIDeviceBatteryStateCharging
                            lowPower:[NSProcessInfo processInfo].isLowPowerModeEnabled];

    // Update sliders
    [_brightnessAndSoundModule updateBrightnessValue];
    [_brightnessAndSoundModule updateVolumeValue];
}

- (void)_didEndTransitionWithContentModuleContainerTransition:(id)transition completed:(BOOL)completed {
    if (completed) {
        // Transition completed - update module state
        [self jade_update];
    }
}

#pragma mark - Module Expansion

- (BOOL)moduleExpanded {
    return moduleExpanded;
}

- (void)setModuleExpanded:(BOOL)expanded {
    moduleExpanded = expanded;

    if (expanded) {
        // Minimize other modules when one is expanded
        [UIView animateWithDuration:0.25 animations:^{
            for (UIView *arrangedView in stackView.arrangedSubviews) {
                if (arrangedView != mediaModule && arrangedView != _connectivityModule) {
                    arrangedView.alpha = 0.3;
                }
            }
        }];
    } else {
        // Restore all modules
        [UIView animateWithDuration:0.25 animations:^{
            for (UIView *arrangedView in stackView.arrangedSubviews) {
                arrangedView.alpha = 1.0;
            }
        }];
    }
}

- (void)expandModuleWithIdentifier:(NSString *)identifier {
    if (!identifier) return;

    // Get the module repository via NSClassFromString
    Class repoClass = NSClassFromString(@"CCSModuleRepository");
    if (!repoClass) return;

    id repository = nil;
    if ([repoClass respondsToSelector:@selector(repository)]) {
        repository = [repoClass performSelector:@selector(repository)];
    }

    if (!repository) return;

    moduleExpanded = YES;

    SEL moduleWithIdentifierSel = @selector(moduleWithIdentifier:);
    if ([repository respondsToSelector:moduleWithIdentifierSel]) {
        id module = JadeModuleForIdentifier(repository, moduleWithIdentifierSel, identifier);
        if (module) {
            Class containerClass = NSClassFromString(@"CCUIContentModuleContainerViewController");
            if (containerClass) {
                CCUIContentModuleContainerViewController *containerVC = \
                    [[containerClass alloc] initWithModuleIdentifier:identifier contentModule:module];
                containerVC.expanded = YES;
                [self presentViewController:containerVC animated:YES completion:nil];
            }
        }
    }
}

- (void)_closeExpandedModule:(id)sender {
    moduleExpanded = NO;
    [self dismissViewControllerAnimated:YES completion:^{
        [self setModuleExpanded:NO];
    }];
}

- (void)closeModules {
    // Close any expanded module content
    if (moduleExpanded) {
        moduleExpanded = NO;
        [self dismissViewControllerAnimated:YES completion:nil];
    }

    // Close all module subviews that support setExpanded:
    [mediaModule setExpanded:NO animated:NO];
    [_connectivityModule setExpanded:NO animated:NO];
    [_brightnessAndSoundModule setExpanded:NO animated:NO];
    [_smallCaddy setExpanded:NO animated:NO];
    [_mainCaddy setExpanded:NO animated:NO];
    [_weatherModule setExpanded:NO animated:NO];
    [_batteryModule setExpanded:NO animated:NO];
    [_powerModule setExpanded:NO animated:NO];

    [self setModuleExpanded:NO];
}

- (void)dismissModulePresentedContentAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:animated completion:^{
            moduleExpanded = NO;
            if (completion) completion();
        }];
    } else {
        moduleExpanded = NO;
        if (completion) completion();
    }
}

#pragma mark - Media Controls

- (void)setMediaPlayerTime:(double)time {
    [mediaModule setExpanded:YES animated:YES];
    [mediaModule startUpdatingProgress];
}

- (void)setPlaying:(BOOL)playing {
    mediaModule.isPlaying = playing;
    [mediaModule updatePlaybackState];
}

#pragma mark - Module Loading & Configuration

- (void)reloadModules {
    NSUserDefaults *modulesPrefs = [[NSUserDefaults alloc] initWithSuiteName:kJadeModulesPrefsSuite];
    NSArray *smallIDs = [modulesPrefs arrayForKey:kJadeSmallModulesKey];
    NSArray *mainIDs = [modulesPrefs arrayForKey:kJadeMainModulesKey];

    if (smallIDs) {
        _smallModulesID = [smallIDs copy];
    }

    if (mainIDs) {
        _mainModulesID = [mainIDs copy];
    }

    // Clear existing module lists
    [_smallCaddy clearAllModules];
    [_mainCaddy clearAllModules];

    NSMutableArray *smallModules = [NSMutableArray array];
    NSMutableArray *mainModules = [NSMutableArray array];

    // Load small modules
    for (NSString *identifier in _smallModulesID) {
        UIView *moduleView = [self _createModuleViewForIdentifier:identifier isSmall:YES];
        if (moduleView) {
            [_smallCaddy addModule:moduleView];
            [smallModules addObject:moduleView];
        }
    }

    // Load main modules
    for (NSString *identifier in _mainModulesID) {
        UIView *moduleView = [self _createModuleViewForIdentifier:identifier isSmall:NO];
        if (moduleView) {
            [_mainCaddy addModule:moduleView];
            [mainModules addObject:moduleView];
        }
    }

    _smallCaddyModules = [smallModules copy];
    _mainCaddyModules = [mainModules copy];

    [_smallCaddy reloadModules];
    [_mainCaddy reloadModules];

    _modulesLoaded = YES;
}

- (UIView *)_createModuleViewForIdentifier:(NSString *)identifier isSmall:(BOOL)isSmall {
    if (!identifier) return nil;

    // Check if we already have a module view for this in the dictionary
    UIView *existingModule = _allModulesDictionary[identifier];
    if (existingModule) return existingModule;

    // Try to get module from repository
    Class repoClass = NSClassFromString(@"CCSModuleRepository");
    if (repoClass) {
        id repository = nil;
        if ([repoClass respondsToSelector:@selector(repository)]) {
            repository = [repoClass performSelector:@selector(repository)];
        }

        if (repository) {
            SEL moduleSel = @selector(moduleWithIdentifier:);
            if ([repository respondsToSelector:moduleSel]) {
                id module = JadeModuleForIdentifier(repository, moduleSel, identifier);
                if (module && [module respondsToSelector:@selector(contentViewController)]) {
                    UIViewController *contentVC = [module performSelector:@selector(contentViewController)];
                    if (contentVC && contentVC.view) {
                        UIView *moduleView = contentVC.view;

                        if (isSmall) {
                            JadeSmallModule *smallModule = [[JadeSmallModule alloc] init];
                            [smallModule setTitle:identifier];
                            [smallModule.contentView addSubview:moduleView];
                            moduleView.frame = smallModule.contentView.bounds;
                            moduleView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

                            // Cache module view
                            NSMutableDictionary *dict = [_allModulesDictionary mutableCopy];
                            dict[identifier] = smallModule;
                            _allModulesDictionary = [dict copy];

                            return smallModule;
                        } else {
                            JadeFullWidthModule *fullModule = [[JadeFullWidthModule alloc] init];
                            [fullModule setTitle:identifier];
                            [fullModule.contentView addSubview:moduleView];
                            moduleView.frame = fullModule.contentView.bounds;
                            moduleView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

                            // Cache module view
                            NSMutableDictionary *dict = [_allModulesDictionary mutableCopy];
                            dict[identifier] = fullModule;
                            _allModulesDictionary = [dict copy];

                            return fullModule;
                        }
                    }
                }
            }
        }
    }

    return nil;
}

- (void)reloadButtons {
    // Reload connectivity buttons
    [_connectivityModule reloadButtons];
    [_connectivityModule updateButtonStates];

    // Reload power module buttons
    [_powerModule reloadButtons];

    // Update weather display
    [_weatherModule updateWeatherDisplay];

    // Update battery display
    [_batteryModule updateDeviceList];

    // Update uptime
    [_currentUptimeModule refreshUptime];

    // Update media info
    [mediaModule updateMediaInfo];

    // Update time
    [_timePill updateTime];
}

- (void)updateCellularStateIfNeeded {
    [_connectivityModule updateCellularStateIfNeeded];
}

- (void)addModuleSettingsIfNeeded {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kJadePrefsSuite];

    // Connectivity module settings
    NSInteger buttonsPerRow = [prefs integerForKey:@"connectivityButtonsPerRow"];
    if (buttonsPerRow > 0) {
        _connectivityModule.buttonsPerRow = buttonsPerRow;
    }

    // Slider settings
    BOOL showSliderLabels = [prefs boolForKey:@"showSliderLabels"];
    _brightnessAndSoundModule.showsLabels = showSliderLabels;
    _brightnessAndSoundModule.brightnessSliderEnabled = [prefs boolForKey:@"brightnessSliderEnabled"];
    _brightnessAndSoundModule.volumeSliderEnabled = [prefs boolForKey:@"volumeSliderEnabled"];

    // Connectivity labels
    _connectivityModule.showsLabels = [prefs boolForKey:@"showConnectivityLabels"];

    // Power module settings
    _powerModule.showsConfirmationDialogs = [prefs boolForKey:@"showPowerConfirmation"];

    // Card settings
    CGFloat cornerRadius = [prefs floatForKey:@"cardCornerRadius"];
    if (cornerRadius > 0) {
        _cardCornerRadius = cornerRadius;
    }

    // Time pill settings
    _timePill.showsDate = [prefs boolForKey:@"timePillShowsDate"];
    _timePill.showsSeconds = [prefs boolForKey:@"timePillShowsSeconds"];
    _timePill.is24HourFormat = [prefs boolForKey:@"timePill24HourFormat"];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Update background image parallax effect
    if (backgroundImageView && _backgroundImageConstraint) {
        _backgroundImageConstraint.constant = -scrollView.contentOffset.y * 0.3;
    }
}

#pragma mark - View Setup (Header Methods)

- (void)setupViews {
    [self loadView];
    [self viewDidLoad];
}

@end
