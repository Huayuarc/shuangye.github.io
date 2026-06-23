// AmpereSupport_UIBatteryView.m
// Subclass of _UIBatteryView with amperage/charging display support

#import "AmpereSupport_UIBatteryView.h"
#import <UIKit/UIKit.h>

// _UIBatteryView is a private class - declare its interface
@interface _UIBatteryView : UIView
- (void)setChargePercent:(NSInteger)percent;
- (void)setChargingState:(BOOL)charging;
- (void)setBoltColor:(UIColor *)color;
- (void)setShowsInlineChargingIndicator:(BOOL)shows;
@end

@interface AmpereSupport_UIBatteryView ()
@property (nonatomic, strong) UIImageView *chargingImageView;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UILabel *ampLabel;
@end

@implementation AmpereSupport_UIBatteryView

@synthesize chargePercent = _chargePercent;
@synthesize isCharging = _isCharging;
@synthesize isLowPowerMode = _isLowPowerMode;
@synthesize batteryColor = _batteryColor;
@synthesize chargingColor = _chargingColor;
@synthesize lowPowerColor = _lowPowerColor;
@synthesize boltColor = _boltColor;
@synthesize showsPercentLabel = _showsPercentLabel;
@synthesize showsBoltWhenCharging = _showsBoltWhenCharging;
@synthesize batteryWidth = _batteryWidth;
@synthesize batteryHeight = _batteryHeight;
@synthesize cornerRadius = _cornerRadius;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _percentLabel.textAlignment = NSTextAlignmentCenter;
        _percentLabel.font = [UIFont systemFontOfSize:10];
        _percentLabel.textColor = [UIColor whiteColor];
        _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_percentLabel];

        _chargingImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _chargingImageView.image = [UIImage systemImageNamed:@"bolt.fill"];
        _chargingImageView.tintColor = [UIColor systemGreenColor];
        _chargingImageView.contentMode = UIViewContentModeScaleAspectFit;
        _chargingImageView.translatesAutoresizingMaskIntoConstraints = NO;
        _chargingImageView.hidden = YES;
        [self addSubview:_chargingImageView];

        _ampLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _ampLabel.textAlignment = NSTextAlignmentCenter;
        _ampLabel.font = [UIFont systemFontOfSize:8];
        _ampLabel.textColor = [UIColor systemGreenColor];
        _ampLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _ampLabel.hidden = YES;
        [self addSubview:_ampLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_percentLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_percentLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [_chargingImageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_chargingImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-6],
            [_chargingImageView.widthAnchor constraintEqualToConstant:10],
            [_chargingImageView.heightAnchor constraintEqualToConstant:10],

            [_ampLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_ampLabel.topAnchor constraintEqualToAnchor:_chargingImageView.bottomAnchor constant:1],
        ]];
    }
    return self;
}

- (void)setChargePercent:(float)percent animated:(BOOL)animated {
    _chargePercent = percent;
    _percentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)lroundf(percent)];

    // Forward to _UIBatteryView
    SEL chargePercentSel = NSSelectorFromString(@"setChargePercent:");
    if ([self respondsToSelector:chargePercentSel]) {
        ((void (*)(id, SEL, NSInteger))[self methodForSelector:chargePercentSel])(self, chargePercentSel, (NSInteger)lroundf(percent));
    }
}

- (void)setChargePercent:(float)chargePercent {
    [self setChargePercent:chargePercent animated:NO];
}

- (void)setIsCharging:(BOOL)isCharging {
    _isCharging = isCharging;
    _chargingImageView.hidden = !isCharging;
    _percentLabel.hidden = isCharging;
    _ampLabel.hidden = !isCharging;

    SEL chargingSel = NSSelectorFromString(@"setChargingState:");
    if ([self respondsToSelector:chargingSel]) {
        ((void (*)(id, SEL, BOOL))[self methodForSelector:chargingSel])(self, chargingSel, isCharging);
    }
}

- (void)setBoltColor:(UIColor *)boltColor {
    _boltColor = boltColor;
    _chargingImageView.tintColor = boltColor;
    _ampLabel.textColor = boltColor;

    SEL boltColorSel = NSSelectorFromString(@"setBoltColor:");
    if ([self respondsToSelector:boltColorSel]) {
        ((void (*)(id, SEL, UIColor *))[self methodForSelector:boltColorSel])(self, boltColorSel, boltColor);
    }
}

- (void)updateBatteryAppearance {
    UIColor *activeColor = _batteryColor ?: [UIColor whiteColor];
    if (_isCharging) {
        activeColor = _chargingColor ?: [UIColor systemGreenColor];
    } else if (_isLowPowerMode) {
        activeColor = _lowPowerColor ?: [UIColor systemYellowColor];
    }

    _percentLabel.hidden = !_showsPercentLabel || _isCharging;
    _chargingImageView.hidden = !_isCharging || !_showsBoltWhenCharging;
    _chargingImageView.tintColor = _boltColor ?: activeColor;
    _ampLabel.textColor = activeColor;
    self.tintColor = activeColor;
    self.layer.cornerRadius = _cornerRadius;
}

- (void)startChargingAnimation {
    [self stopChargingAnimation];
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.35;
    pulse.duration = 0.8;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [_chargingImageView.layer addAnimation:pulse forKey:@"jadeChargingPulse"];
}

- (void)stopChargingAnimation {
    [_chargingImageView.layer removeAnimationForKey:@"jadeChargingPulse"];
}

@end
