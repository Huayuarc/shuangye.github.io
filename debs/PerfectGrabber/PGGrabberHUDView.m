#import "PGGrabberHUDView.h"
#import "PerfectGrabberPreferences.h"
#import "PGSystemStatus.h"
#import <math.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

@interface PGGrabberHUDView ()
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIStackView *controlsView;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation PGGrabberHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    _panelView = [UIView new];
    _panelView.layer.cornerRadius = 16.0;
    _panelView.clipsToBounds = YES;
    [self addSubview:_panelView];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:
                 [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    [_panelView addSubview:_blurView];

    UIButton *previous = [self buttonWithSymbol:@"backward.end.fill" action:@selector(previousTrack)];
    _playButton = [self buttonWithSymbol:@"play.fill" action:@selector(togglePlayback)];
    UIButton *next = [self buttonWithSymbol:@"forward.end.fill" action:@selector(nextTrack)];
    _playButton.transform = CGAffineTransformMakeScale(1.28, 1.28);
    _controlsView = [[UIStackView alloc] initWithArrangedSubviews:@[previous, _playButton, next]];
    _controlsView.axis = UILayoutConstraintAxisHorizontal;
    _controlsView.distribution = UIStackViewDistributionFillEqually;
    _controlsView.alignment = UIStackViewAlignmentFill;
    [_panelView addSubview:_controlsView];

    _valueLabel = [UILabel new];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.textColor = UIColor.whiteColor;
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _valueLabel.adjustsFontSizeToFitWidth = YES;
    _valueLabel.minimumScaleFactor = 0.68;
    [_panelView addSubview:_valueLabel];
    return self;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint panelPoint = [self convertPoint:point toView:self.panelView];
    if (![self.panelView pointInside:panelPoint withEvent:event]) return nil;
    return [super hitTest:point withEvent:event];
}

- (void)previousTrack { PGSendMediaAction(PGMediaActionPrevious); }
- (void)togglePlayback { PGSendMediaAction(PGMediaActionToggle); }
- (void)nextTrack { PGSendMediaAction(PGMediaActionNext); }

- (void)dealloc { [_timer invalidate]; }

- (NSInteger)currentBatteryPercentage {
    Class cls = NSClassFromString(@"SBUIController");
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [cls sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)])
            return MAX(0, MIN(100, [controller batteryCapacityAsPercentage]));
    }
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    CGFloat level = UIDevice.currentDevice.batteryLevel;
    return level < 0 ? 0 : (NSInteger)lround(level * 100.0);
}

- (BOOL)isCharging {
    Class cls = NSClassFromString(@"SBUIController");
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [cls sharedInstance];
        if ([controller respondsToSelector:@selector(isOnAC)]) return [controller isOnAC];
    }
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (void)refreshAppearance {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    self.valueLabel.textColor = preferences.textColor;
    for (UIView *view in self.controlsView.arrangedSubviews) {
        if ([view isKindOfClass:UIButton.class]) ((UIButton *)view).tintColor = preferences.textColor;
    }
    self.blurView.hidden = preferences.swipeUpBackgroundColorEnabled;
    self.panelView.backgroundColor = preferences.swipeUpBackgroundColorEnabled
        ? preferences.swipeUpBackgroundColor : UIColor.clearColor;
}

- (void)updateContents {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.dateFormat = preferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    NSString *time = [formatter stringFromDate:NSDate.date];
    NSString *charge = preferences.chargingIcon && [self isCharging] ? @"⚡" : @"";
    double temperature = PGCurrentDeviceTemperature();
    NSString *temperatureText = isfinite(temperature)
        ? [NSString stringWithFormat:@"%.0f°C", temperature] : @"--°C";
    self.valueLabel.text = [NSString stringWithFormat:@"%@  /  %@  /  %@%ld%%", time,
                            temperatureText, charge, (long)[self currentBatteryPercentage]];
    [self refreshAppearance];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.panelView.bounds = CGRectMake(0, 0, 260.0, 116.0);
    self.panelView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIWindow *window = self.window;
    if (window) {
        id<UICoordinateSpace> space = window.screen.coordinateSpace;
        CGPoint origin = [window convertPoint:CGPointZero toCoordinateSpace:space];
        CGPoint axis = [window convertPoint:CGPointMake(1, 0) toCoordinateSpace:space];
        self.panelView.transform = CGAffineTransformMakeRotation(-atan2(axis.y-origin.y, axis.x-origin.x));
    }
    self.blurView.frame = self.panelView.bounds;
    self.controlsView.frame = CGRectMake(12, 6, 236, 64);
    self.valueLabel.frame = CGRectMake(12, 70, 236, 40);
}

- (void)startUpdating {
    [self stopUpdating];
    [self updateContents];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                selector:@selector(updateContents)
                                                userInfo:nil repeats:YES];
}

- (void)stopUpdating { [self.timer invalidate]; self.timer = nil; }
@end
