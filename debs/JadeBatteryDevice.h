// JadeBatteryDevice.h
// Represents a single battery device (iPhone, AirPods, Watch, etc.)

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, JadeBatteryDeviceType) {
    JadeBatteryDeviceTypeiPhone,
    JadeBatteryDeviceTypeAirPods,
    JadeBatteryDeviceTypeAirPodsPro,
    JadeBatteryDeviceTypeAirPodsMax,
    JadeBatteryDeviceTypeAppleWatch,
    JadeBatteryDeviceTypeBeats,
    JadeBatteryDeviceTypeAirTag,
    JadeBatteryDeviceTypeUnknown
};

typedef NS_ENUM(NSUInteger, JadeBatteryDeviceState) {
    JadeBatteryDeviceStateUnknown,
    JadeBatteryDeviceStateUnplugged,
    JadeBatteryDeviceStateCharging,
    JadeBatteryDeviceStateFull
};

@interface JadeBatteryDevice : NSObject

@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *identifier;
@property (nonatomic, assign) JadeBatteryDeviceType deviceType;
@property (nonatomic, assign) JadeBatteryDeviceState batteryState;
@property (nonatomic, assign) float batteryLevel;
@property (nonatomic, assign) BOOL isCharging;
@property (nonatomic, assign) BOOL isLowPower;
@property (nonatomic, assign) BOOL isInternal;
@property (nonatomic, assign) BOOL isPaired;
@property (nonatomic, strong, nullable) UIImage *deviceIcon;
@property (nonatomic, copy, nullable) NSString *batteryLevelString;

+ (instancetype)deviceWithName:(NSString *)name level:(float)level;
+ (instancetype)deviceWithName:(NSString *)name level:(float)level state:(JadeBatteryDeviceState)state;
+ (instancetype)internalDevice;

- (BOOL)isEqual:(id)object;
- (NSComparisonResult)compare:(JadeBatteryDevice *)otherDevice;

@end

NS_ASSUME_NONNULL_END
