// JadeSmallModule.h
// Small compact module view for grid layout in the control center

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JadeSmallModule : UIView

@property (nonatomic, strong, nullable) UIView *contentView;
@property (nonatomic, strong, nullable) UIImageView *iconImageView;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UILabel *subtitleLabel;
@property (nonatomic, strong, nullable) UISwitch *toggleSwitch;
@property (nonatomic, strong, nullable) UIColor *moduleBackgroundColor;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, strong, nullable) UIColor *highlightedColor;
@property (nonatomic, assign) CGFloat moduleCornerRadius;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isHighlighted;
@property (nonatomic, assign) BOOL showsToggle;
@property (nonatomic, assign) BOOL toggleState;

- (void)setupViews;
- (void)setupConstraints;
- (void)setTitle:(NSString *)title;
- (void)setSubtitle:(NSString *)subtitle;
- (void)setIcon:(UIImage *)icon;
- (void)setActive:(BOOL)active animated:(BOOL)animated;
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated;
- (void)setModuleBackgroundColor:(UIColor *)color animated:(BOOL)animated;
- (void)setToggleState:(BOOL)on animated:(BOOL)animated;
- (void)toggleAction:(id)sender;

@end

NS_ASSUME_NONNULL_END
