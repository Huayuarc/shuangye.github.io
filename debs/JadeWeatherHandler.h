// JadeWeatherHandler.h
// Handles weather data fetching and management for the Jade control center

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@class JadeWeatherHandler;

@protocol JadeWeatherHandlerDelegate <NSObject>
@optional
- (void)weatherHandler:(JadeWeatherHandler *)handler didUpdateWeatherData:(NSDictionary *)data;
- (void)weatherHandler:(JadeWeatherHandler *)handler didFailWithError:(NSError *)error;
- (void)weatherHandlerDidUpdateLocation:(JadeWeatherHandler *)handler;
@end

@interface JadeWeatherHandler : NSObject

@property (nonatomic, weak, nullable) id<JadeWeatherHandlerDelegate> delegate;
@property (nonatomic, strong, readonly, nullable) NSDictionary *currentWeatherData;
@property (nonatomic, strong, readonly, nullable) NSString *locationName;
@property (nonatomic, strong, readonly, nullable) NSNumber *temperature;
@property (nonatomic, strong, readonly, nullable) NSString *conditionDescription;
@property (nonatomic, strong, readonly, nullable) NSString *conditionIconName;
@property (nonatomic, strong, readonly, nullable) NSNumber *highTemperature;
@property (nonatomic, strong, readonly, nullable) NSNumber *lowTemperature;
@property (nonatomic, assign, readonly) BOOL isFetching;
@property (nonatomic, assign, readonly) BOOL hasWeatherData;
@property (nonatomic, strong, readonly, nullable) NSError *lastError;

+ (instancetype)sharedHandler;

- (void)requestWeatherData;
- (void)refreshWeatherData;
- (void)forceRefresh;
- (void)startAutoRefresh;
- (void)stopAutoRefresh;
- (void)updateLocation;

@end

NS_ASSUME_NONNULL_END
