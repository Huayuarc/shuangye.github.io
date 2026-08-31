#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

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

static BOOL AdapterPhysicallyConnected(NSDictionary *properties) {
    NSDictionary *adapter = [properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]] ? properties[S("AdapterDetails")] : nil;
    NSString *description = [adapter[S("Description")] isKindOfClass:[NSString class]] ? adapter[S("Description")] : nil;
    if (adapter.count && ![description isEqualToString:S("batt")]) return YES;
    return [properties[S("ExternalChargeCapable")] boolValue];
}

// 新状态机只写系统提供的充电抑制位。绝不持续伪造 IsCharging 或 ExternalConnected，
// 避免外接电源状态与真实适配器不一致后出现 0~数百 mA 涓流、显示充电却不涨电。
static BOOL SetChargingInhibited(BOOL inhibited) {
    io_service_t service = BatteryService();
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t result = IORegistryEntrySetCFProperty(service, CFSTR("PredictiveChargingInhibit"), inhibited ? kCFBooleanTrue : kCFBooleanFalse);
    IOObjectRelease(service);
    if (result == KERN_SUCCESS) CPUthermalPostSmartChargeCutoffState(inhibited);
    return result == KERN_SUCCESS;
}

// 仅用于修复 1.6.4-24~-29 可能遗留的 ExternalConnected=false。
// 只有硬件适配器信息明确存在且当前字段为 false 时才恢复一次，之后不再接管该字段。
static void RepairLegacyExternalConnectedIfNeeded(io_service_t service, NSDictionary *properties) {
    if (service == IO_OBJECT_NULL || !AdapterPhysicallyConnected(properties) || [properties[S("ExternalConnected")] boolValue]) return;
    IORegistryEntrySetCFProperty(service, CFSTR("ExternalConnected"), kCFBooleanTrue);
}

static NSInteger IntegerPreference(NSDictionary *dictionary, NSString *key, NSInteger fallback) {
    id value = dictionary[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void EvaluateBattery(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL enabled = [prefs[S("smartChargeEnabled")] boolValue];
    io_service_t service = BatteryService();
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { if (service != IO_OBJECT_NULL) IOObjectRelease(service); return; }
    RepairLegacyExternalConnectedIfNeeded(service, properties);

    if (!enabled) {
        // 关闭智能停充时持续保证抑制位为 false，同时修复旧版遗留状态。
        if ([properties[S("PredictiveChargingInhibit")] boolValue] || gWasEnabled)
            IORegistryEntrySetCFProperty(service, CFSTR("PredictiveChargingInhibit"), kCFBooleanFalse);
        gWasEnabled = NO;
        CPUthermalPostSmartChargeCutoffState(NO);
        IOObjectRelease(service);
        return;
    }
    gWasEnabled = YES;

    NSInteger stopLevel = MAX(70, MIN(100, IntegerPreference(prefs, S("smartChargeStopLevel"), 80)));
    NSInteger resumeLevel = MAX(5, stopLevel - 5);
    NSInteger capacity = IntegerPreference(properties, S("CurrentCapacity"), -1);
    BOOL currentlyInhibited = [properties[S("PredictiveChargingInhibit")] boolValue];
    BOOL connected = AdapterPhysicallyConnected(properties) || [properties[S("ExternalConnected")] boolValue];
    BOOL cutoffActive = currentlyInhibited;
    if (capacity >= 0 && connected) {
        if (capacity >= stopLevel) {
            if (!currentlyInhibited) SetChargingInhibited(YES);
            cutoffActive = YES;
        } else if (capacity <= resumeLevel) {
            if (currentlyInhibited) SetChargingInhibited(NO);
            cutoffActive = NO;
        }
    }
    CPUthermalPostSmartChargeCutoffState(cutoffActive);
    if (service != IO_OBJECT_NULL) IOObjectRelease(service);
}

static BOOL ResetCharging(void) {
    io_service_t service = BatteryService();
    if (service == IO_OBJECT_NULL) return NO;
    NSDictionary *properties = BatteryProperties(service) ?: @{};
    RepairLegacyExternalConnectedIfNeeded(service, properties);
    kern_return_t result = IORegistryEntrySetCFProperty(service, CFSTR("PredictiveChargingInhibit"), kCFBooleanFalse);
    IOObjectRelease(service);
    CPUthermalPostSmartChargeCutoffState(NO);
    return result == KERN_SUCCESS;
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    if (gWasEnabled) ResetCharging();
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;
        signal(SIGTERM, SignalHandler); signal(SIGINT, SignalHandler); signal(SIGHUP, SignalHandler);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gNotifyToken, dispatch_get_main_queue(), ^(int token) { (void)token; EvaluateBattery(); });
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) { EvaluateBattery(); }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
