// JadeWeatherHandler.m
// Handles weather data fetching and management for the Jade control center

#import "JadeWeatherHandler.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Private framework class forward declaration
@interface WALockscreenWidgetViewController : UIViewController
- (id)currentTemperature;
- (id)currentLocation;
- (id)currentConditionImage;
- (id)currentCondition;
- (id)lowestTemperature;
- (id)highestTemperature;
- (id)currentConditionAsString;
- (void)refreshData;
- (void)_updateTodayView;
@end

@interface JadeWeatherHandler ()

@property (nonatomic, strong, readwrite) NSDictionary *currentWeatherData;
@property (nonatomic, strong, readwrite) NSString *locationName;
@property (nonatomic, strong, readwrite) NSNumber *temperature;
@property (nonatomic, strong, readwrite) NSString *conditionDescription;
@property (nonatomic, strong, readwrite) NSString *conditionIconName;
@property (nonatomic, strong, readwrite) NSNumber *highTemperature;
@property (nonatomic, strong, readwrite) NSNumber *lowTemperature;
@property (nonatomic, assign, readwrite) BOOL isFetching;
@property (nonatomic, assign, readwrite) BOOL hasWeatherData;
@property (nonatomic, strong, readwrite) NSError *lastError;

- (void)_updateWeatherDataFromWidget;
- (void)_postWeatherUpdateNotification;

@end

static JadeWeatherHandler *sharedHandlerInstance = nil;

@implementation JadeWeatherHandler {
    BOOL _isCelsius;
    WALockscreenWidgetViewController *_widget;
}


#pragma mark - Singleton

+ (instancetype)sharedHandler {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedHandlerInstance = [[self alloc] init];
    });
    return sharedHandlerInstance;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        _isCelsius = YES;

        Class widgetClass = NSClassFromString(@"WALockscreenWidgetViewController");
        if (widgetClass) {
            _widget = [[widgetClass alloc] init];
            if ([_widget respondsToSelector:@selector(refreshData)]) {
                [_widget refreshData];
            }
        }

        // Initialize weather data
        _hasWeatherData = NO;
        _isFetching = NO;

        // Perform initial data update
        [self _updateWeatherDataFromWidget];
    }
    return self;
}

#pragma mark - Binary Methods (WALockscreenWidgetViewController bridge)

- (id)currentTemperature {
    if (!_widget) return nil;
    if ([_widget respondsToSelector:@selector(currentTemperature)]) {
        return [_widget currentTemperature];
    }
    return nil;
}

- (id)currentLocation {
    if (!_widget) return nil;
    if ([_widget respondsToSelector:@selector(currentLocation)]) {
        return [_widget currentLocation];
    }
    return nil;
}

- (id)currentConditionImage {
    if (!_widget) return nil;
    if ([_widget respondsToSelector:@selector(currentConditionImage)]) {
        return [_widget currentConditionImage];
    }
    return nil;
}

- (id)currentCondition {
    if (!_widget) return nil;
    if ([_widget respondsToSelector:@selector(currentCondition)]) {
        return [_widget currentCondition];
    }
    return nil;
}

- (id)lowestTemperature {
    if (!_widget) return nil;
    @try {
        if ([_widget respondsToSelector:@selector(lowestTemperature)]) {
            return [_widget lowestTemperature];
        }
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:@"lowestTemperature"]) {
            NSLog(@"[JadeWeatherHandler] Caught exception lowestTemperature: %@", exception.reason);
        }
        return nil;
    }
    return nil;
}

- (id)highestTemperature {
    if (!_widget) return nil;
    @try {
        if ([_widget respondsToSelector:@selector(highestTemperature)]) {
            return [_widget highestTemperature];
        }
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:@"highestTemperature"]) {
            NSLog(@"[JadeWeatherHandler] Caught exception highestTemperature: %@", exception.reason);
        }
        return nil;
    }
    return nil;
}

- (id)currentConditionAsString {
    if (!_widget) return nil;
    if ([_widget respondsToSelector:@selector(currentConditionAsString)]) {
        return [_widget currentConditionAsString];
    }
    return nil;
}

#pragma mark - isCelsius

- (BOOL)isCelsius {
    return _isCelsius;
}

