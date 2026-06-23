// JadeBatteryPill.h
// Pill-shaped battery indicator for the Jade control center

#import <UIKit/UIKit.h>
#import "AmpereSupport_UIBatteryView.h"

NS_ASSUME_NONNULL_BEGIN

@interface JadeBatteryPill : UIView

@property (nonatomic, strong, nullable) AmpereSupport_UIBatteryView *batteryView;
@property (nonatomic, strong, nullable) UILabel *percentLabel;
@property (nonatomic, strong, nullable) UILabel *amperageLabel;
@property (nonatomic, strong, nullable) UIView *pillContainer;
@property (nonatomic, assign) float currentPercent;
@property (nonatomic, assign) BOOL isCharging;
@property (nonatomic, assign) BOOL isLowPowerMode;
@property (nonatomic, strong, nullable) UIColor *pillColor;
@property (nonatomic, strong, nullable) UIColor *pillBackgroundColor;

- (void)updateBatteryLevel:(float)level;
- (void)updateBatteryState:(BOOL)charging lowPower:(BOOL)lowPower;
- (void)updateAmperage:(NSString *)amperage;
- (void)setupViews;
- (void)setupConstraints;
- (void)setPillColor:(UIColor *)color animated:(BOOL)animated;
- (void)startPulseAnimation;
- (void)stopPulseAnimation;

@end

NS_ASSUME_NONNULL_END
