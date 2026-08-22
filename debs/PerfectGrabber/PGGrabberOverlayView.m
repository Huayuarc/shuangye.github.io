#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import <math.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

@interface PGGrabberOverlayView ()
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation PGGrabberOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        self.layer.cornerRadius = 6.0;

        _timeLabel = [UILabel new];
        _batteryLabel = [UILabel new];
        for (UILabel *label in @[_timeLabel, _batteryLabel]) {
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.65;
            label.numberOfLines = 1;
            [self addSubview:label];
        }

    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (UIFont *)configuredFont {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.fontStyle == 1) {
        return [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightBold];
    }
    UIFont *font = [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightRegular];
    if (preferences.fontStyle == 2) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:preferences.fontSize];
    }
    return font;
}

- (NSInteger)currentBatteryPercentage {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            return MAX(0, MIN(100, [controller batteryCapacityAsPercentage]));
        }
    }

    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    CGFloat level = UIDevice.currentDevice.batteryLevel;
    return level < 0 ? 0 : (NSInteger)lround(level * 100.0);
}

- (BOOL)isCharging {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(isOnAC)]) return [controller isOnAC];
    }
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (void)updateContents {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale currentLocale];
    formatter.dateFormat = preferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    NSString *time = [formatter stringFromDate:NSDate.date];

    NSInteger battery = [self currentBatteryPercentage];
    NSString *chargingPrefix = preferences.chargingIcon && [self isCharging] ? @"\u26A1 " : @"";
    NSString *batteryText = [NSString stringWithFormat:@"%@%ld%%", chargingPrefix, (long)battery];

    if (preferences.twoLine) {
        self.timeLabel.text = time;
        self.batteryLabel.text = batteryText;
        self.batteryLabel.hidden = NO;
    } else {
        self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@", time, batteryText];
        self.batteryLabel.text = nil;
        self.batteryLabel.hidden = YES;
    }
    [self applyAppearance];
    [self setNeedsLayout];
}

- (void)applyAppearance {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    UIFont *font = [self configuredFont];
    for (UILabel *label in @[self.timeLabel, self.batteryLabel]) {
        label.font = font;
        label.textColor = preferences.textColor;
        label.numberOfLines = 1;
    }
    self.backgroundColor = preferences.backgroundColorEnabled ? preferences.backgroundColor : UIColor.clearColor;
    self.layer.maskedCorners = preferences.backgroundColorEnabled
        ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)
        : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
           kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
}

- (void)refreshAppearance {
    [self applyAppearance];
    [self setNeedsLayout];
    [self updateContents];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    CGRect contentBounds = CGRectInset(self.bounds, 8.0, 0.0);

    if (preferences.twoLine) {
        CGFloat rowHeight = CGRectGetHeight(contentBounds) / 2.0;
        self.timeLabel.frame = CGRectMake(CGRectGetMinX(contentBounds), CGRectGetMinY(contentBounds),
                                          CGRectGetWidth(contentBounds), rowHeight);
        self.batteryLabel.frame = CGRectMake(CGRectGetMinX(contentBounds), CGRectGetMinY(contentBounds) + rowHeight,
                                             CGRectGetWidth(contentBounds), rowHeight);
        NSTextAlignment alignment = preferences.grabberStyle == 1 ? NSTextAlignmentLeft :
                                    (preferences.grabberStyle == 2 ? NSTextAlignmentRight : NSTextAlignmentCenter);
        self.timeLabel.textAlignment = alignment;
        self.batteryLabel.textAlignment = alignment;
    } else {
        self.timeLabel.frame = contentBounds;
        self.batteryLabel.frame = CGRectZero;
        self.timeLabel.textAlignment = preferences.grabberStyle == 1 ? NSTextAlignmentLeft :
                                       (preferences.grabberStyle == 2 ? NSTextAlignmentRight : NSTextAlignmentCenter);
    }
}

- (void)startUpdating {
    [self stopUpdating];
    [self refreshAppearance];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(updateContents)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)stopUpdating {
    [self.timer invalidate];
    self.timer = nil;
}

@end
