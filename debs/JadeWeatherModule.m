// JadeWeatherModule.m
// Weather display module for the Jade control center

#import "JadeWeatherModule.h"
#import "JadeLocalization.h"
#import "JadeWeatherHandler.h"

@interface JadeWeatherModule () <JadeWeatherHandlerDelegate>
@property (nonatomic, strong) UIView *weatherContentView;
@property (nonatomic, strong) UIStackView *textStackView;
@property (nonatomic, strong) NSUserDefaults *prefs;
@end

@implementation JadeWeatherModule

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        _isLoading = NO;
        _hasWeatherData = NO;
        _isExpanded = NO;

        // Weather Handler
        _weatherHandler = [JadeWeatherHandler sharedHandler];
        _weatherHandler.delegate = self;

        [self setupViews];
        [self setupConstraints];

        // Initial load
        [self showLoadingState];
        [self refreshWeather];
    }
    return self;
}

- (void)dealloc {
    _weatherHandler.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View Setup

- (void)setupViews {
    // Main container for weather content
    _weatherContentView = [[UIView alloc] initWithFrame:CGRectZero];
    _weatherContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_weatherContentView];

    // Condition Icon Image View
    _conditionIconImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _conditionIconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _conditionIconImageView.tintColor = [UIColor labelColor];
    _conditionIconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_weatherContentView addSubview:_conditionIconImageView];

    // Text Stack View (location, condition, high/low)
    _textStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _textStackView.axis = UILayoutConstraintAxisVertical;
    _textStackView.distribution = UIStackViewDistributionFill;
    _textStackView.alignment = UIStackViewAlignmentLeading;
    _textStackView.spacing = 1;
    _textStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_weatherContentView addSubview:_textStackView];

    // Location Label
    _locationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _locationLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _locationLabel.textColor = [UIColor secondaryLabelColor];
    _locationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_textStackView addArrangedSubview:_locationLabel];

    // Condition Label
    _conditionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _conditionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _conditionLabel.textColor = [UIColor tertiaryLabelColor];
    _conditionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_textStackView addArrangedSubview:_conditionLabel];

    // Temperature Label
    _temperatureLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _temperatureLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
    _temperatureLabel.textColor = [UIColor labelColor];
    _temperatureLabel.textAlignment = NSTextAlignmentRight;
    _temperatureLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_weatherContentView addSubview:_temperatureLabel];

    // High/Low Label
    _highLowLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _highLowLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _highLowLabel.textColor = [UIColor tertiaryLabelColor];
    _highLowLabel.textAlignment = NSTextAlignmentRight;
    _highLowLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_weatherContentView addSubview:_highLowLabel];

    // Loading Indicator
    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.hidesWhenStopped = YES;
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_loadingIndicator];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Weather Content View - fills self
        [_weatherContentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_weatherContentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_weatherContentView.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [_weatherContentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],

        // Condition Icon
        [_conditionIconImageView.leadingAnchor constraintEqualToAnchor:_weatherContentView.leadingAnchor],
        [_conditionIconImageView.centerYAnchor constraintEqualToAnchor:_weatherContentView.centerYAnchor],
        [_conditionIconImageView.widthAnchor constraintEqualToConstant:36],
        [_conditionIconImageView.heightAnchor constraintEqualToConstant:36],

        // Text Stack View (next to icon)
        [_textStackView.leadingAnchor constraintEqualToAnchor:_conditionIconImageView.trailingAnchor constant:10],
        [_textStackView.centerYAnchor constraintEqualToAnchor:_weatherContentView.centerYAnchor],
        [_textStackView.trailingAnchor constraintLessThanOrEqualToAnchor:_temperatureLabel.leadingAnchor constant:-8],

        // Temperature Label (right side)
        [_temperatureLabel.trailingAnchor constraintEqualToAnchor:_weatherContentView.trailingAnchor],
        [_temperatureLabel.topAnchor constraintEqualToAnchor:_weatherContentView.topAnchor constant:4],

        // High/Low Label (below temperature)
        [_highLowLabel.trailingAnchor constraintEqualToAnchor:_weatherContentView.trailingAnchor],
        [_highLowLabel.topAnchor constraintEqualToAnchor:_temperatureLabel.bottomAnchor constant:2],

        // Loading Indicator - centered
        [_loadingIndicator.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_loadingIndicator.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
}

#pragma mark - Weather Data

- (void)refreshWeather {
    [self.weatherHandler refreshWeatherData];
}

- (void)updateWeatherDisplay {
    if (!self.weatherHandler.hasWeatherData) {
        [self showErrorState];
        return;
    }

    self.hasWeatherData = YES;
    self.isLoading = NO;

    // Temperature
    NSNumber *temp = self.weatherHandler.temperature;
    if (temp) {
        self.temperatureLabel.text = [NSString stringWithFormat:@"%.0f\u00B0", [temp doubleValue]];
    } else {
        self.temperatureLabel.text = @"--\u00B0";
    }

    // Condition Description
    NSString *condition = self.weatherHandler.conditionDescription;
    if (condition) {
        self.conditionLabel.text = condition;
        self.conditionLabel.hidden = NO;
    } else {
        self.conditionLabel.hidden = YES;
    }

    // Location Name
    NSString *location = self.weatherHandler.locationName;
    if (location) {
        self.locationLabel.text = location;
        self.locationLabel.hidden = NO;
    } else {
        self.locationLabel.hidden = YES;
    }

    // High/Low
    NSNumber *high = self.weatherHandler.highTemperature;
    NSNumber *low = self.weatherHandler.lowTemperature;
    if (high && low) {
        self.highLowLabel.text = [NSString stringWithFormat:@"H:%.0f\u00B0 L:%.0f\u00B0", [high doubleValue], [low doubleValue]];
        self.highLowLabel.hidden = NO;
    } else {
        self.highLowLabel.hidden = YES;
    }

    // Condition Icon
    NSString *iconName = self.weatherHandler.conditionIconName;
    UIImage *conditionImage = nil;

    if (iconName) {
        // Try WeatherImageLoader for system condition images
        Class weatherImageLoader = NSClassFromString(@"WeatherImageLoader");
        if (weatherImageLoader) {
            SEL conditionImageSel = NSSelectorFromString(@"conditionImageWithConditionIndex:");
            if ([weatherImageLoader respondsToSelector:conditionImageSel]) {
                IMP imp = [weatherImageLoader methodForSelector:conditionImageSel];
                UIImage *(*func)(id, SEL, NSInteger) = (void *)imp;
                conditionImage = func(weatherImageLoader, conditionImageSel, [iconName integerValue]);
            }
        }

        // Fallback to SF Symbol
        if (!conditionImage) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
            conditionImage = [UIImage systemImageNamed:[self _sfSymbolForWeatherIcon:iconName] withConfiguration:config];
        }
    }

    if (conditionImage) {
        self.conditionIconImageView.image = conditionImage;
    }

    [self applyColorPreferences];
    [self showWeatherData];
}

