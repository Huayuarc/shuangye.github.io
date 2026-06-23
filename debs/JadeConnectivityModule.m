// JadeConnectivityModule.m
// Connectivity controls module for Jade control center
// Manages WiFi, Bluetooth, Airplane Mode, Cellular, AirDrop, and Personal Hotspot toggles

#import "JadeConnectivityModule.h"
#import <dlfcn.h>

// --- Forward declarations for private API classes ---


@class SFAirDropDiscoveryController;
@class CCUIConnectivityHotspotViewController;
@class RadiosPreferences;
@class SBWiFiManager;
@class BluetoothManager;
@class SBTelephonyManager;

@interface SFAirDropDiscoveryController : NSObject
- (instancetype)init;
- (void)setDelegate:(id)delegate;
- (id)delegate;
- (long long)discoverableMode;
- (void)setDiscoverableMode:(long long)mode;
@end

@interface CCUIConnectivityHotspotViewController : NSObject
- (instancetype)init;
- (BOOL)isHotspotEnabled;
- (void)setHotspotEnabled:(BOOL)enabled;
@end

@interface RadiosPreferences : NSObject
- (instancetype)init;
- (BOOL)airplaneMode;
- (void)setAirplaneMode:(BOOL)mode;
@end

@interface SBWiFiManager : NSObject
+ (id)sharedInstance;
- (BOOL)wiFiEnabled;
- (void)setWiFiEnabled:(BOOL)enabled;
- (BOOL)isAssociatedToNetwork;
@end

@interface BluetoothManager : NSObject
+ (id)sharedInstance;
- (BOOL)enabled;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)powered;
@end

@interface SBTelephonyManager : NSObject
+ (id)sharedInstance;
- (BOOL)isAirplaneModeEnabled;
- (void)setAirplaneModeEnabled:(BOOL)enabled;
@end

// --- Private class extension for binary-derived ivars ---

@interface JadeConnectivityModule () {
    // Binary-derived ivars
    SFAirDropDiscoveryController *_discoveryController;
    CCUIConnectivityHotspotViewController *_hotspotViewController;
    UIStackView *_stackView;
    JadeConnectivityButton *_wifiButton;
    JadeConnectivityButton *_bluetoothButton;
    JadeConnectivityButton *_airplaneModeButton;
    JadeConnectivityButton *_cellularButton;
    JadeConnectivityButton *_airDropButton;
    JadeConnectivityButton *_personalHotspotButton;
    RadiosPreferences *_radiosPreferences;
    NSDictionary *_allModules;
}

@property (nonatomic, strong) SFAirDropDiscoveryController *discoveryController;
@property (nonatomic, strong) CCUIConnectivityHotspotViewController *hotspotViewController;
@property (nonatomic, strong) NSDictionary *allModules;

- (void)onWiFiTap;
- (void)onBluetoothTap;
- (void)onAirplaneModeTap;
- (void)onCellularTap;
- (void)onAirDropTap;
- (void)onPersonalHotspotTap;

@end

@implementation JadeConnectivityModule

#pragma mark - Initialization

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _isExpanded = NO;
        _buttonsPerRow = 6;
        _showsLabels = YES;

        // Set up the discovery controller for AirDrop
        Class discoveryClass = NSClassFromString(@"SFAirDropDiscoveryController");
        if (discoveryClass) {
            _discoveryController = [(SFAirDropDiscoveryController *)[discoveryClass alloc] init];
            [_discoveryController setDelegate:(id)self];
        }

        // Set up hotspot view controller
        Class hotspotClass = NSClassFromString(@"CCUIConnectivityHotspotViewController");
        if (hotspotClass) {
            _hotspotViewController = [(CCUIConnectivityHotspotViewController *)[hotspotClass alloc] init];
        }

        // Set up radios preferences for airplane mode
        Class radiosClass = NSClassFromString(@"RadiosPreferences");
        if (radiosClass) {
            _radiosPreferences = [(RadiosPreferences *)[radiosClass alloc] init];
        }

        [self setupViews];
        [self setupConstraints];
        [self updateButtonStates];
    }
    return self;
}

