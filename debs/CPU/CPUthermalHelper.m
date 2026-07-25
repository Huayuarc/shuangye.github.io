#import "CPUthermalHelper.h"
#import <spawn.h>
#import <signal.h>

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
    self.thermalPreventDimmingEnabled = [self.plistObj[@"thermalPreventDimmingEnabled"] boolValue];
    self.thermalFullPowerEnabled = [self.plistObj[@"thermalFullPowerEnabled"] boolValue];
    self.thermalLowPowerEnabled = [self.plistObj[@"thermalLowPowerEnabled"] boolValue];
}

- (void)reloadPrefs {
    [self getLocalPrefValue];
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

    // 防温控暗屏：根据用户偏好决定是否阻止系统因温控调暗屏幕
    if (self.thermalPreventDimmingEnabled) {
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
    }

    return (__bridge CFDictionaryRef)dict;
}

// ============================================================
// 重启用户空间
// ============================================================
+ (BOOL)userspaceReboot {
    // 查找 launchctl 路径
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *launchctlPath = nil;
    for (NSString *candidate in @[@"/sbin/launchctl", @"/bin/launchctl"]) {
        NSString *resolved = rootlessPath(candidate);
        if ([fm fileExistsAtPath:resolved]) {
            launchctlPath = resolved;
            break;
        }
    }
    if (!launchctlPath) return NO;

    const char *argv[] = {
        [launchctlPath UTF8String],
        "reboot",
        "userspace",
        NULL
    };

    pid_t pid;
    int ret = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
    if (ret != 0) return NO;

    // 异步等待子进程结束
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int status;
        waitpid(pid, &status, 0);
    });

    return YES;
}

@end
