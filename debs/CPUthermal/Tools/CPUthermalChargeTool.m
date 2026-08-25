#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

static BOOL gLimited = NO;
static BOOL gWasEnabled = NO;
static int gNotifyToken = 0;

static io_service_t BatteryService(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL) service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    return service;
}

static NSDictionary *BatteryProperties(io_service_t service) {
    if (service == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef properties = NULL;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties) return nil;
    return CFBridgingRelease(properties);
}

static BOOL AdapterConnected(NSDictionary *properties) {
    NSDictionary *adapter = [properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]] ? properties[S("AdapterDetails")] : nil;
    NSString *description = [adapter[S("Description")] isKindOfClass:[NSString class]] ? adapter[S("Description")] : nil;
    if (adapter.count && ![description isEqualToString:S("batt")]) return YES;
    return [properties[S("ExternalChargeCapable")] boolValue] || [properties[S("ExternalConnected")] boolValue];
}

static int SetSmartBatteryState(BOOL charging, BOOL inflow) {
    io_service_t service = BatteryService();
    if (service == IO_OBJECT_NULL) return 1;
    NSDictionary *values = @{
        S("IsCharging"): @YES,
        S("PredictiveChargingInhibit"): @(!charging),
        S("ExternalConnected"): @(inflow)
    };
    kern_return_t result = IORegistryEntrySetCFProperties(service, (__bridge CFTypeRef)values);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? 0 : 2;
}

static void RestoreCharging(void) {
    SetSmartBatteryState(YES, YES);
    gLimited = NO;
}

static NSInteger IntegerPreference(NSDictionary *prefs, NSString *key, NSInteger fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void EvaluateBattery(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL enabled = [prefs[S("smartChargeEnabled")] boolValue];
    NSInteger stopLevel = IntegerPreference(prefs, S("smartChargeStopLevel"), 80);
    NSInteger resumeLevel = IntegerPreference(prefs, S("smartChargeResumeLevel"), 75);
    stopLevel = MAX(50, MIN(100, stopLevel));
    resumeLevel = MAX(5, MIN(stopLevel - 1, resumeLevel));

    if (!enabled) {
        if (gLimited || gWasEnabled) RestoreCharging();
        gWasEnabled = NO;
        return;
    }
    gWasEnabled = YES;

    io_service_t service = BatteryService();
    NSDictionary *properties = BatteryProperties(service);
    if (service != IO_OBJECT_NULL) IOObjectRelease(service);
    if (!properties) return;

    NSInteger capacity = IntegerPreference(properties, S("CurrentCapacity"), -1);
    if (capacity < 0) return;
    BOOL connected = AdapterConnected(properties) || gLimited;

    if (capacity >= stopLevel && connected) {
        // 与 ChargeLimiter 一致：先用 PredictiveChargingInhibit 停充，再把 ExternalConnected 置否禁流。
        SetSmartBatteryState(NO, NO);
        gLimited = YES;
    } else if (gLimited && capacity <= resumeLevel) {
        // 回落到恢复阈值后同时恢复输入电流和充电。
        RestoreCharging();
    }
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    RestoreCharging();
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return RestoreCharging(), 0;
        signal(SIGTERM, SignalHandler);
        signal(SIGINT, SignalHandler);
        signal(SIGHUP, SignalHandler);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            EvaluateBattery();
        });
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
            EvaluateBattery();
        }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
