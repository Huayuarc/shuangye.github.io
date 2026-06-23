// JadeBatteryModule.m
// Battery module displaying battery levels of all connected devices

#import "JadeBatteryModule.h"
#import "JadeLocalization.h"
#import "JadeBatteryDevice.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

static NSString *const JadeBatteryDevicesDidChangeNotification = @"BCBatteryDeviceControllerConnectedDevicesDidChangeNotification";

static void JadeLoadBatteryCenterFramework(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter", RTLD_LAZY);
    });
}

static id JadeObjectValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    id (*messageSend)(id, SEL) = (id (*)(id, SEL))[object methodForSelector:selector];
    return messageSend(object, selector);
}

static BOOL JadeBoolValue(id object, SEL selector, BOOL defaultValue) {
    if (!object || ![object respondsToSelector:selector]) return defaultValue;
    BOOL (*messageSend)(id, SEL) = (BOOL (*)(id, SEL))[object methodForSelector:selector];
    return messageSend(object, selector);
}

static NSInteger JadeIntegerValue(id object, SEL selector, NSInteger defaultValue) {
    if (!object || ![object respondsToSelector:selector]) return defaultValue;
    NSInteger (*messageSend)(id, SEL) = (NSInteger (*)(id, SEL))[object methodForSelector:selector];
    return messageSend(object, selector);
}

static float JadeFloatValue(id object, SEL selector, float defaultValue) {
    if (!object || ![object respondsToSelector:selector]) return defaultValue;
    float (*messageSend)(id, SEL) = (float (*)(id, SEL))[object methodForSelector:selector];
    return messageSend(object, selector);
}

@interface JadeBatteryModule ()

@property (nonatomic, strong) id batteryController;
@property (nonatomic, strong) UILabel *noDevicesLabel;

@end

@implementation JadeBatteryModule

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _connectedDevices = [[NSMutableArray alloc] init];
        _isExpanded = NO;

        // Read preferences
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
        NSString *tintColorHex = [prefs stringForKey:@"moduleTintColor"];
        if (tintColorHex) {
            _moduleTintColor = [self _colorFromHexString:tintColorHex];
        } else {
            _moduleTintColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0]; // 0A84FF
        }

        [self setupViews];
        [self setupConstraints];

        // Get battery controller
        JadeLoadBatteryCenterFramework();
        Class controllerClass = NSClassFromString(@"BCBatteryDeviceController");
        if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
            id (*sharedInstance)(id, SEL) = (id (*)(id, SEL))[controllerClass methodForSelector:@selector(sharedInstance)];
            _batteryController = sharedInstance(controllerClass, @selector(sharedInstance));
        }

        // Observe connected devices changes
        NSString *notificationName = JadeBatteryDevicesDidChangeNotification;
        NSString *controllerNotificationName = JadeObjectValue(_batteryController, @selector(connectedDevicesDidChangeNotificationName));
        if ([controllerNotificationName isKindOfClass:[NSString class]] && controllerNotificationName.length > 0) {
            notificationName = controllerNotificationName;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(refreshBatteryData)
                                                     name:notificationName
                                                   object:nil];

        // Initial data load
        [self refreshBatteryData];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    // Title label
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.text = @"Batteries";
    [self addSubview:_titleLabel];

    // Stack view for device rows
    _devicesStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _devicesStackView.translatesAutoresizingMaskIntoConstraints = NO;
    _devicesStackView.axis = UILayoutConstraintAxisVertical;
    _devicesStackView.distribution = UIStackViewDistributionFillEqually;
    _devicesStackView.alignment = UIStackViewAlignmentFill;
    _devicesStackView.spacing = 4;
    [self addSubview:_devicesStackView];

    // No devices label (localized)
    _noDevicesLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _noDevicesLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _noDevicesLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _noDevicesLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    _noDevicesLabel.textAlignment = NSTextAlignmentCenter;
    _noDevicesLabel.text = JadeLocalizedString(@"NO_BLUETOOTH_DEVICES_CONNECTED");
    _noDevicesLabel.numberOfLines = 0;
    _noDevicesLabel.hidden = YES;
    [self addSubview:_noDevicesLabel];

    self.backgroundColor = [UIColor clearColor];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Title label at top
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],

        // Stack view below title
        [_devicesStackView.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8],
        [_devicesStackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_devicesStackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_devicesStackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        // No devices label centered
        [_noDevicesLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_noDevicesLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_noDevicesLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [_noDevicesLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
    ]];
}

