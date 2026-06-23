/**
 * AkaraVerticalModuleProvider.bundle - Complete Objective-C Header Reconstruction
 * Source binary: /tmp/akara_re/var/jb/Library/ControlCenter/CCSupport_Providers/AkaraVerticalModuleProvider.bundle/AkaraVerticalModuleProvider
 *
 * Extracted from: otool -ov, strings -a, otool -L, nm -an
 * Includes ALL classes found in the binary.
 */

#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/ControlCenterUIKit.h>
#import <Preferences/PSListController.h>

@class CCUIContentModuleContainerView;
@class CCUIContentModuleContainerViewController;
@class CCUIButtonModuleViewController;
@class AkaraCCModuleViewController;

#pragma mark - Protocol: CCSModuleProvider

@protocol CCSModuleProvider <NSObject>
@required
- (NSUInteger)numberOfProvidedModules;
- (NSString *)identifierForModuleAtIndex:(NSUInteger)index;
- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier;
- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier;

@optional
- (NSSet *)supportedDeviceFamiliesForModuleWithIdentifier:(NSString *)identifier;
- (NSSet *)requiredDeviceCapabilitiesForModuleWithIdentifier:(NSString *)identifier;
- (NSString *)associatedBundleIdentifierForModuleWithIdentifier:(NSString *)identifier;
- (NSString *)associatedBundleMinimumVersionForModuleWithIdentifier:(NSString *)identifier;
- (NSUInteger)visibilityPreferenceForModuleWithIdentifier:(NSString *)identifier;
- (UIImage *)settingsIconForModuleIdentifier:(NSString *)identifier;
- (BOOL)providesListControllerForModuleIdentifier:(NSString *)identifier;
- (id)listControllerForModuleIdentifier:(NSString *)identifier;
@end


#pragma mark - AkaraCCModuleViewController : UIViewController

/**
 * Instance size: 40 bytes
 * Flags: RO_HAS_CXX_STRUCTORS
 * Protocols: (none directly; conforms via content child)
 */
@interface AkaraCCModuleViewController : UIViewController
{
    NSString *_moduleName;
    CCUIContentModuleContainerView *_moduleContainerView;
    CCUIContentModuleContainerViewController *_moduleContainerViewController;
    CCUIButtonModuleViewController *_buttonViewController;
}

@property (nonatomic, retain) NSString *moduleName;
@property (nonatomic, retain) CCUIContentModuleContainerView *moduleContainerView;
@property (nonatomic, retain) CCUIContentModuleContainerViewController *moduleContainerViewController;
@property (nonatomic, retain) CCUIButtonModuleViewController *buttonViewController;

// --- Initializers ---
- (instancetype)initWithModuleIdentifier:(NSString *)identifier options:(NSDictionary *)options;
- (instancetype)initWithModuleName:(NSString *)moduleName;

// --- Lifecycle ---
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)viewDidDisappear:(BOOL)animated;

// --- CCS Module Content View Controller Protocol ---
- (double)preferredExpandedContentHeight;
- (double)preferredExpandedContentWidth;
- (BOOL)providesOwnPlatter;
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (BOOL)shouldFinishTransitionToExpandedContentModule;
- (BOOL)canDismissPresentedContent;
- (void)willTransitionToExpandedContentMode:(BOOL)expanded;
- (void)didTransitionToExpandedContentMode:(BOOL)expanded;
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;

// --- Custom Methods ---
- (void)setContentModuleContext:(id)context;
- (CCUILayoutSize)moduleSizeForOrientation:(int)orientation;
- (void)expandModule;
- (void)dismissExpandedModule;
- (CGRect)compactModeFrameForContentModuleContainerViewController:(id)viewController;
- (BOOL)_canShowWhileLocked;
- (BOOL)isTransitioning;
- (void)willBecomeActive;
- (void)willResignActive;
- (void)setupModuleView;
- (void)setContentModuleProvidesOwnPlatter:(BOOL)provides;
- (void)setIgnoreFrameUpdates:(BOOL)ignores;
- (void)setMaterialGroupName:(NSString *)name;

