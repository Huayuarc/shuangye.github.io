// JadeMainModulesCaddy.h
// Primary container view that holds the main control center modules

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JadeSmallModule;
@class JadeFullWidthModule;
@class JadeWeatherModule;
@class JadeMediaModule;
@class JadeBatteryModule;

@interface JadeMainModulesCaddy : UIView

@property (nonatomic, strong, nullable) UILabel *sectionLabel;
@property (nonatomic, strong, nullable) UIStackView *modulesStackView;
@property (nonatomic, strong, nullable) NSMutableArray<UIView *> *modules;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, assign) NSInteger modulesPerRow;
@property (nonatomic, assign) CGFloat moduleSpacing;
@property (nonatomic, assign) BOOL isExpanded;

- (void)setupViews;
- (void)setupConstraints;
- (void)addModule:(UIView *)module;
- (void)removeModule:(UIView *)module;
- (void)reloadModules;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)reorderModules;
- (void)clearAllModules;
- (void)layoutModulesInGrid;

@end

NS_ASSUME_NONNULL_END
