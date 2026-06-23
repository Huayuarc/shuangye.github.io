// JadeSlidersModule.h
// Sliders module containing brightness and volume controls

#import <UIKit/UIKit.h>
#import "JadeBrightnessSlider.h"
#import "JadeVolumeSlider.h"

NS_ASSUME_NONNULL_BEGIN

@interface JadeSlidersModule : UIView

@property (nonatomic, strong, nullable) JadeBrightnessSlider *brightnessSlider;
@property (nonatomic, strong, nullable) JadeVolumeSlider *volumeSlider;
@property (nonatomic, strong, nullable) UIView *separatorLine;
@property (nonatomic, strong, nullable) UILabel *brightnessLabel;
@property (nonatomic, strong, nullable) UILabel *volumeLabel;
@property (nonatomic, strong, nullable) UIColor *sliderTintColor;
@property (nonatomic, strong, nullable) UIColor *sliderTrackColor;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) BOOL showsLabels;
@property (nonatomic, assign) BOOL brightnessSliderEnabled;
@property (nonatomic, assign) BOOL volumeSliderEnabled;

- (void)setupViews;
- (void)setupConstraints;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)updateBrightnessValue;
- (void)updateVolumeValue;
- (void)setSliderTintColor:(UIColor *)color animated:(BOOL)animated;
- (void)startObservingBrightness;
- (void)stopObservingBrightness;
- (void)startObservingVolume;
- (void)stopObservingVolume;

@end

NS_ASSUME_NONNULL_END
