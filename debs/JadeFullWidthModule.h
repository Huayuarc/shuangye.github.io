// JadeFullWidthModule.h
// Full-width module view that spans the entire card width

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JadeFullWidthModule : UIView

@property (nonatomic, strong, nullable) UIView *contentView;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UIImageView *iconImageView;
@property (nonatomic, strong, nullable) UIView *separatorLine;
@property (nonatomic, strong, nullable) UIColor *moduleBackgroundColor;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, assign) CGFloat moduleCornerRadius;
@property (nonatomic, assign) BOOL isHighlighted;
@property (nonatomic, assign) BOOL showsSeparator;

- (void)setupViews;
- (void)setupConstraints;
- (void)setTitle:(NSString *)title;
- (void)setIcon:(UIImage *)icon;
- (void)setModuleBackgroundColor:(UIColor *)color animated:(BOOL)animated;
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated;
- (void)showSeparator:(BOOL)show;

@end

NS_ASSUME_NONNULL_END