#pragma mark - State Display

- (void)showLoadingState {
    self.isLoading = YES;
    self.weatherContentView.hidden = YES;
    [self.loadingIndicator startAnimating];
}

- (void)showErrorState {
    self.isLoading = NO;
    self.hasWeatherData = NO;
    [self.loadingIndicator stopAnimating];
    self.weatherContentView.hidden = NO;

    self.temperatureLabel.text = @"--\u00B0";
    self.conditionLabel.text = JadeLocalizedString(@"Unable to load weather");
    self.locationLabel.text = @"";
    self.highLowLabel.text = @"";
    self.conditionLabel.hidden = NO;

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
    self.conditionIconImageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle" withConfiguration:config];
    self.conditionIconImageView.tintColor = [UIColor systemYellowColor];
}

- (void)showWeatherData {
    self.isLoading = NO;
    [self.loadingIndicator stopAnimating];
    self.weatherContentView.hidden = NO;
}

#pragma mark - JadeWeatherHandlerDelegate

- (void)weatherHandler:(JadeWeatherHandler *)handler didUpdateWeatherData:(NSDictionary *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateWeatherDisplay];
    });
}

- (void)weatherHandler:(JadeWeatherHandler *)handler didFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[Jade] Weather update failed: %@", error.localizedDescription);
        [self showErrorState];
    });
}

- (void)weatherHandlerDidUpdateLocation:(JadeWeatherHandler *)handler {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshWeather];
    });
}

#pragma mark - Trait Collection

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle) {
        [self updateWeatherDisplay];
    }
}

#pragma mark - Tint/Text Colors

- (void)setTextColor:(UIColor *)textColor {
    _textColor = textColor;
    self.temperatureLabel.textColor = textColor;
}

- (void)setSecondaryTextColor:(UIColor *)secondaryTextColor {
    _secondaryTextColor = secondaryTextColor;
    self.conditionLabel.textColor = secondaryTextColor;
    self.highLowLabel.textColor = secondaryTextColor;
    self.locationLabel.textColor = secondaryTextColor;
}

