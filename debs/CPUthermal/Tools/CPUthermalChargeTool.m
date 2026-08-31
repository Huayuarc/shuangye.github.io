#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

// 单一职责：仅实现 SmartBatteryAPI 智能停充。
// 只写 PredictiveChargingInhibit，不修改温度、电流、ExternalConnected、
// IsCharging、ChargingOverride、OBC 或充电等待时间。
static BOOL gOwnsInhibit = NO;
static int gNotifyToken = 0;

static BOOL PersistedOwnership(void) {
    return [CPUthermalReadPrefs()[S("__smartChargeOwnsInhibit")] boolValue];
}

static void SetPersistedOwnership(BOOL owns) {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs() ?: [NSMutableDictionary dictionary];
    if (owns) prefs[S("__smartChargeOwnsInhibit")] = [NSNumber numberWithBool:YES];
    else [prefs removeObjectForKey:S("__smartChargeOwnsInhibit")];
    CPUthermalWritePrefs(prefs);
    gOwnsInhibit = owns;
}

static io_service_t BatteryService(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    return service;
}

static NSDictionary *BatteryProperties(io_service_t service) {
    if (service == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef properties = NULL;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties)
        return nil;
    return CFBridgingRelease(properties);
}

static NSInteger IntegerPreference(NSDictionary *dictionary, NSString *key, NSInteger fallback) {
    id value = dictionary[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static BOOL AdapterConnected(NSDictionary *properties) {
    NSDictionary *adapter = [properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]]
        ? properties[S("AdapterDetails")] : nil;
    NSString *description = [adapter[S("Description")] isKindOfClass:[NSString class]]
        ? adapter[S("Description")] : nil;
    if (adapter.count && ![description isEqualToString:S("batt")]) return YES;
    return [properties[S("ExternalConnected")] boolValue] || [properties[S("ExternalChargeCapable")] boolValue];
}

static BOOL SetChargingInhibited(BOOL inhibited) {
    io_service_t service = BatteryService();
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t result = IORegistryEntrySetCFProperty(service, CFSTR("PredictiveChargingInhibit"),
                                                        inhibited ? kCFBooleanTrue : kCFBooleanFalse);
    IOObjectRelease(service);
    if (result == KERN_SUCCESS) SetPersistedOwnership(inhibited);
    return result == KERN_SUCCESS;
}

static void EvaluateBattery(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL enabled = [prefs[S("smartChargeEnabled")] boolValue];
    if (!enabled && !gOwnsInhibit) return;

    io_service_t service = BatteryService();
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { if (service != IO_OBJECT_NULL) IOObjectRelease(service); return; }

    if (!enabled) {
        if (gOwnsInhibit) SetChargingInhibited(NO);
        IOObjectRelease(service);
        return;
    }

    NSInteger stopLevel = MAX(70, MIN(100, IntegerPreference(prefs, S("smartChargeStopLevel"), 80)));
    NSInteger resumeLevel = MAX(5, stopLevel - 5);
    NSInteger capacity = IntegerPreference(properties, S("CurrentCapacity"), -1);
    BOOL connected = AdapterConnected(properties);

    if (capacity >= 0 && connected) {
        if (capacity >= stopLevel && !gOwnsInhibit) SetChargingInhibited(YES);
        else if (capacity <= resumeLevel && gOwnsInhibit) SetChargingInhibited(NO);
    }
    IOObjectRelease(service);
}

static BOOL ResetCharging(void) {
    if (!gOwnsInhibit) return YES;
    return SetChargingInhibited(NO);
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    ResetCharging();
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        gOwnsInhibit = PersistedOwnership();
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;
        signal(SIGTERM, SignalHandler);
        signal(SIGINT, SignalHandler);
        signal(SIGHUP, SignalHandler);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            @autoreleasepool { EvaluateBattery(); }
        });
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateBattery(); }
        }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
