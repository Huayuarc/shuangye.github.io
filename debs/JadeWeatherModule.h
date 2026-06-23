// JadeWeatherModule.h
// Weather display module for the Jade control center

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JadeWeatherHandler;

@interface JadeWeatherModule : UIView

@property (nonatomic, strong, nullable) UIImageView *conditionIconImageView;
@property (nonatomic, strong, nullable) UILabel *temperatureLabel;
@property (nonatomic, strong, nullable) UILabel *conditionLabel;
@property (nonatomic, strong, nullable) UILabel *highLowLabel;
@property (nonatomic, strong, nullable) UILabel *locationLabel;
@property (nonatomic, strong, nullable) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong, nullable) JadeWeatherHandler *weatherHandler;
@property (nonatomic, strong, nullable) UIColor *textColor;
@property (nonatomic, strong, nullable) UIColor *secondaryTextColor;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL hasWeatherData;
@property (nonatomic, assign) BOOL isExpanded;

- (void)setupViews;
- (void)setupConstraints;
- (void)refreshWeather;
- (void)updateWeatherDisplay;
- (void)showLoadingState;
- (void)showErrorState;
- (void)showWeatherData;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
