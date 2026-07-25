#import "CPUthermalHelper.h"

@implementation CPUthermalHelper

+ (instancetype)shared {
    static CPUthermalHelper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _plistObj = @{};
    }
    return self;
}

- (int)getCPUMaxPower {
    if (self.plistObj.count == 0) {
        [self getLocalPrefValue];
    }
    NSString *powerValue = self.plistObj[@"cpuMinPowerValue"] ?: @"";
    return [powerValue intValue];
}

- (void)getLocalPrefValue {
    NSString *path = rootlessPath(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist");
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    self.plistObj = plist ?: @{};
}

- (void)executePuppetEvent {
    [self getLocalPrefValue];
    NSString *eventType = self.plistObj[@"thermalPuppetValue"] ?: @"";
    if (eventType.length > 0) {
        [self.commonProductObject putDeviceInThermalSimulationMode:eventType];
    }
}

- (CFDictionaryRef)patchThermalPlist:(CFDictionaryRef)cfDict {
    NSMutableDictionary *dict = [(__bridge NSDictionary *)cfDict mutableCopy];

    // Patch backlight component control
    NSDictionary *backlight = dict[@"backlightComponentControl"];
    if ([backlight isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutableBacklight = [backlight mutableCopy];

        // Fix BacklightBrightness - set all entries to first value
        NSArray *brightnessArr = mutableBacklight[@"BacklightBrightness"];
        if ([brightnessArr isKindOfClass:[NSArray class]] && brightnessArr.count > 1) {
            NSMutableArray *newBrightness = [brightnessArr mutableCopy];
            id firstVal = newBrightness[0];
            for (NSUInteger i = 1; i < newBrightness.count; i++) {
                newBrightness[i] = firstVal;
            }
            mutableBacklight[@"BacklightBrightness"] = newBrightness;
        }

        // Fix BacklightPower - set all entries to first value
        NSArray *powerArr = mutableBacklight[@"BacklightPower"];
        if ([powerArr isKindOfClass:[NSArray class]] && powerArr.count > 1) {
            NSMutableArray *newPower = [powerArr mutableCopy];
            id firstVal = newPower[0];
            for (NSUInteger i = 1; i < newPower.count; i++) {
                newPower[i] = firstVal;
            }
            mutableBacklight[@"BacklightPower"] = newPower;
        }

        mutableBacklight[@"expectsCPMSSupport"] = @(0);

        int powerValue = [self getCPUMaxPower];
        if (powerValue > 0) {
            mutableBacklight[@"maxThermalPower"] = @(powerValue);
            mutableBacklight[@"minThermalPower"] = @(powerValue);
        }

        dict[@"backlightComponentControl"] = mutableBacklight;
    }

    return (__bridge CFDictionaryRef)dict;
}

@end
