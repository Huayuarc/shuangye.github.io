// JadeBatteryPill.m
// Pill-shaped battery indicator for the Jade control center

#import "JadeBatteryPill.h"
#import <UIKit/UIKit.h>

// Private class declarations
@interface _UIBackdropView : UIView
- (instancetype)initWithFrame:(CGRect)frame autosizesToFitSuperview:(BOOL)autosizes;
- (instancetype)initWithFrame:(CGRect)frame privateStyle:(long long)style;
- (instancetype)initWithPrivateStyle:(long long)style;
- (void)setAutoScale:(BOOL)autoScale;
- (void)setBlurRadius:(double)radius;
- (void)transitionToStyle:(long long)style;
@end

@interface _PMLowPowerMode : NSObject
+ (id)sharedInstance;
- (void)setPowerMode:(BOOL)powerMode fromSource:(id)source;
@end

@interface JadeBatteryPill ()

@property (nonatomic, strong) _UIBackdropView *blurView;

@end

@implementation JadeBatteryPill

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _currentPercent = 100.0f;
        _isCharging = NO;
        _isLowPowerMode = NO;

        // Read preferences
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        NSString *bgColorHex = [prefs stringForKey:@"batteryIndicatorBackgroundColor"];
        NSString *textColorHex = [prefs stringForKey:@"batteryIndicatorTextColor"];

        _pillBackgroundColor = [self _colorFromHexString:bgColorHex] ?: [UIColor colorWithWhite:0.15 alpha:1.0];
        _pillColor = [self _colorFromHexString:textColorHex] ?: [UIColor whiteColor];

        [self setupViews];
        [self setupConstraints];

        // Register for battery notifications
        [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(batteryLevelDidChange:)
                                                     name:UIDeviceBatteryLevelDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(batteryStateDidChange:)
                                                     name:UIDeviceBatteryStateDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(lowPowerStatusDidChange:)
                                                     name:NSProcessInfoPowerStateDidChangeNotification
                                                   object:nil];

        // Initial update
        [self _updateFromDevice];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
    self.clipsToBounds = YES;

    // Blur view background
    _blurView = [[_UIBackdropView alloc] initWithFrame:self.bounds privateStyle:2020];
    if (_blurView) {
        _blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_blurView];
    }

    // Pill container for layout
    _pillContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _pillContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _pillContainer.backgroundColor = [UIColor clearColor];
    [self addSubview:_pillContainer];

    // Battery view
    CGFloat batteryWidth = 22.0;
    CGFloat batteryHeight = 12.0;
    _batteryView = [[AmpereSupport_UIBatteryView alloc] initWithFrame:CGRectMake(0, 0, batteryWidth, batteryHeight)];
    _batteryView.translatesAutoresizingMaskIntoConstraints = NO;
    _batteryView.batteryColor = _pillColor;
    _batteryView.chargingColor = [UIColor systemGreenColor];
    _batteryView.lowPowerColor = [UIColor systemYellowColor];
    _batteryView.boltColor = _pillColor;
    _batteryView.showsPercentLabel = NO;
    _batteryView.batteryWidth = batteryWidth;
    _batteryView.batteryHeight = batteryHeight;
    _batteryView.cornerRadius = 2.0;
    [_batteryView setChargePercent:100 animated:NO];
    [_batteryView updateBatteryAppearance];
    [_pillContainer addSubview:_batteryView];

    // Percent label
    _percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _percentLabel.textColor = _pillColor;
    _percentLabel.textAlignment = NSTextAlignmentLeft;
    _percentLabel.text = @"100%";
    [_pillContainer addSubview:_percentLabel];

    // Amperage label
    _amperageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _amperageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _amperageLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _amperageLabel.textColor = [_pillColor colorWithAlphaComponent:0.7];
    _amperageLabel.textAlignment = NSTextAlignmentLeft;
    _amperageLabel.hidden = YES;
    [_pillContainer addSubview:_amperageLabel];

    // Tap gesture for low power mode toggle
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
    [self addGestureRecognizer:tap];
    self.userInteractionEnabled = YES;
}