- (void)setIsCelsius:(BOOL)isCelsius {
    _isCelsius = isCelsius;
    if ([_widget respondsToSelector:@selector(refreshData)]) {
        [_widget refreshData];
    }
    if ([_widget respondsToSelector:@selector(_updateTodayView)]) {
        [_widget _updateTodayView];
    }
    [self _updateWeatherDataFromWidget];
}

#pragma mark - refreshData

- (void)refreshData {
    if ([_widget respondsToSelector:@selector(refreshData)]) {
        [_widget refreshData];
    }
    if ([_widget respondsToSelector:@selector(_updateTodayView)]) {
        [_widget _updateTodayView];
    }
    [self _updateWeatherDataFromWidget];
}

#pragma mark - Internal Methods

- (void)_updateWeatherDataFromWidget {
    // Update temperature
    id temp = [self currentTemperature];
    if (temp) {
        self.temperature = @([temp doubleValue]);
    }

    // Update location
    id location = [self currentLocation];
    if (location) {
        if ([location isKindOfClass:[NSString class]]) {
            self.locationName = (NSString *)location;
        } else if ([location isKindOfClass:[CLLocation class]]) {
            CLLocation *loc = (CLLocation *)location;
            self.locationName = [NSString stringWithFormat:@"%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude];
        }
    }

    // Update condition description
    id condition = [self currentConditionAsString];
    if (condition) {
        self.conditionDescription = (NSString *)condition;
    } else {
        id rawCondition = [self currentCondition];
        if (rawCondition && [rawCondition respondsToSelector:@selector(description)]) {
            self.conditionDescription = [rawCondition description];
        }
    }

    // Update condition icon
    id conditionIcon = [self currentConditionImage];
    if (conditionIcon) {
        // Derive icon name from image or set a default
        self.conditionIconName = @"cloud.sun.fill";
    }

    // Update high/low temperatures
    id high = [self highestTemperature];
    if (high) {
        self.highTemperature = @([high doubleValue]);
    }

    id low = [self lowestTemperature];
    if (low) {
        self.lowTemperature = @([low doubleValue]);
    }

    // Build full weather data dictionary
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    if (self.temperature) data[@"temperature"] = self.temperature;
    if (self.locationName) data[@"locationName"] = self.locationName;
    if (self.conditionDescription) data[@"conditionDescription"] = self.conditionDescription;
    if (self.conditionIconName) data[@"conditionIconName"] = self.conditionIconName;
    if (self.highTemperature) data[@"highTemperature"] = self.highTemperature;
    if (self.lowTemperature) data[@"lowTemperature"] = self.lowTemperature;
    data[@"isCelsius"] = @(_isCelsius);
    self.currentWeatherData = [data copy];

    _hasWeatherData = (self.temperature != nil);
    self.lastError = nil;

    // Notify delegate
    if ([self.delegate respondsToSelector:@selector(weatherHandler:didUpdateWeatherData:)]) {
        [self.delegate weatherHandler:self didUpdateWeatherData:self.currentWeatherData];
    }

    [self _postWeatherUpdateNotification];
}

- (void)_postWeatherUpdateNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"JadeWeatherDataDidUpdate"
                                                        object:self
                                                      userInfo:self.currentWeatherData];
}

#pragma mark - Public API (Header Methods)

- (void)requestWeatherData {
    if (_isFetching) return;
    _isFetching = YES;
    [self refreshData];
    _isFetching = NO;
}

- (void)refreshWeatherData {
    [self refreshData];
}

- (void)forceRefresh {
    _hasWeatherData = NO;
    if ([_widget respondsToSelector:@selector(refreshData)]) {
        [_widget refreshData];
    }
    if ([_widget respondsToSelector:@selector(_updateTodayView)]) {
        [_widget _updateTodayView];
    }
    [self _updateWeatherDataFromWidget];
}

- (void)startAutoRefresh {
    [NSTimer scheduledTimerWithTimeInterval:300.0
                                     target:self
                                   selector:@selector(refreshWeatherData)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)stopAutoRefresh {
    // Stub - in a full implementation we would invalidate the timer
}

- (void)updateLocation {
    if ([_widget respondsToSelector:@selector(currentLocation)]) {
        id location = [_widget currentLocation];
        if (location) {
            if ([location isKindOfClass:[NSString class]]) {
                self.locationName = (NSString *)location;
            }
            if ([self.delegate respondsToSelector:@selector(weatherHandlerDidUpdateLocation:)]) {
                [self.delegate weatherHandlerDidUpdateLocation:self];
            }
        }
    }
}

@end
