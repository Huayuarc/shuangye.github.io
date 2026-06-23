// JadeBatteryDevice.m
// Represents a single battery device (iPhone, AirPods, Watch, etc.)

#import "JadeBatteryDevice.h"

@implementation JadeBatteryDevice

#pragma mark - Convenience Constructors

+ (instancetype)deviceWithName:(NSString *)name level:(float)level {
    return [self deviceWithName:name level:level state:JadeBatteryDeviceStateUnknown];
}

+ (instancetype)deviceWithName:(NSString *)name level:(float)level state:(JadeBatteryDeviceState)state {
    JadeBatteryDevice *device = [[JadeBatteryDevice alloc] init];
    device.name = name;
    device.batteryLevel = level;
    device.batteryState = state;
    device.isCharging = (state == JadeBatteryDeviceStateCharging);
    device.isPaired = YES;
    device.isInternal = NO;

    // Determine device type from name
    [device _inferDeviceTypeFromName];

    // Generate icon
    device.deviceIcon = [device _generateIcon];

    // Generate level string
    device.batteryLevelString = [device _formattedLevelString];

    return device;
}

+ (instancetype)internalDevice {
    JadeBatteryDevice *device = [[JadeBatteryDevice alloc] init];
    device.name = @"iPhone";
    device.isInternal = YES;
    device.isPaired = YES;
    device.deviceType = JadeBatteryDeviceTypeiPhone;
    device.batteryState = JadeBatteryDeviceStateUnknown;

    // Get current device battery level
    UIDevice *currentDevice = [UIDevice currentDevice];
    [currentDevice setBatteryMonitoringEnabled:YES];
    float level = currentDevice.batteryLevel;
    if (level < 0) level = 1.0f;
    device.batteryLevel = level;

    UIDeviceBatteryState state = currentDevice.batteryState;
    device.isCharging = (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
    if (device.isCharging) {
        device.batteryState = JadeBatteryDeviceStateCharging;
    } else if (level >= 1.0f) {
        device.batteryState = JadeBatteryDeviceStateFull;
    } else {
        device.batteryState = JadeBatteryDeviceStateUnplugged;
    }

    device.deviceIcon = [device _generateIcon];
    device.batteryLevelString = [device _formattedLevelString];

    return device;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceType = JadeBatteryDeviceTypeUnknown;
        _batteryState = JadeBatteryDeviceStateUnknown;
        _batteryLevel = 0.0f;
        _isCharging = NO;
        _isLowPower = NO;
        _isInternal = NO;
        _isPaired = NO;
    }
    return self;
}

#pragma mark - Private Helpers

- (void)_inferDeviceTypeFromName {
    if (!_name) {
        _deviceType = JadeBatteryDeviceTypeUnknown;
        return;
    }

    NSString *lowercaseName = [_name lowercaseString];

    if ([lowercaseName containsString:@"iphone"] || [_name isEqualToString:@"iPhone"]) {
        _deviceType = JadeBatteryDeviceTypeiPhone;
    } else if ([lowercaseName containsString:@"airpods pro"] || [lowercaseName containsString:@"airpods-pro"]) {
        _deviceType = JadeBatteryDeviceTypeAirPodsPro;
    } else if ([lowercaseName containsString:@"airpods max"] || [lowercaseName containsString:@"airpods-max"]) {
        _deviceType = JadeBatteryDeviceTypeAirPodsMax;
    } else if ([lowercaseName containsString:@"airpods"] || [lowercaseName containsString:@"airpods"]) {
        _deviceType = JadeBatteryDeviceTypeAirPods;
    } else if ([lowercaseName containsString:@"watch"] || [lowercaseName containsString:@"apple watch"]) {
        _deviceType = JadeBatteryDeviceTypeAppleWatch;
    } else if ([lowercaseName containsString:@"beats"] || [lowercaseName containsString:@"beats"]) {
        _deviceType = JadeBatteryDeviceTypeBeats;
    } else if ([lowercaseName containsString:@"airtag"] || [lowercaseName containsString:@"air tag"]) {
        _deviceType = JadeBatteryDeviceTypeAirTag;
    } else {
        _deviceType = JadeBatteryDeviceTypeUnknown;
    }
}

- (UIImage *)_generateIcon {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
    NSString *symbolName = [self _symbolNameForDeviceType];
    UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:config];
    if (!image) {
        image = [UIImage systemImageNamed:@"questionmark.circle" withConfiguration:config];
    }
    return image;
}

- (NSString *)_symbolNameForDeviceType {
    switch (_deviceType) {
        case JadeBatteryDeviceTypeiPhone:
            return @"iphone";
        case JadeBatteryDeviceTypeAirPods:
            return @"airpods";
        case JadeBatteryDeviceTypeAirPodsPro:
            return @"airpods.pro";
        case JadeBatteryDeviceTypeAirPodsMax:
            return @"airpods.max";
        case JadeBatteryDeviceTypeAppleWatch:
            return @"applewatch";
        case JadeBatteryDeviceTypeBeats:
            return @"beats.headphones";
        case JadeBatteryDeviceTypeAirTag:
            return @"airtag";
        case JadeBatteryDeviceTypeUnknown:
        default:
            return @"questionmark.circle";
    }
}

- (NSString *)_formattedLevelString {
    if (_batteryState == JadeBatteryDeviceStateFull) {
        return @"100%";
    }
    int percentInt = (int)(_batteryLevel * 100);
    percentInt = MAX(0, MIN(100, percentInt));
    return [NSString stringWithFormat:@"%d%%", percentInt];
}

#pragma mark - NSObject Overrides

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[JadeBatteryDevice class]]) return NO;

    JadeBatteryDevice *other = (JadeBatteryDevice *)object;

    BOOL nameEqual = (!_name && !other.name) || [_name isEqualToString:other.name];
    BOOL identifierEqual = (!_identifier && !other.identifier) || [_identifier isEqualToString:other.identifier];
    BOOL typeEqual = (_deviceType == other.deviceType);

    return nameEqual && identifierEqual && typeEqual;
}

- (NSUInteger)hash {
    return [_name hash] ^ [_identifier hash] ^ (_deviceType * 2654435761u);
}

- (NSComparisonResult)compare:(JadeBatteryDevice *)otherDevice {
    if (!otherDevice) return NSOrderedDescending;

    // Internal device always first
    if (_isInternal && !otherDevice.isInternal) return NSOrderedAscending;
    if (!_isInternal && otherDevice.isInternal) return NSOrderedDescending;

    // Then sort by battery level descending (higher first)
    if (_batteryLevel > otherDevice.batteryLevel) return NSOrderedAscending;
    if (_batteryLevel < otherDevice.batteryLevel) return NSOrderedDescending;

    // Then sort by name
    return [_name localizedCaseInsensitiveCompare:otherDevice.name];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, name=%@, level=%.0f%%, charging=%d, type=%lu>",
            NSStringFromClass([self class]), self, _name, _batteryLevel * 100, _isCharging, (unsigned long)_deviceType];
}

@end
