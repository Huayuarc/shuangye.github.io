// JadeFavoriteModulesCaddy.h
// Container view that holds the user's favorite/frequently used modules

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JadeSmallModule;
@class JadeFullWidthModule;

@interface JadeFavoriteModulesCaddy : UIView

@property (nonatomic, strong, nullable) UILabel *sectionLabel;
@property (nonatomic, strong, nullable) UIStackView *modulesStackView;
@property (nonatomic, strong, nullable) NSMutableArray<UIView *> *modules;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, assign) NSInteger maxVisibleModules;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) BOOL isAscendingOrder;

- (void)setupViews;
- (void)setupConstraints;
- (void)addModule:(UIView *)module;
- (void)removeModule:(UIView *)module;
- (void)reloadModules;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)reorderModules;
- (void)clearAllModules;

@end

NS_ASSUME_NONNULL_END
