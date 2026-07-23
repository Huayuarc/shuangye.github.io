#import "CPUthermalHelper.h"

// ============================================================
// CommonProduct - Force nominal thermal mode, block throttling
// ============================================================
%hook CommonProduct

- (id)initProduct:(id)arg1 {
    id res = %orig(arg1);
    [CPUthermalHelper.shared setCommonProductObject:self];
    [self putDeviceInThermalSimulationMode:@"nominal"];
    return res;
}

- (void)tryTakeAction {}
- (void)simulateLightThermalPressure {}
- (void)updatePowerzoneTelemetry {}

%end

// ============================================================
// HidSensors - Block temperature events
// ============================================================
%hook HidSensors

- (void)handleTemperatureEvent:(int)arg1 service:(id)arg2 {}

%end

// ============================================================
// NSDictionary - Patch thermal plist configuration
// ============================================================
%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(id)path {
    id res = %orig(path);
    if ([path containsString:@"/System/Library/ThermalMonitor/"]) {
        if ([res isKindOfClass:[NSDictionary class]]) {
            CFDictionaryRef patched = [CPUthermalHelper.shared patchThermalPlist:(__bridge CFDictionaryRef)res];
            return (__bridge id)patched;
        }
    }
    return res;
}

%end

// ============================================================
// Darwin notification callback for puppet event
// ============================================================
static void puppetEventCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [CPUthermalHelper.shared executePuppetEvent];
}

%ctor {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        puppetEventCallback,
        CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
