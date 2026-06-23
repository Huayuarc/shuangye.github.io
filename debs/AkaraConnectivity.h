/*
 * AkaraConnectivity.bundle - Complete reconstructed Objective-C header
 * Source: /tmp/akara_re/var/jb/Library/ControlCenter/Bundles/AkaraConnectivity.bundle/AkaraConnectivity
 *
 * Classes found (6 total):
 *   1. AkaraConnectivity                          : NSObject <CCUIContentModule>
 *   2. AkaraConnectivityCollectionViewCell        : UICollectionViewCell
 *   3. AkaraConnectivityModuleContentViewController : UIViewController <CCUIContentModuleContentViewController, UIScrollViewDelegate, UICollectionViewDelegate, UICollectionViewDataSource>
 *   4. AkaraConnectivityRoundButtonViewController : UIViewController
 *   5. AkaraConnectivityToggleDoubleTextView      : UIView
 *   6. AkaraConnectivityToggleViewController      : UIViewController
 *
 * Linked Libraries:
 *   - /usr/lib/libobjc.A.dylib
 *   - /System/Library/Frameworks/Foundation.framework
 *   - /System/Library/Frameworks/CoreFoundation.framework
 *   - /System/Library/Frameworks/UIKit.framework
 *   - /System/Library/Frameworks/CoreGraphics.framework
 *   - /System/Library/PrivateFrameworks/ControlCenterUIKit.framework
 *   - /usr/lib/libc++.1.dylib
 *   - /usr/lib/libSystem.B.dylib
 *
 * Observed Notification Names:
 *   - akaraUpdateNotExpandedSubtitleLabelsNotification
 *   - akaraScrollBackToFirstConnectivityPageNotification
 *   - akaraUpdateDoubleTextViewSecondaryLabelColorNotification
 *
 * Observed CC Module Identifier:
 *   - com.apple.control-center.ConnectivityModule
 *
 * Observed CC UI Class References:
 *   - CCUIModuleInstanceManager (singleton)
 *   - CCUIContentModuleContainerView
 *   - CCUIContentModuleContainerViewController
 *   - CCUIContentModulePresentationContext
 *   - CCUIConnectivityModuleViewController
 *   - CCUIConnectivityAirplaneViewController
 *   - CCUIConnectivityWifiViewController
 *   - CCUIConnectivityBluetoothViewController
 *   - CCUIConnectivityCellularDataViewController
 *   - CCUIConnectivityHotspotViewController
 *   - CCUIConnectivityAirDropViewController
 *   - CCUIConnectivityButtonViewController
 *   - CCUIRoundButton
 *
 * Observed Toggle Names:
 *   - Airplane, Wi-Fi, Bluetooth, Cellular, Hotspot, AirDrop
 *
 * Observed Settings References:
 *   - AkaraSettings (singleton via sharedSettings)
 *   - optionEnabled, useSEMode, blurOption
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class CCUIContentModuleContainerView;
@class CCUIContentModuleContainerViewController;
@class CCUIConnectivityModuleViewController;
@class CCUIConnectivityButtonViewController;
@class CCUIRoundButton;
@class AkaraConnectivityModuleContentViewController;
@class AkaraConnectivityRoundButtonViewController;
@class AkaraConnectivityToggleDoubleTextView;

#pragma mark - Forward Declarations for CCUIContentModule Protocol

@class CCUIContentModulePresentationContext;

@protocol CCUIContentModuleContentViewController <NSObject>
@required
- (CGFloat)preferredExpandedContentHeight;
@optional
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (BOOL)shouldFinishTransitionToExpandedContentModule;
- (BOOL)canDismissPresentedContent;
- (BOOL)providesOwnPlatter;
- (CGFloat)preferredExpandedContentWidth;
- (void)willResignActive;
- (void)willBecomeActive;
- (void)willTransitionToExpandedContentMode:(BOOL)expanded;
- (void)didTransitionToExpandedContentMode:(BOOL)expanded;
- (void)dismissPresentedContentAnimated:(BOOL)animated completion:(void (^)(void))completion;
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;
@end

@protocol CCUIContentModuleBackgroundViewController <NSObject>
@end

@protocol CCUIContentModule <NSObject>
@required
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController;
@optional
- (void)setContentModuleContext:(id)context;
- (UIViewController<CCUIContentModuleBackgroundViewController> *)backgroundViewController;
@end


#pragma mark - AkaraConnectivity

/**
 * CCUIContentModule for the Akara Control Center connectivity module.
 * Acts as the module factory, instantiating the content and background VCs.
 *
 * Instance size: 24 bytes
 */