#pragma mark - Expanded State

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;
    NSTimeInterval duration = animated ? 0.25 : 0.0;

    [UIView animateWithDuration:duration animations:^{
        self.conditionLabel.alpha = expanded ? 1.0 : 0.0;
        self.highLowLabel.alpha = expanded ? 1.0 : 0.0;
    }];

    if (expanded) {
        [self refreshWeather];
    }
}

#pragma mark - Color Preferences

- (void)applyColorPreferences {
    NSString *tempColorStr = [self.prefs stringForKey:@"weatherTemperatureColor"];
    if (tempColorStr) {
        UIColor *color = [self _colorFromHexString:tempColorStr];
        if (color) self.temperatureLabel.textColor = color;
    }

    NSString *conditionColorStr = [self.prefs stringForKey:@"weatherConditionColor"];
    if (conditionColorStr) {
        UIColor *color = [self _colorFromHexString:conditionColorStr];
        if (color) self.conditionLabel.textColor = color;
    }

    NSString *locationColorStr = [self.prefs stringForKey:@"weatherLocationColor"];
    if (locationColorStr) {
        UIColor *color = [self _colorFromHexString:locationColorStr];
        if (color) self.locationLabel.textColor = color;
    }

    NSString *highLowColorStr = [self.prefs stringForKey:@"weatherHighLowColor"];
    if (highLowColorStr) {
        UIColor *color = [self _colorFromHexString:highLowColorStr];
        if (color) self.highLowLabel.textColor = color;
    }
}

#pragma mark - Utility

- (NSString *)_sfSymbolForWeatherIcon:(NSString *)conditionIndex {
    // Map common Weather condition icons to SF Symbols
    NSDictionary *iconMap = @{
        @"0": @"sun.max.fill",          // Clear (day)
        @"1": @"moon.stars.fill",       // Clear (night)
        @"2": @"cloud.sun.fill",        // Mostly clear (day)
        @"3": @"cloud.moon.fill",       // Mostly clear (night)
        @"4": @"cloud.fill",            // Partly cloudy
        @"5": @"smoke.fill",            // Haze
        @"6": @"cloud.fog.fill",        // Foggy
        @"7": @"cloud.fill",            // Cloudy
        @"8": @"cloud.drizzle.fill",    // Mostly cloudy
        @"9": @"cloud.drizzle.fill",    // Drizzle
        @"10": @"cloud.rain.fill",      // Rain
        @"11": @"cloud.rain.fill",      // Mostly cloudy with rain
        @"12": @"cloud.heavyrain.fill", // Showers
        @"13": @"cloud.hail.fill",      // Hail
        @"14": @"cloud.sleet.fill",     // Sleet
        @"15": @"cloud.snow.fill",      // Freezing rain
        @"16": @"cloud.snow.fill",      // Snow
        @"17": @"cloud.bolt.fill",      // Thunderstorm
        @"18": @"cloud.bolt.rain.fill", // Thunderstorm with rain
        @"19": @"tornado",              // Tornado
        @"20": @"wind",                 // Windy
    };

    NSString *symbol = iconMap[conditionIndex];
    return symbol ?: @"cloud.sun.fill";
}

- (UIColor *)_colorFromHexString:(NSString *)hexString {
    NSString *cleanString = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([cleanString hasPrefix:@"#"]) {
        cleanString = [cleanString substringFromIndex:1];
    }
    if ([cleanString hasPrefix:@"0x"]) {
        cleanString = [cleanString substringFromIndex:2];
    }

    NSUInteger length = [cleanString length];
    if (length != 6 && length != 8) return nil;

    NSScanner *scanner = [NSScanner scannerWithString:cleanString];
    unsigned long long hexValue = 0;
    if (![scanner scanHexLongLong:&hexValue]) return nil;

    CGFloat red, green, blue, alpha;
    if (length == 8) {
        red   = ((hexValue & 0xFF000000) >> 24) / 255.0;
        green = ((hexValue & 0x00FF0000) >> 16) / 255.0;
        blue  = ((hexValue & 0x0000FF00) >> 8)  / 255.0;
        alpha =  (hexValue & 0x000000FF)         / 255.0;
    } else {
        red   = ((hexValue & 0xFF0000) >> 16) / 255.0;
        green = ((hexValue & 0x00FF00) >> 8)  / 255.0;
        blue  =  (hexValue & 0x0000FF)        / 255.0;
        alpha = 1.0;
    }

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}


@end