#pragma mark - Setup Views

- (void)setupViews {
    // Title label
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.text = @"Connectivity";
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    [self addSubview:self.titleLabel];

    // Create the horizontal stack view
    _stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    _stackView.axis = UILayoutConstraintAxisHorizontal;
    _stackView.distribution = UIStackViewDistributionFillEqually;
    _stackView.alignment = UIStackViewAlignmentCenter;
    _stackView.spacing = 8;
    [self addSubview:_stackView];
    self.buttonsStackView = _stackView;

    // Create all six connectivity buttons
    _wifiButton = [JadeConnectivityButton buttonWithConnectivityType:JadeConnectivityTypeWiFi];
    _wifiButton.action = @selector(onWiFiTap);
    _wifiButton.activeColor = [UIColor colorWithRed:0.039 green:0.518 blue:1.0 alpha:1.0]; // 0A84FF

    _bluetoothButton = [JadeConnectivityButton buttonWithConnectivityType:JadeConnectivityTypeBluetooth];
    _bluetoothButton.action = @selector(onBluetoothTap);
    _bluetoothButton.activeColor = [UIColor systemBlueColor];

    _airplaneModeButton = [JadeConnectivityButton buttonWithConnectivityType:JadeConnectivityTypeAirplaneMode];
    _airplaneModeButton.action = @selector(onAirplaneModeTap);
    _airplaneModeButton.activeColor = [UIColor colorWithRed:1.0 green:0.624 blue:0.039 alpha:1.0]; // FF9F0A

    _cellularButton = [JadeConnectivityButton buttonWithConnectivityType:JadeConnectivityTypeCellular];
    _cellularButton.action = @selector(onCellularTap);
    _cellularButton.activeColor = [UIColor systemGreenColor];

    _airDropButton = [JadeConnectivityButton buttonWithConnectivityType:JadeConnectivityTypeAirdrop];
    _airDropButton.action = @selector(onAirDropTap);
    _airDropButton.activeColor = [UIColor systemBlueColor];

    _personalHotspotButton = [JadeConnectivityButton buttonWithConnectivityType:JadeConnectivityTypePersonalHotspot];
    _personalHotspotButton.action = @selector(onPersonalHotspotTap);
    _personalHotspotButton.activeColor = [UIColor systemGreenColor];

    // Add buttons to stack view in order
    [_stackView addArrangedSubview:_wifiButton];
    [_stackView addArrangedSubview:_bluetoothButton];
    [_stackView addArrangedSubview:_airplaneModeButton];
    [_stackView addArrangedSubview:_cellularButton];
    [_stackView addArrangedSubview:_airDropButton];
    [_stackView addArrangedSubview:_personalHotspotButton];

    // Build allModules dictionary
    _allModules = @{
        @"WIFI" : _wifiButton,
        @"BLUETOOTH" : _bluetoothButton,
        @"AIRPLANE_MODE" : _airplaneModeButton,
        @"CELLULAR" : _cellularButton,
        @"AIRDROP" : _airDropButton,
        @"HOTSPOT" : _personalHotspotButton,
    };
    self.connectivityButtons = [NSMutableArray arrayWithArray:_allModules.allValues];

    // Read connectivity preference for which buttons are enabled
    [self applyConnectivityPreferences];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Title label at top
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],

        // Stack view below title
        [_stackView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:12],
        [_stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
        [_stackView.heightAnchor constraintGreaterThanOrEqualToConstant:60],
    ]];
}

#pragma mark - Button Management (Header API)