@interface AkaraConnectivity : NSObject <CCUIContentModule>
{
    AkaraConnectivityModuleContentViewController *_contentViewController;
    UIViewController<CCUIContentModuleBackgroundViewController> *_backgroundViewController;
}

@property (nonatomic, strong, readonly) AkaraConnectivityModuleContentViewController *contentViewController;
@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleBackgroundViewController> *backgroundViewController;

- (NSURL *)moduleBundleURL;
- (void)_updateAvailableModuleMetadata;

@end


#pragma mark - AkaraConnectivityCollectionViewCell

/**
 * Collection view cell used in the Akara connectivity module.
 * Wraps a round button with a double text view underneath.
 *
 * Instance size: 40 bytes
 */
@interface AkaraConnectivityCollectionViewCell : UICollectionViewCell
{
    UIView *_containerView;
    AkaraConnectivityRoundButtonViewController *_roundButtonViewController;
    AkaraConnectivityToggleDoubleTextView *_doubleTextView;
    NSString *_toggleName;
}

@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) AkaraConnectivityRoundButtonViewController *roundButtonViewController;
@property (nonatomic, strong) AkaraConnectivityToggleDoubleTextView *doubleTextView;
@property (nonatomic, strong) NSString *toggleName;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)setup;
- (void)setupContainerView;
- (void)setupRoundButtonView;
- (void)setupDoubleTextView;
- (BOOL)useNativeConnectivityLabels;
- (void)updateNotExpandedConnectivityButtons;
- (void)prepareForReuse;

@end


#pragma mark - AkaraConnectivityModuleContentViewController

/**
 * Primary content view controller for the Akara connectivity module.
 * Manages a collection view of toggles (Airplane, Wi-Fi, Bluetooth, etc.)
 * and an expanded state view controller for the full connectivity UI.
 *
 * Instance size: 104 bytes
 */
@interface AkaraConnectivityModuleContentViewController : UIViewController <CCUIContentModuleContentViewController, UIScrollViewDelegate, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
{
    BOOL _providesOwnPlatter;
    BOOL _expanded;
    CGFloat _preferredExpandedContentHeight;
    CGFloat _preferredExpandedContentWidth;
    NSArray *_firstToggleNames;
    NSArray *_secondToggleNames;
    NSMutableDictionary *_connectivityToggles;
    NSDictionary *_expandedConnectivityToggles;
    UICollectionView *_connectivityCollectionView;
    CCUIContentModuleContainerView *_moduleContainerView;
    CCUIContentModuleContainerViewController *_moduleContainerViewController;
    CCUIConnectivityModuleViewController *_connectivityExpandedViewController;
    UIScrollView *_connectivityButtonContainerScrollView;
}

@property (nonatomic, readonly) CGFloat preferredExpandedContentHeight;
@property (nonatomic, readonly) CGFloat preferredExpandedContentWidth;
@property (nonatomic, readonly) BOOL providesOwnPlatter;
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;

@property (nonatomic, strong) NSArray *firstToggleNames;
@property (nonatomic, strong) NSArray *secondToggleNames;
@property (nonatomic, strong) NSMutableDictionary *connectivityToggles;
@property (nonatomic, strong) NSDictionary *expandedConnectivityToggles;
@property (nonatomic, strong) UICollectionView *connectivityCollectionView;
@property (nonatomic, strong) CCUIContentModuleContainerView *moduleContainerView;
@property (nonatomic, strong) CCUIContentModuleContainerViewController *moduleContainerViewController;
@property (nonatomic, strong) CCUIConnectivityModuleViewController *connectivityExpandedViewController;
@property (nonatomic, strong) UIScrollView *connectivityButtonContainerScrollView;

