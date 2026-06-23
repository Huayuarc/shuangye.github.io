// JadeTimePill.m
// Pill-shaped time display for the Jade control center

#import "JadeTimePill.h"
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

@interface JadeTimePill ()

@property (nonatomic, strong) _UIBackdropView *blurView;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;

@end

@implementation JadeTimePill

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _showsDate = YES;
        _showsSeconds = NO;
        _is24HourFormat = NO;

        // Read preferences
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        NSString *bgColorHex = [prefs stringForKey:@"timeIndicatorBackgroundColor"];
        NSString *textColorHex = [prefs stringForKey:@"timeIndicatorTextColor"];
        NSString *timeFormat = [prefs stringForKey:@"TIME_FORMAT"];

        _showsDate = [prefs boolForKey:@"showsDate"];
        _showsSeconds = [prefs boolForKey:@"showsSeconds"];
        _is24HourFormat = [prefs boolForKey:@"is24HourFormat"];

        _pillBackgroundColor = [self _colorFromHexString:bgColorHex] ?: [UIColor colorWithWhite:0.15 alpha:1.0];
        _textColor = [self _colorFromHexString:textColorHex] ?: [UIColor whiteColor];

        // Configure date formatter
        _dateFormatter = [[NSDateFormatter alloc] init];
        NSString *localeIdentifier = [prefs stringForKey:@"LOCALE_IDENTIFIER"];
        if (localeIdentifier) {
            _dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:localeIdentifier];
        } else {
            _dateFormatter.locale = [NSLocale currentLocale];
        }

        if (timeFormat && timeFormat.length > 0) {
            // Use the localized time format from preferences
            [_dateFormatter setLocalizedDateFormatFromTemplate:timeFormat];
        } else {
            // Default format based on 12/24 hour preference
            if (_is24HourFormat) {
                if (_showsSeconds) {
                    [_dateFormatter setDateFormat:@"HH:mm:ss"];
                } else {
                    [_dateFormatter setDateFormat:@"HH:mm"];
                }
            } else {
                if (_showsSeconds) {
                    [_dateFormatter setDateFormat:@"h:mm:ss a"];
                } else {
                    [_dateFormatter setDateFormat:@"h:mm a"];
                }
            }
        }

        [self setupViews];
        [self setupConstraints];
        [self updateTime];
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
        _blurView.backgroundColor = _pillBackgroundColor;
        [self addSubview:_blurView];
    }

    // Pill container
    _pillContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _pillContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _pillContainer.backgroundColor = [UIColor clearColor];
    [self addSubview:_pillContainer];

    // Time label - main time display
    _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timeLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _timeLabel.textColor = _textColor;
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.text = @"--:--";
    [_pillContainer addSubview:_timeLabel];

    // Date label
    _dateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _dateLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _dateLabel.textColor = [_textColor colorWithAlphaComponent:0.7];
    _dateLabel.textAlignment = NSTextAlignmentCenter;
    _dateLabel.text = @"";
    _dateLabel.hidden = !_showsDate;
    [_pillContainer addSubview:_dateLabel];
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

        // Container fills self
        [container.topAnchor constraintEqualToAnchor:self.topAnchor],
        [container.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // Time label centered in container
        [_timeLabel.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [_timeLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:(_showsDate ? -6 : 0)],

        // Date label below time
        [_dateLabel.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [_dateLabel.topAnchor constraintEqualToAnchor:_timeLabel.bottomAnchor constant:1],
    ]];
}

#pragma mark - Time Updates

- (void)updateTime {
    _timeLabel.text = [self formattedTimeString];
    if (_showsDate) {
        _dateLabel.text = [self formattedDateString];
        _dateLabel.hidden = NO;
    } else {
        _dateLabel.hidden = YES;
    }
}

- (NSString *)formattedTimeString {
    return [_dateFormatter stringFromDate:[NSDate date]];
}

- (NSString *)formattedDateString {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.locale = _dateFormatter.locale;
    dateFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEE, MMM d" options:0 locale:dateFormatter.locale];
    return [dateFormatter stringFromDate:[NSDate date]];
}

#pragma mark - Timer Management

- (void)startUpdating {
    if (_showsSeconds) {
        _updateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(updateTime)
                                                      userInfo:nil
                                                       repeats:YES];
    } else {
        // Update every 30 seconds if not showing seconds
        _updateTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        target:self
                                                      selector:@selector(updateTime)
                                                      userInfo:nil
                                                       repeats:YES];
    }
    [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUpdating {
    if (_updateTimer) {
        [_updateTimer invalidate];
        _updateTimer = nil;
    }
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        [self startUpdating];
    } else {
        [self stopUpdating];
    }
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    [super willMoveToSuperview:newSuperview];
    if (!newSuperview) {
        [self stopUpdating];
    }
}

#pragma mark - Appearance

- (void)setTextColor:(UIColor *)color animated:(BOOL)animated {
    UIColor *targetColor = color ?: _textColor;
    if (animated) {
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            _timeLabel.textColor = targetColor;
            _dateLabel.textColor = [targetColor colorWithAlphaComponent:0.7];
        } completion:nil];
    } else {
        _timeLabel.textColor = targetColor;
        _dateLabel.textColor = [targetColor colorWithAlphaComponent:0.7];
    }
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
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

#pragma mark - Cleanup

- (void)dealloc {
    [self stopUpdating];
}

@end