#pragma mark - Data Refresh

- (void)refreshBatteryData {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _loadDevices];
        [self updateDeviceList];
    });
}

- (void)_loadDevices {
    [_connectedDevices removeAllObjects];

    // Always add internal device first
    JadeBatteryDevice *internal = [JadeBatteryDevice internalDevice];
    [_connectedDevices addObject:internal];

    // Query BCBatteryDeviceController for connected devices
    if (_batteryController) {
        NSArray *devices = JadeObjectValue(_batteryController, @selector(connectedDevices));
        for (id device in devices) {
            BOOL isConnected = JadeBoolValue(device, @selector(isConnected), JadeBoolValue(device, @selector(connected), YES));
            BOOL isInternal = JadeBoolValue(device, @selector(isInternal), JadeBoolValue(device, @selector(internalDevice), NO));
            if (!isConnected) continue;
            if (isInternal) continue; // Skip internal, we add our own

            NSString *name = JadeObjectValue(device, @selector(name));
            NSString *identifier = JadeObjectValue(device, @selector(identifier));
            NSInteger vendor = JadeIntegerValue(device, @selector(vendor), 0);
            float batteryLevel = JadeFloatValue(device, @selector(level), -1.0f);
            if (batteryLevel < 0.0f) {
                NSInteger percentCharge = JadeIntegerValue(device, @selector(percentCharge), -1);
                batteryLevel = percentCharge >= 0 ? (float)percentCharge / 100.0f : 0.0f;
            }
            batteryLevel = MAX(0.0f, MIN(1.0f, batteryLevel));

            BOOL isCharging = JadeBoolValue(device, @selector(isCharging), JadeBoolValue(device, @selector(charging), NO));
            BOOL isLowPower = JadeBoolValue(device, @selector(lowPower), JadeBoolValue(device, @selector(isLowBattery), NO));

            JadeBatteryDevice *jadeDevice = [[JadeBatteryDevice alloc] init];
            jadeDevice.name = name;
            jadeDevice.identifier = identifier;
            jadeDevice.batteryLevel = batteryLevel;
            jadeDevice.isCharging = isCharging;
            jadeDevice.isLowPower = isLowPower;
            jadeDevice.isInternal = isInternal;
            jadeDevice.isPaired = YES;

            // Map vendor to device type
            jadeDevice.deviceType = [self _deviceTypeForVendor:vendor name:name];

            // Map battery state
            NSInteger batteryState = JadeIntegerValue(device, @selector(batteryState), 0);
            switch (batteryState) {
                case 1:
                    jadeDevice.batteryState = JadeBatteryDeviceStateUnplugged;
                    break;
                case 2:
                    jadeDevice.batteryState = JadeBatteryDeviceStateCharging;
                    break;
                case 3:
                    jadeDevice.batteryState = JadeBatteryDeviceStateFull;
                    break;
                default:
                    if (isCharging) {
                        jadeDevice.batteryState = JadeBatteryDeviceStateCharging;
                    } else if (batteryLevel >= 0.99f) {
                        jadeDevice.batteryState = JadeBatteryDeviceStateFull;
                    } else {
                        jadeDevice.batteryState = JadeBatteryDeviceStateUnplugged;
                    }
                    break;
            }

            jadeDevice.deviceIcon = [self _iconForDevice:device];
            NSString *batteryLevelString = JadeObjectValue(device, @selector(batteryLevelString));
            jadeDevice.batteryLevelString = [batteryLevelString isKindOfClass:[NSString class]] ? batteryLevelString : [NSString stringWithFormat:@"%.0f%%", batteryLevel * 100];

            [_connectedDevices addObject:jadeDevice];
        }
    }

    // Sort devices (internal first, then by level desc)
    [_connectedDevices sortUsingComparator:^NSComparisonResult(JadeBatteryDevice *a, JadeBatteryDevice *b) {
        return [a compare:b];
    }];
}