// Init
- (instancetype)initWithModuleIdentifier:(id)identifier options:(NSDictionary *)options;

// Lifecycle
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator;
- (void)willTransitionToExpandedContentMode:(BOOL)expanded;
- (void)didTransitionToExpandedContentMode:(BOOL)expanded;

// Setup
- (void)setup;
- (void)setupCollectionView;
- (void)setupExpandedStateVC;

// UI Updates
- (void)updateExpandedConnectivityButtons;
- (void)updateNotExpandedConnectivityButtons;
- (BOOL)shouldBeginTransitionToExpandedContentModule;

// UICollectionViewDataSource
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView;
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section;
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath;
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath;
- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section;

@end


#pragma mark - AkaraConnectivityRoundButtonViewController

/**
 * View controller wrapping a single CCUIRoundButton with a configured
 * CCUIConnectivityButtonViewController for a specific toggle (Airplane, Wi-Fi, etc.).
 *
 * Instance size: 32 bytes
 */
@interface AkaraConnectivityRoundButtonViewController : UIViewController
{
    NSString *_buttonName;
    CCUIConnectivityButtonViewController *_ccButtonVC;
    UIControl *_ccRoundButton;
}

@property (nonatomic, strong) NSString *buttonName;
@property (nonatomic, strong) CCUIConnectivityButtonViewController *ccButtonVC;
@property (nonatomic, strong) UIControl *ccRoundButton;

- (instancetype)initWithButtonName:(NSString *)buttonName;
- (void)setup;
- (void)setupButton:(NSString *)buttonName;
- (void)setupRoundButtonView;
- (BOOL)useNativeConnectivityLabels;

@end


#pragma mark - AkaraConnectivityToggleDoubleTextView

/**
 * Custom UIView containing a primary label and a secondary label,
 * displayed below each connectivity toggle button.
 *
 * Instance size: 40 bytes
 */
@interface AkaraConnectivityToggleDoubleTextView : UIView
{
    UIView *_containerView;
    UILabel *_primaryLabel;
    UILabel *_secondaryNameLabel;
    NSString *_primaryLabelText;
}

@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UILabel *primaryLabel;
@property (nonatomic, strong) UILabel *secondaryNameLabel;
@property (nonatomic, strong) NSString *primaryLabelText;

- (instancetype)initWithPrimaryLabelText:(NSString *)text;
- (void)setup;
- (void)setupContainerView;
- (void)setupPrimaryLabel;
- (void)setupSecondaryNameLabel;
- (void)updateLabelColorWithNotification:(NSNotification *)notification;

@end


#pragma mark - AkaraConnectivityToggleViewController

/**
 * View controller composing a round button and a double text view
 * into a single toggle unit for the connectivity module.
 *
 * Instance size: 48 bytes
 */
@interface AkaraConnectivityToggleViewController : UIViewController
{
    NSString *_toggleName;
    UIStackView *_toggleStackView;
    UIView *_containerView;
    AkaraConnectivityRoundButtonViewController *_roundButtonViewController;
    AkaraConnectivityToggleDoubleTextView *_doubleTextView;
}

@property (nonatomic, strong) NSString *toggleName;
@property (nonatomic, strong) UIStackView *toggleStackView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) AkaraConnectivityRoundButtonViewController *roundButtonViewController;
@property (nonatomic, strong) AkaraConnectivityToggleDoubleTextView *doubleTextView;

- (instancetype)initWithToggleName:(NSString *)toggleName;
- (void)setup;
- (void)setupToggleStackView;
- (void)setupToggle;
- (void)setupContainerView;
- (void)setupRoundButtonView;
- (BOOL)useNativeConnectivityLabels;

@end
