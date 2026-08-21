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
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PGPreferencesDomain);
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
    NSString *migrationKey = @"PGRestoredLegacySingleLine";
    if (![[self valueForKey:migrationKey fallback:@NO] boolValue]) {
        CFPreferencesSetAppValue(CFSTR("TwoLine"), kCFBooleanFalse,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)migrationKey, kCFBooleanTrue,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)PGPreferencesDomain);
    }
    self.enabled = [[self valueForKey:@"EnabledPerfectGrabber" fallback:@NO] boolValue];
    self.vibrationFeedback = [[self valueForKey:@"VibrationFeedback" fallback:@YES] boolValue];
    self.showOnSwipeUp = [[self valueForKey:@"ShowOnSwipeUp" fallback:@YES] boolValue];
    self.autoCloseDelay = MAX(1.0, MIN(10.0, [[self valueForKey:@"AutoCloseDelay" fallback:@8.0] doubleValue]));
    self.disable24Hour = [[self valueForKey:@"Disable24H" fallback:@NO] boolValue];
    self.chargingIcon = [[self valueForKey:@"ChargingIcon" fallback:@YES] boolValue];
    self.twoLine = [[self valueForKey:@"TwoLine" fallback:@NO] boolValue];
    self.grabberStyle = MAX(0, MIN(2, [[self valueForKey:@"GrabberStyle" fallback:@0] integerValue]));
    self.fontSize = MAX(8.0, MIN(28.0, [[self valueForKey:@"FontSize" fallback:@12.0] doubleValue]));
    self.fontStyle = MAX(0, MIN(2, [[self valueForKey:@"FontStyle" fallback:@0] integerValue]));
    self.backgroundColorEnabled = [[self valueForKey:@"EnabledBackgroundColor" fallback:@NO] boolValue];
    self.swipeUpBackgroundColorEnabled = [[self valueForKey:@"EnabledSwipeUpBackgroundColor" fallback:@NO] boolValue];
    self.textColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"TextColor" fallback:@"#FFFFFF"]
                                                           fallback:UIColor.whiteColor];
    self.backgroundColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"BackgroundColor" fallback:@"#00BFFF"]
                                                                 fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
    self.swipeUpBackgroundColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"SwipeUpBackgroundColor" fallback:@"#00ADFF"]
                                                                        fallback:[UIColor colorWithRed:0 green:0.68 blue:1 alpha:1]];
}

@end
