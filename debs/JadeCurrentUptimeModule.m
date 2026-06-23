// JadeCurrentUptimeModule.m
// Module displaying current system uptime information
// Uses sysctl to retrieve kernel boot time and calculates elapsed time

#import "JadeCurrentUptimeModule.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/types.h>

@interface JadeCurrentUptimeModule ()

// Internal ivars from binary analysis
@property (nonatomic, assign) BOOL shouldUpdate;

@end

@implementation JadeCurrentUptimeModule

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _shouldUpdate = YES;
        _textColor = [UIColor whiteColor];
        _valueTextColor = [UIColor systemGreenColor];
        _isShowingDetailed = NO;

        [self setupViews];
        [self setupConstraints];
        [self refreshUptime];
    }
    return self;
}

- (instancetype)init {
    CGRect defaultFrame = CGRectMake(0, 0, 300, 60);
    return [self initWithFrame:defaultFrame];
}

#pragma mark - Setup Views

- (void)setupViews {
    // Uptime title label
    _uptimeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _uptimeLabel.textAlignment = NSTextAlignmentCenter;
    _uptimeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _uptimeLabel.textColor = _textColor;
    _uptimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_uptimeLabel];

    // Uptime value label (shows the time)
    _uptimeValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _uptimeValueLabel.textAlignment = NSTextAlignmentCenter;
    _uptimeValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightSemibold];
    _uptimeValueLabel.textColor = _valueTextColor;
    _uptimeValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_uptimeValueLabel];

    // Since label (boot date/time)
    _sinceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sinceLabel.textAlignment = NSTextAlignmentCenter;
    _sinceLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _sinceLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _sinceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sinceLabel.hidden = YES;
    [self addSubview:_sinceLabel];

    // Tap gesture to toggle detailed view
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleDetailedView)];
    [self addGestureRecognizer:tapGesture];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Uptime label (title)
        [_uptimeLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_uptimeLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_uptimeLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],

        // Uptime value label
        [_uptimeValueLabel.topAnchor constraintEqualToAnchor:_uptimeLabel.bottomAnchor constant:4],
        [_uptimeValueLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_uptimeValueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],

        // Since label
        [_sinceLabel.topAnchor constraintEqualToAnchor:_uptimeValueLabel.bottomAnchor constant:4],
        [_sinceLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_sinceLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_sinceLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-8],
    ]];
}

#pragma mark - Uptime Calculation

- (void)refreshUptime {
    [self updateUptime];

    // Read preferences for colors
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];

    NSString *textColorHex = [prefs stringForKey:@"uptimeTextColor"];
    if (textColorHex) {
        _textColor = [self colorFromHexString:textColorHex];
    } else {
        _textColor = [UIColor whiteColor];
    }
    _uptimeLabel.textColor = _textColor;

    NSString *timeColorHex = [prefs stringForKey:@"uptimeTimeColor"];
    if (timeColorHex) {
        _valueTextColor = [self colorFromHexString:timeColorHex];
    } else {
        _valueTextColor = [UIColor systemGreenColor];
    }
    _uptimeValueLabel.textColor = _valueTextColor;

    // Localization support
    NSString *uptimeLocalization = [prefs stringForKey:@"UPTIME"];
    if (!uptimeLocalization) {
        uptimeLocalization = @"UPTIME";
    }

    NSString *timeFormatLocalization = [prefs stringForKey:@"TIME_FORMAT"];
    if (!timeFormatLocalization) {
        timeFormatLocalization = @"HH:mm:ss";
    }

    _uptimeLabel.text = uptimeLocalization;
}

- (void)updateUptime {
    struct timeval bootTime;
    size_t size = sizeof(bootTime);

    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &bootTime, &size, NULL, 0) != -1 && bootTime.tv_sec != 0) {
        // Calculate uptime
        struct timeval now;
        gettimeofday(&now, NULL);

        time_t uptimeSeconds = now.tv_sec - bootTime.tv_sec;

        int days = (int)(uptimeSeconds / 86400);
        int hours = (int)((uptimeSeconds % 86400) / 3600);
        int minutes = (int)((uptimeSeconds % 3600) / 60);
        int seconds = (int)(uptimeSeconds % 60);

        // Format uptime string
        NSString *uptimeString;
        if (days > 0) {
            uptimeString = [NSString stringWithFormat:@"%dd %02d:%02d:%02d", days, hours, minutes, seconds];
        } else if (hours > 0) {
            uptimeString = [NSString stringWithFormat:@"%dh %02dm %02ds", hours, minutes, seconds];
        } else if (minutes > 0) {
            uptimeString = [NSString stringWithFormat:@"%dm %02ds", minutes, seconds];
        } else {
            uptimeString = [NSString stringWithFormat:@"%ds", seconds];
        }

        _uptimeValueLabel.text = uptimeString;

        // Boot date
        NSDate *bootDate = [NSDate dateWithTimeIntervalSince1970:bootTime.tv_sec];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM/dd/yy HH:mm";
        _sinceLabel.text = [NSString stringWithFormat:@"Since %@", [formatter stringFromDate:bootDate]];
    } else {
        _uptimeValueLabel.text = @"--:--:--";
    }
}

