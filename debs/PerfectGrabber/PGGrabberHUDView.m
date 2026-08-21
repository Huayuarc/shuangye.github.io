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
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
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
    _panelView.layer.cornerRadius = 18.0;
    _panelView.clipsToBounds = YES;
    [self addSubview:_panelView];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:
                 [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    [_panelView addSubview:_blurView];

    _artworkView = [UIImageView new];
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.layer.cornerRadius = 12.0;
    _artworkView.clipsToBounds = YES;
    _artworkView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _artworkView.image = [UIImage systemImageNamed:@"music.note"];
    _artworkView.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    [_panelView addSubview:_artworkView];

    _titleLabel = [self metadataLabelWithSize:16 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    _artistLabel = [self metadataLabelWithSize:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.62]];
    [_panelView addSubview:_titleLabel];
    [_panelView addSubview:_artistLabel];

    UIButton *previous = [self buttonWithSymbol:@"backward.end.fill" action:@selector(previousTrack)];
    _playButton = [self buttonWithSymbol:@"play.fill" action:@selector(togglePlayback)];
    UIButton *next = [self buttonWithSymbol:@"forward.end.fill" action:@selector(nextTrack)];
    _controlsView = [[UIStackView alloc] initWithArrangedSubviews:@[previous, _playButton, next]];
    _controlsView.axis = UILayoutConstraintAxisHorizontal;
    _controlsView.distribution = UIStackViewDistributionFillEqually;
    [_panelView addSubview:_controlsView];

    _valueLabel = [self metadataLabelWithSize:13 weight:UIFontWeightMedium color:UIColor.whiteColor];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    [_panelView addSubview:_valueLabel];
    return self;
}

- (UILabel *)metadataLabelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
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
    CGPoint p = [self convertPoint:point toView:self.panelView];
    return [self.panelView pointInside:p withEvent:event] ? [super hitTest:point withEvent:event] : nil;
}

- (void)previousTrack { PGSendMediaAction(PGMediaActionPrevious); [self refreshMediaSoon]; }
- (void)togglePlayback { PGSendMediaAction(PGMediaActionToggle); [self refreshMediaSoon]; }
- (void)nextTrack { PGSendMediaAction(PGMediaActionNext); [self refreshMediaSoon]; }
- (void)refreshMediaSoon { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self updateMedia]; }); }
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

- (void)updateMedia {
    __weak typeof(self) weakSelf = self;
    PGFetchNowPlaying(^(BOOL playing, NSString *title, NSString *artist, UIImage *artwork) {
        typeof(self) self = weakSelf;
        if (!self) return;
        [self.playButton setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill")]
                          forState:UIControlStateNormal];
        self.titleLabel.text = title.length ? title : @"未在播放";
        self.artistLabel.text = artist.length ? artist : @"轻点播放继续音乐";
        if (artwork) {
            self.artworkView.image = artwork;
            self.artworkView.tintColor = nil;
        } else {
            self.artworkView.image = [UIImage systemImageNamed:@"music.note"];
            self.artworkView.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
        }
    });
}

- (void)updateContents {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.dateFormat = preferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    NSString *charge = preferences.chargingIcon && [self isCharging] ? @"⚡" : @"";
    double temperature = PGCurrentDeviceTemperature();
    NSString *temp = isfinite(temperature) ? [NSString stringWithFormat:@"%.0f°C", temperature] : @"--°C";
    self.valueLabel.text = [NSString stringWithFormat:@"%@  ·  %@  ·  %@%ld%%",
                            [formatter stringFromDate:NSDate.date], temp, charge,
                            (long)[self currentBatteryPercentage]];
    UIColor *tint = preferences.textColor;
    self.valueLabel.textColor = tint;
    for (UIView *view in self.controlsView.arrangedSubviews)
        if ([view isKindOfClass:UIButton.class]) ((UIButton *)view).tintColor = tint;
    self.blurView.hidden = preferences.swipeUpBackgroundColorEnabled;
    self.panelView.backgroundColor = preferences.swipeUpBackgroundColorEnabled
        ? preferences.swipeUpBackgroundColor : UIColor.clearColor;
    [self updateMedia];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.panelView.bounds = CGRectMake(0, 0, 340, 150);
    self.panelView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIWindow *window = self.window;
    if (window) {
        id<UICoordinateSpace> space = window.screen.coordinateSpace;
        CGPoint origin = [window convertPoint:CGPointZero toCoordinateSpace:space];
        CGPoint axis = [window convertPoint:CGPointMake(1, 0) toCoordinateSpace:space];
        self.panelView.transform = CGAffineTransformMakeRotation(-atan2(axis.y-origin.y, axis.x-origin.x));
    }
    self.blurView.frame = self.panelView.bounds;
    self.artworkView.frame = CGRectMake(14, 14, 76, 76);
    self.titleLabel.frame = CGRectMake(104, 13, 220, 24);
    self.artistLabel.frame = CGRectMake(104, 38, 220, 20);
    self.controlsView.frame = CGRectMake(100, 59, 228, 38);
    self.valueLabel.frame = CGRectMake(14, 106, 312, 32);
}

- (void)startUpdating {
    [self stopUpdating];
    [self updateContents];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateContents)
                                                userInfo:nil repeats:YES];
}
- (void)stopUpdating { [self.timer invalidate]; self.timer = nil; }
@end
