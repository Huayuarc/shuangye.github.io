#import "AkaraModuleProviderShared.h"
#import "AkaraCommon.h"
#import <objc/runtime.h>

#ifndef AKR_PROVIDER_CLASS
#define AKR_PROVIDER_CLASS AkaraModuleProvider
#endif
#ifndef AKR_PROVIDED_MODULE_CLASS
#define AKR_PROVIDED_MODULE_CLASS ProvidedAkaraModule
#endif
#ifndef AKR_CONTENT_CLASS
#define AKR_CONTENT_CLASS AkaraProvidedModuleContentViewController
#endif
#ifndef AKR_ROOT_LIST_CLASS
#define AKR_ROOT_LIST_CLASS ProvidedAkaraModuleRootListController
#endif
#ifndef AKR_PROVIDER_IDENTIFIER_PREFIX
#define AKR_PROVIDER_IDENTIFIER_PREFIX @"com.huayuarc.akara.providedakaramodule."
#endif
#ifndef AKR_PROVIDER_DISPLAY_PREFIX
#define AKR_PROVIDER_DISPLAY_PREFIX @"AkaraModule"
#endif
#ifndef AKR_PROVIDER_PREFS_PLIST
#define AKR_PROVIDER_PREFS_PLIST @"AkaraModuleProviderPrefs"
#endif
#ifndef AKR_VERTICAL_LAYOUT
#define AKR_VERTICAL_LAYOUT 0
#endif

@protocol AKRModuleIdentifierInitializable <NSObject>
- (instancetype)initWithModuleIdentifier:(NSString *)identifier options:(NSDictionary *)options;
@end

@interface AKR_ROOT_LIST_CLASS : NSObject
@end

@interface AKRProviderFallbackContentViewController : UIViewController <CCUIContentModuleContentViewController>
@property (nonatomic, copy) NSString *titleText;
@end

@implementation AKRProviderFallbackContentViewController

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _titleText = [title copy];
    }
    return self;
}