#pragma mark - Public Methods

- (void)startUpdating {
    _shouldUpdate = YES;

    if (_updateTimer) {
        [_updateTimer invalidate];
    }

    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                    target:self
                                                  selector:@selector(updateUptime)
                                                  userInfo:nil
                                                   repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUpdating {
    _shouldUpdate = NO;

    if (_updateTimer) {
        [_updateTimer invalidate];
        _updateTimer = nil;
    }
}

- (void)toggleDetailedView {
    _isShowingDetailed = !_isShowingDetailed;

    [UIView animateWithDuration:0.3 animations:^{
        self->_sinceLabel.hidden = !self->_isShowingDetailed;

        if (self->_isShowingDetailed) {
            self->_uptimeValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightSemibold];
        } else {
            self->_uptimeValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightSemibold];
        }

        [self layoutIfNeeded];
    }];
}

- (NSString *)formattedUptime {
    struct timeval bootTime;
    size_t size = sizeof(bootTime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};

    if (sysctl(mib, 2, &bootTime, &size, NULL, 0) != -1 && bootTime.tv_sec != 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        time_t uptimeSeconds = now.tv_sec - bootTime.tv_sec;

        int days = (int)(uptimeSeconds / 86400);
        int hours = (int)((uptimeSeconds % 86400) / 3600);
        int minutes = (int)((uptimeSeconds % 3600) / 60);
        int seconds = (int)(uptimeSeconds % 60);

        if (days > 0) {
            return [NSString stringWithFormat:@"%d days, %02d:%02d:%02d", days, hours, minutes, seconds];
        } else {
            return [NSString stringWithFormat:@"%02d:%02d:%02d", hours, minutes, seconds];
        }
    }

    return @"--:--:--";
}

- (NSString *)formattedBootDate {
    struct timeval bootTime;
    size_t size = sizeof(bootTime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};

    if (sysctl(mib, 2, &bootTime, &size, NULL, 0) != -1 && bootTime.tv_sec != 0) {
        NSDate *bootDate = [NSDate dateWithTimeIntervalSince1970:bootTime.tv_sec];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        return [formatter stringFromDate:bootDate];
    }

    return @"Unknown";
}

- (NSString *)formattedDetailedUptime {
    struct timeval bootTime;
    size_t size = sizeof(bootTime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};

    if (sysctl(mib, 2, &bootTime, &size, NULL, 0) != -1 && bootTime.tv_sec != 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        time_t uptimeSeconds = now.tv_sec - bootTime.tv_sec;

        int days = (int)(uptimeSeconds / 86400);
        int hours = (int)((uptimeSeconds % 86400) / 3600);
        int minutes = (int)((uptimeSeconds % 3600) / 60);
        int seconds = (int)(uptimeSeconds % 60);

        return [NSString stringWithFormat:@"%d days %d hours %d minutes %d seconds", days, hours, minutes, seconds];
    }

    return @"--";
}

#pragma mark - Helper Methods

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *cleaned = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([cleaned hasPrefix:@"#"]) {
        cleaned = [cleaned substringFromIndex:1];
    }
    if ([cleaned length] < 6) {
        return nil;
    }

    unsigned int rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:cleaned];
    [scanner scanHexInt:&rgbValue];

    CGFloat alpha = 1.0f;
    if ([cleaned length] >= 8) {
        alpha = ((rgbValue >> 24) & 0xFF) / 255.0f;
    }

    return [UIColor colorWithRed:((rgbValue >> 16) & 0xFF) / 255.0f
                           green:((rgbValue >> 8) & 0xFF) / 255.0f
                            blue:(rgbValue & 0xFF) / 255.0f
                           alpha:alpha];
}

#pragma mark - Dealloc

- (void)dealloc {
    _shouldUpdate = NO;
    if (_updateTimer) {
        [_updateTimer invalidate];
        _updateTimer = nil;
    }
}

@end
