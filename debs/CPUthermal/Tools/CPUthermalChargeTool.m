#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

// ChargeLimiter 电量阈值核心移植：SmartBatteryAPI + 智能停充 + 停充自动禁流。
// 不处理温度阈值、通知、统计、充电电流和附加动作。
static BOOL gOwnsInhibit = NO;
static BOOL gOwnsInflowDisable = NO;
static BOOL gOwnershipPreferSmart = YES;
static int gNotifyToken = 0;

static BOOL BoolPreference(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger IntegerPreference(NSDictionary *prefs, NSString *key, NSInteger fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void LoadOwnership(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    gOwnsInhibit = [prefs[S("__smartChargeOwnsInhibit")] boolValue];
    gOwnsInflowDisable = [prefs[S("__smartChargeOwnsInflowDisable")] boolValue];
    id source = prefs[S("__smartChargeOwnershipPreferSmart")];
    gOwnershipPreferSmart = [source respondsToSelector:@selector(boolValue)] ? [source boolValue] : YES;
}

static void SaveOwnership(void) {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs() ?: [NSMutableDictionary dictionary];
    if (gOwnsInhibit) prefs[S("__smartChargeOwnsInhibit")] = @YES;
    else [prefs removeObjectForKey:S("__smartChargeOwnsInhibit")];
    if (gOwnsInflowDisable) prefs[S("__smartChargeOwnsInflowDisable")] = @YES;
    else [prefs removeObjectForKey:S("__smartChargeOwnsInflowDisable")];
    if (gOwnsInhibit || gOwnsInflowDisable) prefs[S("__smartChargeOwnershipPreferSmart")] = @(gOwnershipPreferSmart);
    else [prefs removeObjectForKey:S("__smartChargeOwnershipPreferSmart")];
    CPUthermalWritePrefs(prefs);
}

static io_service_t BatteryService(BOOL preferSmart) {
    io_service_t service = IO_OBJECT_NULL;
    if (preferSmart)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL && !preferSmart)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    return service;
}

static NSDictionary *BatteryProperties(io_service_t service) {
    if (service == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef raw = NULL;
    if (IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) != KERN_SUCCESS || !raw) return nil;
    return CFBridgingRelease(raw);
}

static BOOL AdapterConnected(NSDictionary *properties) {
    NSDictionary *adapter = [properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]] ? properties[S("AdapterDetails")] : nil;
    NSString *description = [adapter[S("Description")] isKindOfClass:[NSString class]] ? adapter[S("Description")] : nil;
    if (adapter.count && ![description isEqualToString:S("batt")]) return YES;
    return [properties[S("ExternalConnected")] boolValue] || [properties[S("ExternalChargeCapable")] boolValue];
}

