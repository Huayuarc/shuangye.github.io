// JadeCardViewController.h
// Card-style view controller that hosts all modules in the Jade control center

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JadeMainModulesCaddy;
@class JadeFavoriteModulesCaddy;
@class JadeMediaModule;
@class JadeWeatherModule;
@class JadeBatteryModule;
@class JadePowerModule;
@class JadeConnectivityModule;
@class JadeSlidersModule;
@class JadeCurrentUptimeModule;

@interface JadeCardViewController : UIViewController

// Module containers
@property (nonatomic, strong, nullable) UIScrollView *scrollView;
@property (nonatomic, strong, nullable) UIStackView *mainStackView;
@property (nonatomic, strong, nullable) JadeMainModulesCaddy *mainModulesCaddy;
@property (nonatomic, strong, nullable) JadeFavoriteModulesCaddy *favoriteModulesCaddy;
@property (nonatomic, strong, nullable) JadeMediaModule *mediaModule;
@property (nonatomic, strong, nullable) JadeWeatherModule *weatherModule;
@property (nonatomic, strong, nullable) JadeBatteryModule *batteryModule;
@property (nonatomic, strong, nullable) JadePowerModule *powerModule;
@property (nonatomic, strong, nullable) JadeConnectivityModule *connectivityModule;
@property (nonatomic, strong, nullable) JadeSlidersModule *slidersModule;
@property (nonatomic, strong, nullable) JadeCurrentUptimeModule *currentUptimeModule;

// State
@property (nonatomic, assign) BOOL isPresented;
@property (nonatomic, assign) BOOL isModuleExpanded;
@property (nonatomic, assign) BOOL modulesLoaded;

// Appearance
@property (nonatomic, strong, nullable) UIColor *tintColor;
@property (nonatomic, strong, nullable) UIColor *cardBackgroundColor;
@property (nonatomic, assign) CGFloat cardCornerRadius;
@property (nonatomic, assign) CGFloat cardWidth;
@property (nonatomic, assign) CGFloat cardMaxHeight;

- (void)reloadModules;
- (void)reloadButtons;
- (void)closeModules;
- (void)setModuleExpanded:(BOOL)expanded;
- (void)updateCellularStateIfNeeded;
- (void)setupViews;
- (void)setupConstraints;
- (void)layoutModules;
- (void)updateCardAppearance;
- (void)configureCardWidth;

@end

NS_ASSUME_NONNULL_END