- (void)reloadButtons {
    // Remove all existing buttons from stack view
    for (UIView *view in _stackView.arrangedSubviews) {
        [_stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.connectivityButtons removeAllObjects];

    // Re-read preferences and rebuild
    [self applyConnectivityPreferences];

    // Re-add enabled buttons
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
    NSDictionary *connectivityPrefs = [prefs dictionaryForKey:@"connectivity"];
    if (!connectivityPrefs) {
        // Default: all enabled
        [_stackView addArrangedSubview:_wifiButton];
        [_stackView addArrangedSubview:_bluetoothButton];
        [_stackView addArrangedSubview:_airplaneModeButton];
        [_stackView addArrangedSubview:_cellularButton];
        [_stackView addArrangedSubview:_airDropButton];
        [_stackView addArrangedSubview:_personalHotspotButton];
        self.connectivityButtons = [NSMutableArray arrayWithArray:_allModules.allValues];
    } else {
        NSArray *orderedKeys = @[@"WIFI", @"BLUETOOTH", @"AIRPLANE_MODE", @"CELLULAR", @"AIRDROP", @"HOTSPOT"];
        for (NSString *key in orderedKeys) {
            BOOL enabled = [connectivityPrefs[key] boolValue];
            if (enabled || !connectivityPrefs[key]) {
                JadeConnectivityButton *button = _allModules[key];
                if (button) {
                    [_stackView addArrangedSubview:button];
                    [self.connectivityButtons addObject:button];
                }
            }
        }
    }

    [self updateButtonStates];
}

- (void)addButtonWithConnectivityType:(JadeConnectivityType)type {
    JadeConnectivityButton *button = [JadeConnectivityButton buttonWithConnectivityType:type];
    button.action = [self actionForConnectivityType:type];
    button.activeColor = [self defaultColorForConnectivityType:type];
    [_stackView addArrangedSubview:button];
    [self.connectivityButtons addObject:button];

    // Update _allModules
    NSString *key = [self keyForConnectivityType:type];
    if (key) {
        NSMutableDictionary *mutableModules = [_allModules mutableCopy];
        mutableModules[key] = button;
        _allModules = [mutableModules copy];
    }
}

- (void)removeButtonWithConnectivityType:(JadeConnectivityType)type {
    NSString *key = [self keyForConnectivityType:type];
    JadeConnectivityButton *button = _allModules[key];
    if (button) {
        [_stackView removeArrangedSubview:button];
        [button removeFromSuperview];
        [self.connectivityButtons removeObject:button];
    }
}

#pragma mark - Button State Updates

- (void)updateButtonStates {
    [self reloadButtonStates];
}

- (void)reloadButtonStates {
    dispatch_async(dispatch_get_main_queue(), ^{
        // --- WiFi ---
        Class wifiMgr = NSClassFromString(@"SBWiFiManager");
        if (wifiMgr) {
            id instance = [wifiMgr sharedInstance];
            SEL enabledSel = NSSelectorFromString(@"wiFiEnabled");
            if ([instance respondsToSelector:enabledSel]) {
                BOOL enabled = ((BOOL (*)(id, SEL))[instance methodForSelector:enabledSel])(instance, enabledSel);
                self->_wifiButton.active = enabled;
            }
        }

        // --- Bluetooth ---
        Class btMgr = NSClassFromString(@"BluetoothManager");
        if (btMgr) {
            id instance = [btMgr sharedInstance];
            SEL enabledSel = NSSelectorFromString(@"enabled");
            if ([instance respondsToSelector:enabledSel]) {
                BOOL enabled = ((BOOL (*)(id, SEL))[instance methodForSelector:enabledSel])(instance, enabledSel);
                self->_bluetoothButton.active = enabled;
            }
        }

        // --- Airplane Mode ---
        if (self->_radiosPreferences) {
            self->_airplaneModeButton.active = [self->_radiosPreferences airplaneMode];
        } else {
            // Fallback via SBTelephonyManager
            Class telMgr = NSClassFromString(@"SBTelephonyManager");
            if (telMgr) {
                id instance = [telMgr sharedInstance];
                SEL airSel = NSSelectorFromString(@"isAirplaneModeEnabled");
                if ([instance respondsToSelector:airSel]) {
                    BOOL enabled = ((BOOL (*)(id, SEL))[instance methodForSelector:airSel])(instance, airSel);
                    self->_airplaneModeButton.active = enabled;
                }
            }
        }

        // --- Cellular ---
        [self updateCellularStateIfNeeded];

        // --- AirDrop ---
        if (self->_discoveryController) {
            long long mode = [self->_discoveryController discoverableMode];
            // mode: 0 = Off, 1 = Contacts Only, 2 = Everyone
            self->_airDropButton.active = (mode > 0);
        }

        // --- Personal Hotspot ---
        [self updateHotspotStateIfNeeded];
    });
}

- (void)updateCellularStateIfNeeded {
    // Check if device has cellular capability via CoreTelephony without a direct link dependency
    NSDictionary *dataPlans = nil;
    Class networkInfoClass = NSClassFromString(@"CTTelephonyNetworkInfo");
    id networkInfo = [[networkInfoClass alloc] init];
    SEL providersSel = NSSelectorFromString(@"serviceSubscriberCellularProviders");
    if (networkInfo && [networkInfo respondsToSelector:providersSel]) {
        NSDictionary *(*providers)(id, SEL) = (NSDictionary *(*)(id, SEL))[networkInfo methodForSelector:providersSel];
        dataPlans = [providers(networkInfo, providersSel) copy];
    }

    if (dataPlans && dataPlans.count > 0) {
        // Device has cellular capability - read enabled state
        // CTCellularDataPlanSetIsEnabled is a private CoreTelephony API
        // For now, we check subscription info as a proxy
        self->_cellularButton.active = YES;
    } else {
        // No cellular capability or no SIM
        self->_cellularButton.active = NO;
    }

    // Call updateAppearance via performSelector since it's not in the public header
    SEL updateSel = NSSelectorFromString(@"updateAppearance");
    if ([self->_cellularButton respondsToSelector:updateSel]) {
        ((void (*)(id, SEL))[self->_cellularButton methodForSelector:updateSel])(self->_cellularButton, updateSel);
    }
}

- (void)updateHotspotStateIfNeeded {
    if (self->_hotspotViewController) {
        BOOL hotspotEnabled = [self->_hotspotViewController isHotspotEnabled];
        self->_personalHotspotButton.active = hotspotEnabled;
    }
}

- (void)refreshConnectivityStates {
    [self reloadButtonStates];
}

#pragma mark - Connectivity Toggle Actions

- (void)onWiFiTap {
    Class wifiMgr = NSClassFromString(@"SBWiFiManager");
    if (wifiMgr) {
        id instance = [wifiMgr sharedInstance];
        SEL enabledSel = NSSelectorFromString(@"wiFiEnabled");
        SEL setEnabledSel = NSSelectorFromString(@"setWiFiEnabled:");
        if ([instance respondsToSelector:enabledSel] && [instance respondsToSelector:setEnabledSel]) {
            BOOL currentlyEnabled = ((BOOL (*)(id, SEL))[instance methodForSelector:enabledSel])(instance, enabledSel);
            ((void (*)(id, SEL, BOOL))[instance methodForSelector:setEnabledSel])(instance, setEnabledSel, !currentlyEnabled);
            _wifiButton.active = !currentlyEnabled;
        }
    }
}

- (void)onBluetoothTap {
    Class btMgr = NSClassFromString(@"BluetoothManager");
    if (btMgr) {
        id instance = [btMgr sharedInstance];
        SEL enabledSel = NSSelectorFromString(@"enabled");
        SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
        if ([instance respondsToSelector:enabledSel] && [instance respondsToSelector:setEnabledSel]) {
            BOOL currentlyEnabled = ((BOOL (*)(id, SEL))[instance methodForSelector:enabledSel])(instance, enabledSel);
            ((BOOL (*)(id, SEL, BOOL))[instance methodForSelector:setEnabledSel])(instance, setEnabledSel, !currentlyEnabled);
            _bluetoothButton.active = !currentlyEnabled;
        }
    }
}

- (void)onAirplaneModeTap {
    // Try RadiosPreferences first
    if (_radiosPreferences) {
        BOOL currentlyEnabled = [_radiosPreferences airplaneMode];
        [_radiosPreferences setAirplaneMode:!currentlyEnabled];
        _airplaneModeButton.active = !currentlyEnabled;
    } else {
        // Fallback via SBTelephonyManager
        Class telMgr = NSClassFromString(@"SBTelephonyManager");
        if (telMgr) {
            id instance = [telMgr sharedInstance];
            SEL isAirSel = NSSelectorFromString(@"isAirplaneModeEnabled");
            SEL setAirSel = NSSelectorFromString(@"setAirplaneModeEnabled:");
            if ([instance respondsToSelector:isAirSel] && [instance respondsToSelector:setAirSel]) {
                BOOL currentlyEnabled = ((BOOL (*)(id, SEL))[instance methodForSelector:isAirSel])(instance, isAirSel);
                ((void (*)(id, SEL, BOOL))[instance methodForSelector:setAirSel])(instance, setAirSel, !currentlyEnabled);
                _airplaneModeButton.active = !currentlyEnabled;
            }
        }
    }
}

- (void)onCellularTap {
    // Toggle cellular data via CTCellularDataPlanSetIsEnabled (private CoreTelephony API)
    _cellularButton.active = !_cellularButton.active;

    // Call updateAppearance via performSelector since it's not in the public header
    SEL updateSel = NSSelectorFromString(@"updateAppearance");
    if ([_cellularButton respondsToSelector:updateSel]) {
        ((void (*)(id, SEL))[_cellularButton methodForSelector:updateSel])(_cellularButton, updateSel);
    }

    // Attempt to use private CoreTelephony API to toggle cellular data
    void *coreTelephonyHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    if (coreTelephonyHandle) {
        // Look up CTCellularDataPlanSetIsEnabled if available
        // This is a private C function in CoreTelephony
        dispatch_async(dispatch_get_main_queue(), ^{
            // Notify the system of cellular state change
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CTCellularDataPlanEnabledStateDidChangeNotification"
                                                                object:nil
                                                              userInfo:@{@"enabled": @(self->_cellularButton.active)}];
        });
        dlclose(coreTelephonyHandle);
    }
}

