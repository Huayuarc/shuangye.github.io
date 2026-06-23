// JadeCurrentUptimeModule.h
// Module displaying current system uptime information

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JadeCurrentUptimeModule : UIView

@property (nonatomic, strong, nullable) UILabel *uptimeLabel;
@property (nonatomic, strong, nullable) UILabel *uptimeValueLabel;
@property (nonatomic, strong, nullable) UILabel *sinceLabel;
@property (nonatomic, strong, nullable) NSTimer *updateTimer;
@property (nonatomic, strong, nullable) UIColor *textColor;
@property (nonatomic, strong, nullable) UIColor *valueTextColor;
@property (nonatomic, assign) BOOL isShowingDetailed;

- (void)setupViews;
- (void)setupConstraints;
- (void)refreshUptime;
- (void)startUpdating;
- (void)stopUpdating;
- (void)toggleDetailedView;
- (NSString *)formattedUptime;
- (NSString *)formattedBootDate;
- (NSString *)formattedDetailedUptime;

@end

NS_ASSUME_NONNULL_END
