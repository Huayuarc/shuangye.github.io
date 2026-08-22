#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PGPreferencesDomain;
FOUNDATION_EXPORT NSString *const PGPreferencesChangedNotification;

@interface PerfectGrabberPreferences : NSObject

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL vibrationFeedback;
@property (nonatomic, readonly) BOOL showOnSwipeUp;
@property (nonatomic, readonly) NSTimeInterval autoCloseDelay;
@property (nonatomic, readonly) BOOL disable24Hour;
@property (nonatomic, readonly) BOOL chargingIcon;
@property (nonatomic, readonly) BOOL twoLine;
@property (nonatomic, readonly) NSInteger grabberStyle;
@property (nonatomic, readonly) CGFloat fontSize;
@property (nonatomic, readonly) NSInteger fontStyle;
@property (nonatomic, readonly) CGFloat statusFontSize;
@property (nonatomic, readonly) NSInteger statusPosition;
@property (nonatomic, readonly) BOOL backgroundColorEnabled;
@property (nonatomic, readonly) BOOL swipeUpBackgroundColorEnabled;
@property (nonatomic, readonly) UIColor *textColor;
@property (nonatomic, readonly) UIColor *backgroundColor;
@property (nonatomic, readonly) UIColor *swipeUpBackgroundColor;

+ (instancetype)sharedPreferences;
+ (UIColor *)colorFromHexString:(NSString *)value fallback:(UIColor *)fallback;
- (void)reload;

@end

NS_ASSUME_NONNULL_END