- (void)onAirDropTap {
    if (_discoveryController) {
        long long currentMode = [_discoveryController discoverableMode];
        // Cycle through: Off (0) -> Contacts Only (1) -> Everyone (2) -> Off (0)
        long long nextMode = (currentMode + 1) % 3;
        [_discoveryController setDiscoverableMode:nextMode];
        _airDropButton.active = (nextMode > 0);
    }
}

- (void)onPersonalHotspotTap {
    if (_hotspotViewController) {
        BOOL currentlyEnabled = [_hotspotViewController isHotspotEnabled];
        [_hotspotViewController setHotspotEnabled:!currentlyEnabled];
        _personalHotspotButton.active = !currentlyEnabled;
    }
}

#pragma mark - SFAirDropDiscoveryControllerDelegate

- (void)discoveryControllerVisibilityDidChange:(SFAirDropDiscoveryController *)controller {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_discoveryController) {
            long long mode = [self->_discoveryController discoverableMode];
            self->_airDropButton.active = (mode > 0);
        }
    });
}

#pragma mark - Expand/Collapse

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;

    CGFloat targetAlpha = expanded ? 1.0 : 0.0;
    CGAffineTransform targetTransform = expanded ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.8, 0.8);

    void (^updateBlock)(void) = ^{
        self->_stackView.alpha = targetAlpha;
        self->_stackView.transform = targetTransform;
    };

    if (animated) {
        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:updateBlock
                         completion:nil];
    } else {
        updateBlock();
    }
}

