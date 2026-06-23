// JadeTimePill.h
// Pill-shaped time display for the Jade control center

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JadeTimePill : UIView

@property (nonatomic, strong, nullable) UILabel *timeLabel;
@property (nonatomic, strong, nullable) UILabel *dateLabel;
@property (nonatomic, strong, nullable) UIView *pillContainer;
@property (nonatomic, strong, nullable) NSTimer *updateTimer;
@property (nonatomic, strong, nullable) UIColor *textColor;
@property (nonatomic, strong, nullable) UIColor *pillBackgroundColor;
@property (nonatomic, assign) BOOL showsDate;
@property (nonatomic, assign) BOOL showsSeconds;
@property (nonatomic, assign) BOOL is24HourFormat;

- (void)setupViews;
- (void)setupConstraints;
- (void)updateTime;
- (void)startUpdating;
- (void)stopUpdating;
- (void)setTextColor:(UIColor *)color animated:(BOOL)animated;
- (NSString *)formattedTimeString;
- (NSString *)formattedDateString;

@end

NS_ASSUME_NONNULL_END