- (void)setupConstraints {
    UIView *container = _pillContainer;
    UIView *blur = _blurView;

    [NSLayoutConstraint activateConstraints:@[
        // Blur fills self
        [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // Container fills self with padding
        [container.topAnchor constraintEqualToAnchor:self.topAnchor],
        [container.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [container.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [container.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // Battery view left-aligned in container
        [_batteryView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [_batteryView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_batteryView.widthAnchor constraintEqualToConstant:_batteryView.batteryWidth],
        [_batteryView.heightAnchor constraintEqualToConstant:_batteryView.batteryHeight],

        // Percent label next to battery
        [_percentLabel.leadingAnchor constraintEqualToAnchor:_batteryView.trailingAnchor constant:6],
        [_percentLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],

        // Amperage label trailing
        [_amperageLabel.leadingAnchor constraintEqualToAnchor:_percentLabel.trailingAnchor constant:4],
        [_amperageLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [_amperageLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],
    ]];
}

#pragma mark - Battery Updates

- (void)_updateFromDevice {
    UIDevice *device = [UIDevice currentDevice];
    float level = device.batteryLevel;
    if (level < 0) level = 1.0f;
    [self updateBatteryLevel:level];

    BOOL charging = (device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull);
    BOOL lowPower = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
    [self updateBatteryState:charging lowPower:lowPower];
}

- (void)updateBatteryLevel:(float)level {
    _currentPercent = level;
    int percentInt = (int)(level * 100);
    _percentLabel.text = [NSString stringWithFormat:@"%d%%", percentInt];
    [_batteryView setChargePercent:percentInt animated:YES];

    // Update pill color: yellow for low battery (<20%), green when charging
    if (_isCharging) {
        [self setPillColor:[UIColor systemGreenColor] animated:YES];
    } else if (_isLowPowerMode) {
        [self setPillColor:[UIColor systemYellowColor] animated:YES];
    } else {
        [self setPillColor:_pillColor animated:YES];
    }
}

- (void)updateBatteryState:(BOOL)charging lowPower:(BOOL)lowPower {
    _isCharging = charging;
    _isLowPowerMode = lowPower;

    _batteryView.isCharging = charging;
    _batteryView.isLowPowerMode = lowPower;
    [_batteryView updateBatteryAppearance];

    if (charging) {
        [self setPillColor:[UIColor systemGreenColor] animated:YES];
        [self startPulseAnimation];
    } else if (lowPower) {
        [self setPillColor:[UIColor systemYellowColor] animated:YES];
        [self stopPulseAnimation];
    } else {
        [self setPillColor:_pillColor animated:YES];
        [self stopPulseAnimation];
    }
}

- (void)updateAmperage:(NSString *)amperage {
    _amperageLabel.text = amperage;
    _amperageLabel.hidden = (amperage == nil || amperage.length == 0);
}

#pragma mark - Notification Handlers

- (void)batteryLevelDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _updateFromDevice];
    });
}

- (void)batteryStateDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _updateFromDevice];
    });
}

- (void)lowPowerStatusDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _updateFromDevice];
    });
}

- (void)tapped {
    _isLowPowerMode = !_isLowPowerMode;

    Class lowPowerModeClass = NSClassFromString(@"_PMLowPowerMode");
    if (lowPowerModeClass) {
        id instance = [lowPowerModeClass sharedInstance];
        SEL selector = NSSelectorFromString(@"setPowerMode:fromSource:");
        if ([instance respondsToSelector:selector]) {
            ((void (*)(id, SEL, BOOL, id))[instance methodForSelector:selector])(instance, selector, _isLowPowerMode, @"Jade");
        }
    } else {
        // Fallback: use NSProcessInfo
        if (_isLowPowerMode) {
            // Can't programmatically enable low power mode without private API
            NSLog(@"[Jade] Low power mode toggled: %d", _isLowPowerMode);
        }
    }

    [self updateBatteryState:_isCharging lowPower:_isLowPowerMode];
}

#pragma mark - Appearance

- (void)setPillColor:(UIColor *)color animated:(BOOL)animated {
    UIColor *targetColor = color ?: _pillColor;
    if (animated) {
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.percentLabel.textColor = targetColor;
            self.batteryView.batteryColor = targetColor;
            self.batteryView.boltColor = targetColor;
            [self.batteryView updateBatteryAppearance];
        } completion:nil];
    } else {
        self.percentLabel.textColor = targetColor;
        self.batteryView.batteryColor = targetColor;
        self.batteryView.boltColor = targetColor;
        [self.batteryView updateBatteryAppearance];
    }
}

- (void)startPulseAnimation {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @(1.0);
    pulse.toValue = @(0.5);
    pulse.duration = 1.0;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:pulse forKey:@"pulseAnimation"];
}

- (void)stopPulseAnimation {
    [self.layer removeAnimationForKey:@"pulseAnimation"];
    self.layer.opacity = 1.0;
}

#pragma mark - Helper

- (UIColor *)_colorFromHexString:(NSString *)hexString {
    if (!hexString || hexString.length == 0) return nil;
    NSString *hex = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length < 6) return nil;

    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    [scanner scanHexInt:&rgbValue];

    CGFloat red = ((rgbValue & 0xFF0000) >> 16) / 255.0;
    CGFloat green = ((rgbValue & 0x00FF00) >> 8) / 255.0;
    CGFloat blue = (rgbValue & 0x0000FF) / 255.0;
    CGFloat alpha = 1.0;
    if (hex.length >= 8) {
        alpha = ((rgbValue & 0xFF000000) >> 24) / 255.0;
    }

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
}

#pragma mark - Cleanup

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSProcessInfoPowerStateDidChangeNotification object:nil];
}

@end