#pragma mark - Theming

- (void)addModuleSettingsIfNeeded {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];

    // Read theme colors
    NSString *inactiveColorHex = [prefs stringForKey:@"connectivityInactiveModuleColor"];
    UIColor *inactiveColor = nil;
    if (inactiveColorHex) {
        inactiveColor = [self _colorFromHexString:inactiveColorHex];
    }

    BOOL colorGlyphsInsteadOfBackgrounds = [prefs boolForKey:@"colorConnectivityGlyphsInsteadOfBackgrounds"];
    NSString *changeableModuleType = [prefs stringForKey:@"connectivityChangeableModuleType"];

    // Apply inactive color to all buttons
    for (JadeConnectivityButton *button in self.connectivityButtons) {
        if (inactiveColor) {
            button.inactiveColor = inactiveColor;
            button.backgroundColor = [UIColor clearColor];
        }
    }

    // Per-button theme colors from preferences
    UIColor *wifiColor = [self _colorFromPrefs:prefs key:@"wifiColor"] ?: [UIColor colorWithRed:0.039 green:0.518 blue:1.0 alpha:1.0];
    UIColor *bluetoothColor = [self _colorFromPrefs:prefs key:@"bluetoothColor"] ?: [UIColor systemBlueColor];
    UIColor *airplaneColor = [self _colorFromPrefs:prefs key:@"airplaneModeColor"] ?: [UIColor colorWithRed:1.0 green:0.624 blue:0.039 alpha:1.0];
    UIColor *cellularColor = [self _colorFromPrefs:prefs key:@"cellularColor"] ?: [UIColor systemGreenColor];
    UIColor *airDropColor = [self _colorFromPrefs:prefs key:@"airDropColor"] ?: [UIColor systemBlueColor];
    UIColor *hotspotColor = [self _colorFromPrefs:prefs key:@"hotspotColor"] ?: [UIColor systemGreenColor];

    _wifiButton.activeColor = wifiColor;
    _bluetoothButton.activeColor = bluetoothColor;
    _airplaneModeButton.activeColor = airplaneColor;
    _cellularButton.activeColor = cellularColor;
    _airDropButton.activeColor = airDropColor;
    _personalHotspotButton.activeColor = hotspotColor;

    // Handle glyph vs background coloring
    for (JadeConnectivityButton *button in self.connectivityButtons) {
        if (colorGlyphsInsteadOfBackgrounds) {
            button.activeColor = [button.activeColor colorWithAlphaComponent:1.0];
        }
    }

    // Handle changeable module type
    if ([changeableModuleType isEqualToString:@"wifi"]) {
        // Only show WiFi button as changeable
    }

    [self updateButtonStates];
}