// --- Content Module Container Callbacks ---
- (void)contentModuleContainerViewController:(id)containerViewController willPresentViewController:(UIViewController *)viewController;
- (void)contentModuleContainerViewController:(id)containerViewController willDismissViewController:(UIViewController *)viewController;
- (BOOL)contentModuleContainerViewController:(id)containerViewController canBeginInteractionWithModule:(id)module;
- (void)contentModuleContainerViewController:(id)containerViewController didBeginInteractionWithModule:(id)module;
- (void)contentModuleContainerViewController:(id)containerViewController didFinishInteractionWithModule:(id)module;
- (void)contentModuleContainerViewController:(id)containerViewController willOpenExpandedModule:(id)module;
- (void)contentModuleContainerViewController:(id)containerViewController didOpenExpandedModule:(id)module;
- (void)contentModuleContainerViewController:(id)containerViewController willCloseExpandedModule:(id)module;
- (void)contentModuleContainerViewController:(id)containerViewController didCloseExpandedModule:(id)module;
- (void)contentModuleContainerViewControllerDismissPresentedContent:(id)containerViewController;

// --- UIViewController Content Module ---
- (void)beginAppearanceTransition:(BOOL)appear animated:(BOOL)animated;
- (void)ccui_safelyBeginAppearanceTransition:(BOOL)appear animated:(BOOL)animated;
- (void)ccui_safelyEndAppearanceTransition;

// --- Button Module ---
- (void)setButtonViewController:(CCUIButtonModuleViewController *)buttonViewController;
- (CCUIButtonModuleViewController *)buttonViewController;
@end


#pragma mark - AkaraVerticalModuleProvider : NSObject <CCSModuleProvider>

/**
 * CCS Module Provider for Akara Vertical modules.
 * Instance size: 16 bytes
 * Provides the vertical split module to Control Center.
 */
@interface AkaraVerticalModuleProvider : NSObject <CCSModuleProvider>
{
    NSMutableDictionary *_moduleInstancesByIdentifier;
}

@property (nonatomic, retain) NSMutableDictionary *moduleInstancesByIdentifier;

// --- CCSModuleProvider Required ---
- (NSUInteger)numberOfProvidedModules;
- (NSString *)identifierForModuleAtIndex:(NSUInteger)index;
- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier;
- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier;

// --- CCSModuleProvider Optional Implemented ---
- (BOOL)providesListControllerForModuleIdentifier:(NSString *)identifier;
- (id)listControllerForModuleIdentifier:(NSString *)identifier;

// --- Custom ---
- (NSArray *)loadableModuleIdentifiers;
- (void)setModuleInstancesByIdentifier:(NSMutableDictionary *)moduleInstances;
@end


#pragma mark - Protocol: CCUIContentModuleContentViewController (ControlCenterUIKit)

@protocol CCUIContentModuleContentViewController <NSObject>
@required
@property (nonatomic, readonly) double preferredExpandedContentHeight;

@optional
@property (nonatomic, readonly) double preferredExpandedContentWidth;
@property (nonatomic, readonly) BOOL providesOwnPlatter;
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (BOOL)shouldFinishTransitionToExpandedContentModule;
- (BOOL)canDismissPresentedContent;
- (void)willTransitionToExpandedContentMode:(BOOL)expanded;
- (void)didTransitionToExpandedContentMode:(BOOL)expanded;
- (void)dismissPresentedContentAnimated:(BOOL)animated completion:(void (^)(void))completion;
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;
- (void)willBecomeActive;
- (void)willResignActive;
@end


#pragma mark - Protocol: CCUIContentModule (ControlCenterUIKit)

@protocol CCUIContentModule <NSObject>
@required
@property (nonatomic, readonly, strong) UIViewController<CCUIContentModuleContentViewController> *contentViewController;

@optional
@property (nonatomic, readonly, strong) UIViewController<CCUIContentModuleBackgroundViewController> *backgroundViewController;
- (void)setContentModuleContext:(id)context;
@end


#pragma mark - AkaraVerticalProvidedModuleContentViewController : UIViewController <CCUIContentModuleContentViewController>

/**
 * Content view controller for the vertical split Akara module.
 * Instance size: 72 bytes
 * Manages two AkaraCCModuleViewControllers (first and second module).
 */