static BOOL SetProperties(BOOL preferSmart, NSDictionary *properties) {
    io_service_t service = BatteryService(preferSmart);
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t result = IORegistryEntrySetCFProperties(service, (__bridge CFTypeRef)properties);
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

static BOOL SetChargeInhibited(BOOL preferSmart, BOOL inhibited) {
    BOOL ok = SetProperties(preferSmart, @{S("PredictiveChargingInhibit"):@(inhibited)});
    if (ok) { if (inhibited) gOwnershipPreferSmart = preferSmart; gOwnsInhibit = inhibited; SaveOwnership(); }
    return ok;
}

static BOOL SetInflowEnabled(BOOL preferSmart, BOOL enabled) {
    BOOL ok = SetProperties(preferSmart, @{S("ExternalConnected"):@(enabled)});
    if (ok) { if (!enabled) gOwnershipPreferSmart = preferSmart; gOwnsInflowDisable = !enabled; SaveOwnership(); }
    return ok;
}

static void RestoreOwnedState(void) {
    BOOL preferSmart = gOwnershipPreferSmart;
    if (gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
    if (gOwnsInhibit) SetChargeInhibited(preferSmart, NO);
}

static void EvaluateBattery(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL enabled = BoolPreference(prefs, S("smartChargeEnabled"), NO);
    BOOL preferSmart = BoolPreference(prefs, S("smartChargeUseSmartBatteryAPI"), YES);
    BOOL disableInflow = BoolPreference(prefs, S("smartChargeDisableInflow"), NO);
    if ((gOwnsInhibit || gOwnsInflowDisable) && preferSmart != gOwnershipPreferSmart) RestoreOwnedState();
    if (!enabled) { RestoreOwnedState(); return; }

    io_service_t service = BatteryService(preferSmart);
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { if (service != IO_OBJECT_NULL) IOObjectRelease(service); return; }
    NSInteger stopLevel = MAX(70, MIN(100, IntegerPreference(prefs, S("smartChargeStopLevel"), 80)));
    NSInteger resumeLevel = MAX(5, stopLevel - 5);
    NSInteger capacity = IntegerPreference(properties, S("CurrentCapacity"), -1);
    BOOL connected = AdapterConnected(properties);
    IOObjectRelease(service);

    if (capacity < 0 || !connected) return;
    if (capacity >= stopLevel) {
        if (!gOwnsInhibit) SetChargeInhibited(preferSmart, YES);
        if (disableInflow && !gOwnsInflowDisable) SetInflowEnabled(preferSmart, NO);
        if (!disableInflow && gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
    } else if (capacity <= resumeLevel) {
        // ChargeLimiter 顺序：先恢复输入，再恢复充电。
        if (gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
        if (gOwnsInhibit) SetChargeInhibited(preferSmart, NO);
    }
}


// ============================================================================
// 充电发热保护：充电过程中电池温度过高时暂停充电，降温后自动恢复
//   阈值：chargeHeatStopTempC（默认 42℃，可写偏好调整），恢复温度 = 停止温度 - 4
//   与智能停充共用同一套停充/恢复实现（PredictiveChargingInhibit / ExternalConnected）
// ============================================================================
static BOOL gHeatGuardActive = NO;

static void AppendChargeLog(NSString *message) {
    if (message.length == 0) return;
    NSString *line = [NSString stringWithFormat:@"[%.3f][charge] %@\n", CFAbsoluteTimeGetCurrent(), message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[S("/usr/local/share/CPUthermal"), S("/var/jb/usr/local/share/CPUthermal"),
                            S("/var/mobile/Library/CPUthermal"), S("/var/tmp"), S("/tmp")]) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSString *path = [dir stringByAppendingPathComponent:S("cputhermal-throttle.log")];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) continue;
        @try { [handle seekToEndOfFile]; [handle writeData:data]; [handle closeFile]; }
        @catch (__unused NSException *e) { }
        break;
    }
}

// AppleSmartBattery 的 Temperature 为百分之一摄氏度（4600 => 46.0℃），兼容十分之一
static double BatteryTemperatureCelsius(NSDictionary *properties) {
    id value = properties[S("Temperature")];
    if (![value respondsToSelector:@selector(doubleValue)]) return -1.0;
    double raw = [value doubleValue];
    if (raw <= 0.0) return -1.0;
    return raw > 2000.0 ? raw / 100.0 : raw / 10.0;
}

static void EvaluateHeatGuard(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL preferSmart = BoolPreference(prefs, S("smartChargeUseSmartBatteryAPI"), YES);
    if (!BoolPreference(prefs, S("chargeHeatGuardEnabled"), YES)) {
        if (gHeatGuardActive) { gHeatGuardActive = NO; AppendChargeLog(S("HEAT 充电高温保护已关闭")); }
        return;
    }
    io_service_t service = BatteryService(preferSmart);
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { if (service != IO_OBJECT_NULL) IOObjectRelease(service); return; }
    double tempC = BatteryTemperatureCelsius(properties);
    BOOL connected = AdapterConnected(properties);
    IOObjectRelease(service);
    if (tempC < 0.0 || !connected) {
        if (gHeatGuardActive) { gHeatGuardActive = NO; AppendChargeLog(S("HEAT 充电高温保护解除（未充电或温度不可用）")); }
        return;
    }
    NSInteger stopTemp = MAX(35, MIN(55, IntegerPreference(prefs, S("chargeHeatStopTempC"), 42)));
    NSInteger resumeTemp = MAX(30, stopTemp - 4);
    if (!gHeatGuardActive && tempC >= (double)stopTemp) {
        gHeatGuardActive = YES;
        if (!gOwnsInhibit) SetChargeInhibited(preferSmart, YES);
        if (BoolPreference(prefs, S("smartChargeDisableInflow"), NO) && !gOwnsInflowDisable) SetInflowEnabled(preferSmart, NO);
        AppendChargeLog([NSString stringWithFormat:@"HEAT 充电高温保护生效 temp=%.1fC >= %ldC：已暂停充电",
                         tempC, (long)stopTemp]);
    } else if (gHeatGuardActive && tempC <= (double)resumeTemp) {
        gHeatGuardActive = NO;
        RestoreOwnedState();
        EvaluateBattery();   // 再按电量阈值决定是否应继续停充
        AppendChargeLog([NSString stringWithFormat:@"HEAT 充电高温保护解除 temp=%.1fC <= %ldC：已恢复充电评估",
                         tempC, (long)resumeTemp]);
    }
}

static BOOL ResetCharging(void) {
    RestoreOwnedState();
    return !gOwnsInhibit && !gOwnsInflowDisable;
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    ResetCharging();
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        LoadOwnership();
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;
        signal(SIGTERM, SignalHandler); signal(SIGINT, SignalHandler); signal(SIGHUP, SignalHandler);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
            (void)token; @autoreleasepool { EvaluateBattery(); EvaluateHeatGuard(); }
        });
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateBattery(); }
        }];
        // 温度变化比电量快，单独 5 秒轮询做充电高温保护
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateHeatGuard(); }
        }];
        EvaluateBattery();
        EvaluateHeatGuard();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