- (void)updateDeviceList {
    // Remove existing device subviews from stack
    NSArray *arrangedViews = [_devicesStackView.arrangedSubviews copy];
    for (UIView *view in arrangedViews) {
        [_devicesStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (_connectedDevices.count <= 1) {
        // Only internal device or none - show no devices label
        _noDevicesLabel.hidden = NO;
        return;
    }

    _noDevicesLabel.hidden = YES;

    // Add device views for external devices
    for (JadeBatteryDevice *device in _connectedDevices) {
        if (device.isInternal) continue; // Skip internal in the module list

        UIView *deviceRow = [self _createDeviceRowForDevice:device];
        if (deviceRow) {
            [_devicesStackView addArrangedSubview:deviceRow];
        }
    }
}

#pragma mark - Device Management

- (void)addDevice:(JadeBatteryDevice *)device {
    if (!device) return;
    if ([_connectedDevices containsObject:device]) return;

    [_connectedDevices addObject:device];
    [_connectedDevices sortUsingComparator:^NSComparisonResult(JadeBatteryDevice *a, JadeBatteryDevice *b) {
        return [a compare:b];
    }];
    [self updateDeviceList];
}

- (void)removeDevice:(JadeBatteryDevice *)device {
    if (!device) return;
    [_connectedDevices removeObject:device];
    [self updateDeviceList];
}

#pragma mark - Expand/Collapse

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;
    if (animated) {
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            [self _updateVisibility];
            [self layoutIfNeeded];
        } completion:nil];
    } else {
        [self _updateVisibility];
    }
}

- (void)_updateVisibility {
    // When expanded, show more details; collapsed shows summary
    CGFloat alpha = _isExpanded ? 1.0 : 0.0;
    for (UIView *arrangedView in _devicesStackView.arrangedSubviews) {
        arrangedView.alpha = alpha;
    }
    _noDevicesLabel.alpha = alpha;
}

#pragma mark - Auto Refresh

- (void)startAutoRefresh {
    [self refreshBatteryData];
}

- (void)stopAutoRefresh {
    // No ongoing timer to stop currently
}

#pragma mark - Device Row Creation

