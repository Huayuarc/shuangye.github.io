#import "include/CPUthermalHelper.h"
#include <CPUthermalPaths.h>

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
        _thermalPreventDimmingEnabled = YES;
    }
    return self;
}

- (void)reloadPrefs {
    NSDictionary *plist = CPUthermalReadPrefs();
    self.thermalPreventDimmingEnabled = [plist[S("thermalPreventDimmingEnabled")] ?: [NSNumber numberWithBool:YES] boolValue];
}

- (CFDictionaryRef)patchThermalPlist:(CFDictionaryRef)cfDict {
    NSMutableDictionary *dict = [(__bridge NSDictionary *)cfDict mutableCopy];

    if (self.thermalPreventDimmingEnabled) {
        // Patch backlight component control — 阻止系统因温控调暗屏幕
        NSDictionary *backlight = dict[S("backlightComponentControl")];
        if ([backlight isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *mutableBacklight = [backlight mutableCopy];

            // BacklightBrightness — 将所有值设为第一个值（保持当前亮度）
            NSArray *brightnessArr = mutableBacklight[S("BacklightBrightness")];
            if ([brightnessArr isKindOfClass:[NSArray class]] && brightnessArr.count > 1) {
                NSMutableArray *newBrightness = [brightnessArr mutableCopy];
                id firstVal = newBrightness[0];
                for (NSUInteger i = 1; i < newBrightness.count; i++) {
                    newBrightness[i] = firstVal;
                }
                mutableBacklight[S("BacklightBrightness")] = newBrightness;
            }

            // BacklightPower — 将所有值设为第一个值
            NSArray *powerArr = mutableBacklight[S("BacklightPower")];
            if ([powerArr isKindOfClass:[NSArray class]] && powerArr.count > 1) {
                NSMutableArray *newPower = [powerArr mutableCopy];
                id firstVal = newPower[0];
                for (NSUInteger i = 1; i < newPower.count; i++) {
                    newPower[i] = firstVal;
                }
                mutableBacklight[S("BacklightPower")] = newPower;
            }

            mutableBacklight[S("expectsCPMSSupport")] = @(0);
            dict[S("backlightComponentControl")] = mutableBacklight;
        }
    }

    return (__bridge CFDictionaryRef)dict;
}

@end