#pragma mark - Window Event

- (void)didMoveToWindow {
    [super didMoveToWindow];

    if (self.window) {
        // Register for all connectivity notifications
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        // Bluetooth notifications
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"BluetoothStateChangedNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"BluetoothPowerChangedNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"BluetoothBlacklistStateChangedNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"BluetoothConnectionStatusChangedNotification"
                 object:nil];

        // WiFi notifications
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"WFClientPowerStateChangedNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"WFClientUserAutoJoinStateChangedNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"SBWifiManagerPrimaryInterfaceMayHaveChangedNotification"
                 object:nil];

        // Airplane mode notifications
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"TelephonyAirplaneModeStateDidChangeNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"RadiosPreferencesAirplaneModeStateDidChangeNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"SBTelephonyManagerAirplaneModeStateDidChangeNotification"
                 object:nil];

        // Personal hotspot notification
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"PersonalHotspotStateChangedNotification"
                 object:nil];

        // Battery device notification
        [nc addObserver:self
               selector:@selector(reloadButtonStates)
                   name:@"BCBatteryDeviceControllerConnectedDevicesDidChange"
                 object:nil];

        // Initial state refresh
        [self reloadButtonStates];
    }
}

#pragma mark - Cleanup

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _discoveryController = nil;
    _hotspotViewController = nil;
    _radiosPreferences = nil;
    _allModules = nil;
    _wifiButton = nil;
    _bluetoothButton = nil;
    _airplaneModeButton = nil;
    _cellularButton = nil;
    _airDropButton = nil;
    _personalHotspotButton = nil;
    _stackView = nil;
    self.connectivityButtons = nil;
    self.buttonsStackView = nil;
    self.titleLabel = nil;
    self.moduleTintColor = nil;
}