@interface AkaraVerticalProvidedModuleContentViewController : UIViewController <CCUIContentModuleContentViewController>
{
    BOOL _providesOwnPlatter;
    BOOL _expanded;
    double _preferredExpandedContentHeight;
    double _preferredExpandedContentWidth;
    NSString *_firstModuleName;
    NSString *_secondModuleName;
    UIVisualEffectView *_blurView;
    AkaraCCModuleViewController *_firstModuleViewController;
    AkaraCCModuleViewController *_secondModuleViewController;
}

@property (nonatomic, readonly) double preferredExpandedContentHeight;
@property (nonatomic, readonly) double preferredExpandedContentWidth;
@property (nonatomic, readonly) BOOL providesOwnPlatter;
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;
@property (nonatomic, retain) NSString *firstModuleName;
@property (nonatomic, retain) NSString *secondModuleName;
@property (nonatomic, retain) UIVisualEffectView *blurView;
@property (nonatomic, retain) AkaraCCModuleViewController *firstModuleViewController;
@property (nonatomic, retain) AkaraCCModuleViewController *secondModuleViewController;

- (instancetype)initWithFirstModuleName:(NSString *)firstModuleName andSecondModuleName:(NSString *)secondModuleName;

// --- Lifecycle ---
- (void)viewDidLoad;
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;

// --- CCUIContentModuleContentViewController Required ---
- (double)preferredExpandedContentHeight;
- (double)preferredExpandedContentWidth;

// --- CCUIContentModuleContentViewController Optional ---
- (BOOL)providesOwnPlatter;
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (BOOL)shouldFinishTransitionToExpandedContentModule;
- (BOOL)isExpanded;

// --- Custom Setup ---
- (void)setupModuleView;
- (void)setupModules;
- (void)setupBlurView;
- (void)setupCCArrays;
- (void)_updateAvailableModuleMetadata;
- (void)_instantiateModuleWithMetadata:(id)metadata;

// --- Constraint Helpers ---
- (void)activateConstraints:(NSArray *)constraints;

// --- Getter helpers ---
- (NSString *)_descriptionForIdentifier:(NSString *)identifier;
@end


#pragma mark - ProvidedAkaraVerticalModule : NSObject <CCUIContentModule>

/**
 * CCUIContentModule implementation for the Akara vertical split module.
 * Instance size: 32 bytes
 */
@interface ProvidedAkaraVerticalModule : NSObject <CCUIContentModule>
{
    NSString *_settingsIdentifier;
    AkaraVerticalProvidedModuleContentViewController *_contentViewController;
    UIViewController<CCUIContentModuleBackgroundViewController> *_backgroundViewController;
}

@property (nonatomic, retain) NSString *settingsIdentifier;
@property (nonatomic, readonly, strong) AkaraVerticalProvidedModuleContentViewController *contentViewController;
@property (nonatomic, readonly, strong) UIViewController<CCUIContentModuleBackgroundViewController> *backgroundViewController;

- (instancetype)initWithModuleIdentifier:(NSString *)identifier contentModule:(id)contentModule presentationContext:(id)presentationContext;
- (CCUILayoutSize)moduleSizeForOrientation:(int)orientation;
- (void)setContentModuleContext:(id)context;
@end


#pragma mark - ProvidedAkaraVerticalModuleRootListController : PSListController

/**
 * Settings root list controller for the Akara vertical module preferences.
 * Instance size: 48 bytes
 * Extends PSListController (Preferences framework).
 */
@interface ProvidedAkaraVerticalModuleRootListController : PSListController
{
    NSString *_settingsIdentifier;
    NSString *_displayName;
    NSMutableArray *_ccTitles;
    NSMutableArray *_ccValues;
}

@property (nonatomic, retain) NSString *settingsIdentifier;
@property (nonatomic, retain) NSString *displayName;
@property (nonatomic, retain) NSMutableArray *ccTitles;
@property (nonatomic, retain) NSMutableArray *ccValues;

// --- Lifecycle ---
- (void)viewDidLoad;
- (void)load;

// --- PSListController Overrides ---
- (id)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
- (id)specifiers;
- (void)reloadSpecifiers;

// --- Custom Methods ---
- (void)setupCCArrays;
- (void)getCCTitles:(NSArray **)titles;
- (void)getCCValues:(NSArray **)values;
- (void)applyChanges;
@end