- (void)dealloc {
    [_titleText release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = self.titleText ?: @"Module";
    label.textColor = UIColor.labelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:6.0],
        [label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-6.0],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (CGFloat)preferredExpandedContentHeight { return 120.0; }
- (CGFloat)preferredExpandedContentWidth { return 120.0; }
- (BOOL)providesOwnPlatter { return NO; }

@end

static NSString *AKRLastIdentifierComponent(NSString *identifier) {
    NSArray<NSString *> *components = [identifier componentsSeparatedByString:@"."];
    return components.lastObject ?: identifier;
}

static NSDictionary<NSString *, NSString *> *AKRKnownBundleNamesByIdentifier(void) {
    return @{
        @"com.apple.control-center.FlashlightModule": @"FlashlightModule",
        @"com.apple.donotdisturb.DoNotDisturbModule": @"FocusUIModule",
        @"com.apple.control-center.LowPowerModule": @"LowPowerModule",
        @"com.apple.control-center.CalculatorModule": @"CalculatorModule",
        @"com.apple.control-center.OrientationLockModule": @"OrientationLockModule",
        @"com.apple.replaykit.controlcenter.screencapture": @"ReplayKitModule",
        @"com.apple.control-center.DisplayModule": @"DisplayModule",
        @"com.apple.control-center.ConnectivityModule": @"ConnectivityModule",
        @"com.apple.mediaremote.controlcenter.audio": @"MediaControlsAudioModule",
        @"com.apple.mediaremote.controlcenter.nowplaying": @"MediaControlsModule",
        @"com.apple.control-center.CameraModule": @"CameraModule",
        @"com.apple.control-center.TimerModule": @"TimerModule",
        @"com.apple.control-center.AlarmModule": @"AlarmModule",
        @"com.apple.control-center.QRCodeModule": @"QRCodeModule",
        @"com.apple.control-center.WalletModule": @"WalletModule",
        @"com.apple.control-center.MagnifierModule": @"MagnifierModule",
        @"com.apple.control-center.ShazamModule": @"ShazamModule",
        @"com.apple.control-center.StopwatchModule": @"StopwatchModule",
        @"com.apple.control-center.AppearanceModule": @"AppearanceModule",
        @"com.apple.control-center.TVRemoteModule": @"TVRemoteModule"
    };
}

static NSString *AKRBundlePathForModuleIdentifier(NSString *identifier) {
    NSString *knownName = AKRKnownBundleNamesByIdentifier()[identifier];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (knownName.length > 0) {
        NSString *path = [@"/System/Library/ControlCenter/Bundles" stringByAppendingPathComponent:[knownName stringByAppendingString:@".bundle"]];
        if ([fileManager fileExistsAtPath:path]) {
            return path;
        }
    }

    NSArray<NSString *> *bundleNames = @[
        [AKRLastIdentifierComponent(identifier) stringByAppendingString:@".bundle"],
        [[AKRLastIdentifierComponent(identifier) stringByReplacingOccurrencesOfString:@"Module" withString:@""] stringByAppendingString:@"Module.bundle"]
    ];
    for (NSString *bundleName in bundleNames) {
        NSString *path = [@"/System/Library/ControlCenter/Bundles" stringByAppendingPathComponent:bundleName];
        if ([fileManager fileExistsAtPath:path]) {
            return path;
        }
    }

    NSArray<NSString *> *paths = [fileManager contentsOfDirectoryAtPath:@"/System/Library/ControlCenter/Bundles" error:nil];
    for (NSString *bundleName in paths) {
        if (![bundleName hasSuffix:@".bundle"]) {
            continue;
        }
        NSString *infoPath = [[@"/System/Library/ControlCenter/Bundles" stringByAppendingPathComponent:bundleName] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if ([info[@"CFBundleIdentifier"] isEqualToString:identifier]) {
            return [@"/System/Library/ControlCenter/Bundles" stringByAppendingPathComponent:bundleName];
        }
    }
    return nil;
}

static id AKRCreateSystemModule(NSString *identifier) {
    NSString *bundlePath = AKRBundlePathForModuleIdentifier(identifier);
    NSBundle *bundle = bundlePath ? [NSBundle bundleWithPath:bundlePath] : nil;
    if (!bundle) {
        return nil;
    }

    @try {
        [bundle load];
        Class principalClass = bundle.principalClass;
        if (!principalClass) {
            NSString *className = [bundle objectForInfoDictionaryKey:@"NSPrincipalClass"];
            principalClass = NSClassFromString(className);
        }
        if (!principalClass) {
            return nil;
        }
        if ([principalClass instancesRespondToSelector:@selector(initWithModuleIdentifier:options:)]) {
            id allocatedModule = [principalClass alloc];
            return [[(id<AKRModuleIdentifierInitializable>)allocatedModule initWithModuleIdentifier:identifier options:nil] autorelease];
        }
        return [[[principalClass alloc] init] autorelease];
    } @catch (NSException *exception) {
        NSLog(@"[Akara] failed to create module %@: %@", identifier, exception);
        return nil;
    }
}

static NSString *AKRPreferencePathForProviderIdentifier(NSString *settingsIdentifier) {
    return AKRMobilePath([NSString stringWithFormat:@"Library/Preferences/%@.plist", settingsIdentifier]);
}

static NSDictionary *AKRProviderPreferences(NSString *settingsIdentifier) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:AKRPreferencePathForProviderIdentifier(settingsIdentifier)];
    if ([preferences isKindOfClass:NSDictionary.class]) {
        return preferences;
    }
    return @{};
}

@implementation AkaraCCModuleViewController

- (instancetype)initWithModuleName:(NSString *)moduleName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _moduleIdentifier = [moduleName copy];
        _module = [AKRCreateSystemModule(moduleName) retain];
    }
    return self;
}

- (instancetype)initWithModuleIdentifier:(NSString *)identifier options:(NSDictionary *)options {
    return [self initWithModuleName:identifier];
}

