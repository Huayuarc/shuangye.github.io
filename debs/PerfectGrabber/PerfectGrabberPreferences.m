#import "PerfectGrabberPreferences.h"

NSString *const PGPreferencesDomain = @"com.netskao.perfectgrabber";
NSString *const PGPreferencesChangedNotification = @"com.netskao.perfectgrabber.settingschanged";

@interface PerfectGrabberPreferences ()
@property (nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property (nonatomic, readwrite) BOOL vibrationFeedback;
@property (nonatomic, readwrite) BOOL showOnSwipeUp;
@property (nonatomic, readwrite) NSTimeInterval autoCloseDelay;
@property (nonatomic, readwrite) BOOL disable24Hour;
@property (nonatomic, readwrite) BOOL chargingIcon;
@property (nonatomic, readwrite) BOOL twoLine;
@property (nonatomic, readwrite) NSInteger grabberStyle;
@property (nonatomic, readwrite) CGFloat fontSize;
@property (nonatomic, readwrite) NSInteger fontStyle;
@property (nonatomic, readwrite) CGFloat statusFontSize;
@property (nonatomic, readwrite) NSInteger statusPosition;
@property (nonatomic, readwrite) BOOL backgroundColorEnabled;
@property (nonatomic, readwrite) BOOL swipeUpBackgroundColorEnabled;
@property (nonatomic, readwrite) UIColor *textColor;
@property (nonatomic, readwrite) UIColor *backgroundColor;
@property (nonatomic, readwrite) UIColor *swipeUpBackgroundColor;
@end

@implementation PerfectGrabberPreferences

+ (instancetype)sharedPreferences {
    static PerfectGrabberPreferences *preferences;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        preferences = [[self alloc] init];
        [preferences reload];
    });
    return preferences;
}

- (id)valueForKey:(NSString *)key fallback:(id)fallback {
    CFPreferencesSynchronize((__bridge CFStringRef)PGPreferencesDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      (__bridge CFStringRef)PGPreferencesDomain,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value) ?: fallback;
}

+ (UIColor *)colorFromHexString:(NSString *)value fallback:(UIColor *)fallback {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *hex = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return fallback;

    unsigned long long rgba = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexLongLong:&rgba] || !scanner.isAtEnd) return fallback;
    CGFloat alpha = hex.length == 8 ? ((rgba >> 24) & 0xff) / 255.0 : 1.0;
    CGFloat red = ((rgba >> 16) & 0xff) / 255.0;
    CGFloat green = ((rgba >> 8) & 0xff) / 255.0;
    CGFloat blue = (rgba & 0xff) / 255.0;
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

- (void)reload {
    self.enabled = [[self valueForKey:@"EnabledPerfectGrabber" fallback:@NO] boolValue];
    self.vibrationFeedback = [[self valueForKey:@"VibrationFeedback" fallback:@YES] boolValue];
    self.showOnSwipeUp = [[self valueForKey:@"ShowOnSwipeUp" fallback:@YES] boolValue];
    double storedDelay = [[self valueForKey:@"AutoCloseDelay" fallback:@6.0] doubleValue];
    self.autoCloseDelay = (storedDelay >= 1.0 && storedDelay <= 6.0) ? storedDelay : 6.0;
    self.disable24Hour = [[self valueForKey:@"Disable24H" fallback:@NO] boolValue];
    self.chargingIcon = [[self valueForKey:@"ChargingIcon" fallback:@YES] boolValue];
    self.twoLine = NO;
    self.grabberStyle = MAX(0, MIN(1, [[self valueForKey:@"GrabberStyle" fallback:@0] integerValue]));
    self.fontSize = 13.0;
    self.fontStyle = MAX(0, MIN(2, [[self valueForKey:@"FontStyle" fallback:@0] integerValue]));
    self.statusFontSize = MAX(11.0, MIN(20.0, [[self valueForKey:@"StatusFontSize" fallback:@15.0] doubleValue]));
    self.statusPosition = MAX(0, MIN(1, [[self valueForKey:@"StatusPosition" fallback:@0] integerValue]));
    self.backgroundColorEnabled = NO;
    self.swipeUpBackgroundColorEnabled = [[self valueForKey:@"EnabledSwipeUpBackgroundColor" fallback:@NO] boolValue];
    self.textColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"TextColor" fallback:@"#FFFFFF"]
                                                           fallback:UIColor.whiteColor];
    self.backgroundColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"BackgroundColor" fallback:@"#00BFFF"]
                                                                 fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
    self.swipeUpBackgroundColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"SwipeUpBackgroundColor" fallback:@"#00ADFF"]
                                                                        fallback:[UIColor colorWithRed:0 green:0.68 blue:1 alpha:1]];
}

@end