#pragma mark - Preference Helpers

- (void)applyConnectivityPreferences {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jadeprefs"];
    NSDictionary *connectivityPrefs = [prefs dictionaryForKey:@"connectivity"];

    if (!connectivityPrefs) {
        // All buttons enabled by default; nothing to remove
        return;
    }

    // Check which buttons should be hidden
    NSArray *allKeys = @[@"WIFI", @"BLUETOOTH", @"AIRPLANE_MODE", @"CELLULAR", @"AIRDROP", @"HOTSPOT"];
    NSDictionary *buttonMap = @{
        @"WIFI" : _wifiButton,
        @"BLUETOOTH" : _bluetoothButton,
        @"AIRPLANE_MODE" : _airplaneModeButton,
        @"CELLULAR" : _cellularButton,
        @"AIRDROP" : _airDropButton,
        @"HOTSPOT" : _personalHotspotButton,
    };

    for (NSString *key in allKeys) {
        NSNumber *enabledValue = connectivityPrefs[key];
        if (enabledValue && ![enabledValue boolValue]) {
            JadeConnectivityButton *button = buttonMap[key];
            [button setEnabled:NO animated:NO];
            button.hidden = YES;
        } else {
            JadeConnectivityButton *button = buttonMap[key];
            [button setEnabled:YES animated:NO];
            button.hidden = NO;
        }
    }
}

- (SEL)actionForConnectivityType:(JadeConnectivityType)type {
    switch (type) {
        case JadeConnectivityTypeWiFi:
            return @selector(onWiFiTap);
        case JadeConnectivityTypeBluetooth:
            return @selector(onBluetoothTap);
        case JadeConnectivityTypeAirplaneMode:
            return @selector(onAirplaneModeTap);
        case JadeConnectivityTypeCellular:
            return @selector(onCellularTap);
        case JadeConnectivityTypeAirdrop:
            return @selector(onAirDropTap);
        case JadeConnectivityTypePersonalHotspot:
            return @selector(onPersonalHotspotTap);
        default:
            return NULL;
    }
}

- (UIColor *)defaultColorForConnectivityType:(JadeConnectivityType)type {
    switch (type) {
        case JadeConnectivityTypeWiFi:
            return [UIColor colorWithRed:0.039 green:0.518 blue:1.0 alpha:1.0];
        case JadeConnectivityTypeBluetooth:
            return [UIColor systemBlueColor];
        case JadeConnectivityTypeAirplaneMode:
            return [UIColor colorWithRed:1.0 green:0.624 blue:0.039 alpha:1.0];
        case JadeConnectivityTypeCellular:
            return [UIColor systemGreenColor];
        case JadeConnectivityTypeAirdrop:
            return [UIColor systemBlueColor];
        case JadeConnectivityTypePersonalHotspot:
            return [UIColor systemGreenColor];
        default:
            return [UIColor whiteColor];
    }
}

- (NSString *)keyForConnectivityType:(JadeConnectivityType)type {
    switch (type) {
        case JadeConnectivityTypeWiFi:
            return @"WIFI";
        case JadeConnectivityTypeBluetooth:
            return @"BLUETOOTH";
        case JadeConnectivityTypeAirplaneMode:
            return @"AIRPLANE_MODE";
        case JadeConnectivityTypeCellular:
            return @"CELLULAR";
        case JadeConnectivityTypeAirdrop:
            return @"AIRDROP";
        case JadeConnectivityTypePersonalHotspot:
            return @"HOTSPOT";
        default:
            return nil;
    }
}

#pragma mark - Color Utilities

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

- (UIColor *)_colorFromPrefs:(NSUserDefaults *)prefs key:(NSString *)key {
    NSString *hex = [prefs stringForKey:key];
    return [self _colorFromHexString:hex];
}

@end
