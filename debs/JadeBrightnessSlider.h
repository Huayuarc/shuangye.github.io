// JadeBrightnessSlider.h
// Custom brightness slider for the Jade control center

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JadeBrightnessSlider : UIControl

@property (nonatomic, assign) float value;
@property (nonatomic, assign) float minimumValue;
@property (nonatomic, assign) float maximumValue;
@property (nonatomic, strong, nullable) UIImageView *iconImageView;
@property (nonatomic, strong, nullable) UISlider *slider;
@property (nonatomic, strong, nullable) UIView *trackView;
@property (nonatomic, strong, nullable) UIView *progressView;
@property (nonatomic, strong, nullable) UIView *thumbView;
@property (nonatomic, strong, nullable) UIColor *trackColor;
@property (nonatomic, strong, nullable) UIColor *progressColor;
@property (nonatomic, strong, nullable) UIColor *thumbColor;
@property (nonatomic, assign) CGFloat sliderHeight;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign, getter=isContinuous) BOOL continuous;

- (void)setValue:(float)value animated:(BOOL)animated;
- (void)setIcon:(UIImage *)icon;
- (void)setupViews;
- (void)setupConstraints;
- (void)updateSliderAppearance;
- (void)beginTrackingInteraction;
- (void)endTrackingInteraction;

@end

NS_ASSUME_NONNULL_END