- (void)dealloc {
    [_moduleIdentifier release];
    [_module release];
    [_hostedContentViewController release];
    [_hostedBackgroundViewController release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self setupModuleView];
}

- (void)setupModuleView {
    UIViewController *contentViewController = nil;
    @try {
        if ([self.module respondsToSelector:@selector(contentViewController)]) {
            contentViewController = [self.module contentViewController];
        }
    } @catch (__unused NSException *exception) {
        contentViewController = nil;
    }

    if (!contentViewController) {
        contentViewController = [[[AKRProviderFallbackContentViewController alloc] initWithTitle:[self.moduleIdentifier componentsSeparatedByString:@"."].lastObject] autorelease];
    }

    self.hostedContentViewController = contentViewController;
    [self addChildViewController:contentViewController];
    contentViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:contentViewController.view];
    [NSLayoutConstraint activateConstraints:@[
        [contentViewController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [contentViewController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [contentViewController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [contentViewController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [contentViewController didMoveToParentViewController:self];
}

- (void)setContentModuleContext:(id)context {
    if ([self.module respondsToSelector:@selector(setContentModuleContext:)]) {
        @try {
            [self.module performSelector:@selector(setContentModuleContext:) withObject:context];
        } @catch (__unused NSException *exception) {
        }
    }
}

- (CGFloat)preferredExpandedContentHeight {
    if ([self.hostedContentViewController respondsToSelector:@selector(preferredExpandedContentHeight)]) {
        return [(id)self.hostedContentViewController preferredExpandedContentHeight];
    }
    return 120.0;
}

- (CGFloat)preferredExpandedContentWidth {
    if ([self.hostedContentViewController respondsToSelector:@selector(preferredExpandedContentWidth)]) {
        return [(id)self.hostedContentViewController preferredExpandedContentWidth];
    }
    return 120.0;
}

- (BOOL)providesOwnPlatter {
    if ([self.hostedContentViewController respondsToSelector:@selector(providesOwnPlatter)]) {
        return [(id)self.hostedContentViewController providesOwnPlatter];
    }
    return NO;
}

- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (BOOL)shouldFinishTransitionToExpandedContentModule { return YES; }
- (BOOL)canDismissPresentedContent { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)expanded { self.expanded = expanded; }
- (void)didTransitionToExpandedContentMode:(BOOL)expanded { self.expanded = expanded; }
- (void)controlCenterWillPresent { if ([self.hostedContentViewController respondsToSelector:@selector(controlCenterWillPresent)]) [(id)self.hostedContentViewController controlCenterWillPresent]; }
- (void)controlCenterDidDismiss { if ([self.hostedContentViewController respondsToSelector:@selector(controlCenterDidDismiss)]) [(id)self.hostedContentViewController controlCenterDidDismiss]; }
- (void)willBecomeActive { if ([self.hostedContentViewController respondsToSelector:@selector(willBecomeActive)]) [(id)self.hostedContentViewController willBecomeActive]; }
- (void)willResignActive { if ([self.hostedContentViewController respondsToSelector:@selector(willResignActive)]) [(id)self.hostedContentViewController willResignActive]; }
- (void)expandModule {}
- (void)dismissExpandedModule {}
- (CCUILayoutSize)moduleSizeForOrientation:(int)orientation { return (CCUILayoutSize){1, 1}; }

@end

@interface AKR_CONTENT_CLASS : UIViewController <CCUIContentModuleContentViewController>
@property (nonatomic, copy) NSString *firstModuleName;
@property (nonatomic, copy) NSString *secondModuleName;
@property (nonatomic, retain) UIVisualEffectView *blurView;
@property (nonatomic, retain) AkaraCCModuleViewController *firstModuleViewController;
@property (nonatomic, retain) AkaraCCModuleViewController *secondModuleViewController;
@property (nonatomic, assign, getter=isExpanded) BOOL expanded;
- (instancetype)initWithFirstModuleName:(NSString *)firstModuleName andSecondModuleName:(NSString *)secondModuleName;
@end

@implementation AKR_CONTENT_CLASS

- (instancetype)initWithFirstModuleName:(NSString *)firstModuleName andSecondModuleName:(NSString *)secondModuleName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _firstModuleName = [firstModuleName copy];
        _secondModuleName = [secondModuleName copy];
    }
    return self;
}

- (void)dealloc {
    [_firstModuleName release];
    [_secondModuleName release];
    [_blurView release];
    [_firstModuleViewController release];
    [_secondModuleViewController release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self setupBlurView];
    [self setupModules];
}

- (void)setupBlurView {
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.blurView = [[[UIVisualEffectView alloc] initWithEffect:blurEffect] autorelease];
    self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
    self.blurView.layer.cornerRadius = 18.0;
    self.blurView.clipsToBounds = YES;
    [self.view addSubview:self.blurView];
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupModules {
    self.firstModuleViewController = [[[AkaraCCModuleViewController alloc] initWithModuleName:self.firstModuleName] autorelease];
    self.secondModuleViewController = [[[AkaraCCModuleViewController alloc] initWithModuleName:self.secondModuleName] autorelease];
    NSArray<AkaraCCModuleViewController *> *controllers = @[self.firstModuleViewController, self.secondModuleViewController];
    for (AkaraCCModuleViewController *controller in controllers) {
        [self addChildViewController:controller];
        controller.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:controller.view];
        [controller didMoveToParentViewController:self];
    }

    if (AKR_VERTICAL_LAYOUT) {
        [NSLayoutConstraint activateConstraints:@[
            [self.firstModuleViewController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.firstModuleViewController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.firstModuleViewController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.firstModuleViewController.view.bottomAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [self.secondModuleViewController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.secondModuleViewController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.secondModuleViewController.view.topAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [self.secondModuleViewController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [self.firstModuleViewController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.firstModuleViewController.view.trailingAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.firstModuleViewController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.firstModuleViewController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.secondModuleViewController.view.leadingAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.secondModuleViewController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.secondModuleViewController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.secondModuleViewController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
    }
}

- (CGFloat)preferredExpandedContentHeight { return AKR_VERTICAL_LAYOUT ? 200.0 : 100.0; }
- (CGFloat)preferredExpandedContentWidth { return AKR_VERTICAL_LAYOUT ? 100.0 : 200.0; }
- (BOOL)providesOwnPlatter { return YES; }
- (BOOL)shouldBeginTransitionToExpandedContentModule { return YES; }
- (BOOL)shouldFinishTransitionToExpandedContentModule { return YES; }
- (void)willTransitionToExpandedContentMode:(BOOL)expanded { self.expanded = expanded; }
- (void)didTransitionToExpandedContentMode:(BOOL)expanded { self.expanded = expanded; }
- (void)controlCenterWillPresent { [self.firstModuleViewController controlCenterWillPresent]; [self.secondModuleViewController controlCenterWillPresent]; }
- (void)controlCenterDidDismiss { [self.firstModuleViewController controlCenterDidDismiss]; [self.secondModuleViewController controlCenterDidDismiss]; }
- (void)setupModuleView {}
- (void)setupCCArrays {}
- (void)_updateAvailableModuleMetadata {}
- (void)_instantiateModuleWithMetadata:(id)metadata {}
- (void)activateConstraints:(NSArray *)constraints { [NSLayoutConstraint activateConstraints:constraints]; }
- (NSString *)_descriptionForIdentifier:(NSString *)identifier { return identifier; }

@end

@interface AKR_PROVIDED_MODULE_CLASS : NSObject <CCUIContentModule>
@property (nonatomic, copy) NSString *settingsIdentifier;
@property (nonatomic, retain) AKR_CONTENT_CLASS *contentViewController;
@property (nonatomic, retain) UIViewController *backgroundViewController;
- (instancetype)initWithModuleIdentifier:(NSString *)identifier contentModule:(id)contentModule presentationContext:(id)presentationContext;
@end

@implementation AKR_PROVIDED_MODULE_CLASS

- (instancetype)initWithModuleIdentifier:(NSString *)identifier contentModule:(id)contentModule presentationContext:(id)presentationContext {
    self = [super init];
    if (self) {
        _settingsIdentifier = [identifier copy];
        NSDictionary *preferences = AKRProviderPreferences(identifier);
        NSString *firstModule = preferences[@"akaraModuleProviderFirstModule"] ?: @"com.apple.control-center.FlashlightModule";
        NSString *secondModule = preferences[@"akaraModuleProviderSecondModule"] ?: @"com.apple.donotdisturb.DoNotDisturbModule";
        _contentViewController = [[AKR_CONTENT_CLASS alloc] initWithFirstModuleName:firstModule andSecondModuleName:secondModule];
    }
    return self;
}

- (instancetype)init {
    return [self initWithModuleIdentifier:[AKR_PROVIDER_IDENTIFIER_PREFIX stringByAppendingString:@"0"] contentModule:nil presentationContext:nil];
}

- (void)dealloc {
    [_settingsIdentifier release];
    [_contentViewController release];
    [_backgroundViewController release];
    [super dealloc];
}

- (void)setContentModuleContext:(id)context {
    [self.contentViewController.firstModuleViewController setContentModuleContext:context];
    [self.contentViewController.secondModuleViewController setContentModuleContext:context];
}

- (CCUILayoutSize)moduleSizeForOrientation:(int)orientation {
    return AKR_VERTICAL_LAYOUT ? (CCUILayoutSize){1, 2} : (CCUILayoutSize){2, 1};
}

@end

@interface AKR_PROVIDER_CLASS : NSObject <CCSModuleProvider>
@property (nonatomic, retain) NSMutableDictionary *moduleInstancesByIdentifier;
@end

@implementation AKR_PROVIDER_CLASS

- (instancetype)init {
    self = [super init];
    if (self) {
        _moduleInstancesByIdentifier = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_moduleInstancesByIdentifier release];
    [super dealloc];
}

- (NSArray *)loadableModuleIdentifiers {
    return @[
        [AKR_PROVIDER_IDENTIFIER_PREFIX stringByAppendingString:@"0"],
        [AKR_PROVIDER_IDENTIFIER_PREFIX stringByAppendingString:@"1"]
    ];
}

- (NSUInteger)numberOfProvidedModules {
    return self.loadableModuleIdentifiers.count;
}

- (NSString *)identifierForModuleAtIndex:(NSUInteger)index {
    NSArray *identifiers = self.loadableModuleIdentifiers;
    return index < identifiers.count ? identifiers[index] : nil;
}

- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier {
    id module = self.moduleInstancesByIdentifier[identifier];
    if (!module) {
        module = [[[AKR_PROVIDED_MODULE_CLASS alloc] initWithModuleIdentifier:identifier contentModule:nil presentationContext:nil] autorelease];
        self.moduleInstancesByIdentifier[identifier] = module;
    }
    return module;
}

- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier {
    NSUInteger index = [self.loadableModuleIdentifiers indexOfObject:identifier];
    if (index == NSNotFound) {
        index = 0;
    }
    return [NSString stringWithFormat:@"%@ %lu", AKR_PROVIDER_DISPLAY_PREFIX, (unsigned long)(index + 1)];
}

- (BOOL)providesListControllerForModuleIdentifier:(NSString *)identifier { return NO; }
- (id)listControllerForModuleIdentifier:(NSString *)identifier { return nil; }
- (NSSet *)supportedDeviceFamiliesForModuleWithIdentifier:(NSString *)identifier { return [NSSet setWithObjects:@1, @2, nil]; }
- (NSUInteger)visibilityPreferenceForModuleWithIdentifier:(NSString *)identifier { return 0; }

- (UIImage *)settingsIconForModuleIdentifier:(NSString *)identifier {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    UIImage *image = [UIImage imageNamed:@"SettingsIcon" inBundle:bundle compatibleWithTraitCollection:nil];
    return image;
}

@end

@implementation AKR_ROOT_LIST_CLASS
@end