- (UIView *)_createDeviceRowForDevice:(JadeBatteryDevice *)device {
    if (!device) return nil;

    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor clearColor];

    // Glyph image view
    UIImageView *glyphImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    glyphImageView.translatesAutoresizingMaskIntoConstraints = NO;
    glyphImageView.contentMode = UIViewContentModeScaleAspectFit;
    glyphImageView.image = device.deviceIcon;
    glyphImageView.tintColor = _moduleTintColor;
    [row addSubview:glyphImageView];

    // Device name label
    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    nameLabel.text = device.name;
    [row addSubview:nameLabel];

    // Percentage label
    UILabel *percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    percentLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    percentLabel.textColor = [UIColor whiteColor];
    percentLabel.textAlignment = NSTextAlignmentRight;
    percentLabel.text = device.batteryLevelString;
    [row addSubview:percentLabel];

    // Charging indicator
    UIImageView *chargingImageView = nil;
    if (device.isCharging) {
        chargingImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        chargingImageView.translatesAutoresizingMaskIntoConstraints = NO;
        chargingImageView.contentMode = UIViewContentModeScaleAspectFit;
        chargingImageView.image = [UIImage systemImageNamed:@"bolt.fill"];
        chargingImageView.tintColor = [UIColor systemGreenColor];
        [row addSubview:chargingImageView];
    }

    // Constraints
    NSMutableArray *constraints = [NSMutableArray array];
    [constraints addObjectsFromArray:@[
        [glyphImageView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:8],
        [glyphImageView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [glyphImageView.widthAnchor constraintEqualToConstant:20],
        [glyphImageView.heightAnchor constraintEqualToConstant:20],

        [nameLabel.leadingAnchor constraintEqualToAnchor:glyphImageView.trailingAnchor constant:8],
        [nameLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [percentLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-8],
        [percentLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [percentLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:nameLabel.trailingAnchor constant:8],

        [row.heightAnchor constraintEqualToConstant:36],
    ]];

    if (chargingImageView) {
        [constraints addObjectsFromArray:@[
            [chargingImageView.trailingAnchor constraintEqualToAnchor:percentLabel.leadingAnchor constant:-4],
            [chargingImageView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [chargingImageView.widthAnchor constraintEqualToConstant:14],
            [chargingImageView.heightAnchor constraintEqualToConstant:14],
        ]];
    }

    [NSLayoutConstraint activateConstraints:constraints];

    return row;
}

#pragma mark - Mapping Helpers

- (JadeBatteryDeviceType)_deviceTypeForVendor:(long long)vendor name:(NSString *)name {
    NSString *lowercaseName = [name lowercaseString];

    // Map BCBatteryDevice vendor values to Jade device types
    switch (vendor) {
        case 1: // Apple
            if ([lowercaseName containsString:@"watch"]) return JadeBatteryDeviceTypeAppleWatch;
            if ([lowercaseName containsString:@"airpods pro"]) return JadeBatteryDeviceTypeAirPodsPro;
            if ([lowercaseName containsString:@"airpods max"]) return JadeBatteryDeviceTypeAirPodsMax;
            if ([lowercaseName containsString:@"airpods"]) return JadeBatteryDeviceTypeAirPods;
            if ([lowercaseName containsString:@"airtag"]) return JadeBatteryDeviceTypeAirTag;
            if ([lowercaseName containsString:@"iphone"]) return JadeBatteryDeviceTypeiPhone;
            return JadeBatteryDeviceTypeUnknown;
        case 2: // Beats
            return JadeBatteryDeviceTypeBeats;
        default:
            // Fall back to name-based inference
            if ([lowercaseName containsString:@"watch"]) return JadeBatteryDeviceTypeAppleWatch;
            if ([lowercaseName containsString:@"airpods"]) return JadeBatteryDeviceTypeAirPods;
            if ([lowercaseName containsString:@"beats"]) return JadeBatteryDeviceTypeBeats;
            return JadeBatteryDeviceTypeUnknown;
    }
}

- (UIImage *)_iconForDevice:(id)device {
    UIImage *icon = JadeObjectValue(device, @selector(icon));
    if (![icon isKindOfClass:[UIImage class]]) {
        icon = JadeObjectValue(device, @selector(glyph));
    }
    if ([icon isKindOfClass:[UIImage class]]) return icon;

    // Fall back to SF Symbol
    NSString *symbolName = @"questionmark.circle";
    NSString *name = JadeObjectValue(device, @selector(name));
    NSString *lowercaseName = [name lowercaseString] ?: @"";

    if ([lowercaseName containsString:@"watch"]) {
        symbolName = @"applewatch";
    } else if ([lowercaseName containsString:@"airpods pro"]) {
        symbolName = @"airpods.pro";
    } else if ([lowercaseName containsString:@"airpods max"]) {
        symbolName = @"airpods.max";
    } else if ([lowercaseName containsString:@"airpods"]) {
        symbolName = @"airpods";
    } else if ([lowercaseName containsString:@"beats"]) {
        symbolName = @"beats.headphones";
    } else if ([lowercaseName containsString:@"iphone"]) {
        symbolName = @"iphone";
    } else if ([lowercaseName containsString:@"airtag"]) {
        symbolName = @"airtag";
    }

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
    return [UIImage systemImageNamed:symbolName withConfiguration:config];
}

#pragma mark - Helper

- (UIColor *)_colorFromHexString:(NSString *)hexString {
    if (!hexString || hexString.length == 0) return nil;
    NSString *hex = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length < 6) return nil;

    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    [scanner scanHexInt:&rgbValue];

    CGFloat red = ((rgbValue & 0xFF0000) >> 16) / 255.0;
    CGFloat green = ((rgbValue & 0x00FF00) >> 8) / 255.0;
    CGFloat blue = (rgbValue & 0x0000FF) / 255.0;
    CGFloat alpha = 1.0;
    if (hex.length >= 8) {
        alpha = ((rgbValue & 0xFF000000) >> 24) / 255.0;
    }

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

#pragma mark - Cleanup

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:JadeBatteryDevicesDidChangeNotification object:nil];
}

@end
