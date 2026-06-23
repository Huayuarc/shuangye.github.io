// AmpereSupport_UIBatteryView.h
// Battery view with amperage support - displays charging status and current

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AmpereSupport_UIBatteryView : UIView

@property (nonatomic, assign) float chargePercent;
@property (nonatomic, assign) BOOL isCharging;
@property (nonatomic, assign) BOOL isLowPowerMode;
@property (nonatomic, strong, nullable) UIColor *batteryColor;
@property (nonatomic, strong, nullable) UIColor *chargingColor;
@property (nonatomic, strong, nullable) UIColor *lowPowerColor;
@property (nonatomic, strong, nullable) UIColor *boltColor;
@property (nonatomic, assign) BOOL showsPercentLabel;
@property (nonatomic, assign) BOOL showsBoltWhenCharging;
@property (nonatomic, assign) CGFloat batteryWidth;
@property (nonatomic, assign) CGFloat batteryHeight;
@property (nonatomic, assign) CGFloat cornerRadius;

- (void)setChargePercent:(float)percent animated:(BOOL)animated;
- (void)updateBatteryAppearance;
- (void)startChargingAnimation;
- (void)stopChargingAnimation;

@end

NS_ASSUME_NONNULL_END
