#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <CPUthermalPaths.h>

static int gNotifyToken = 0;
static NSTimeInterval gProcessStartTime = 0;
static unsigned int gMissingAdapterSamples = 0;
static BOOL gHasPostedCutoffState = NO;
static BOOL gLastPostedCutoffState = NO;
static BOOL gSmartChargeEnabled = NO;
static NSInteger gConfiguredStopLevel = 80;
static NSString *gCachedStatePath = nil;

static void PublishCutoffState(BOOL cutoff) {
    if (gHasPostedCutoffState && gLastPostedCutoffState == cutoff) return;
    gHasPostedCutoffState = YES;
    gLastPostedCutoffState = cutoff;
    CPUthermalPostSmartChargeCutoffState(cutoff);
}

static NSString *StatePath(void) {
    if (!gCachedStatePath) {
        NSString *directory = [CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent];
        gCachedStatePath = [directory stringByAppendingPathComponent:S("CPUthermalChargeState.plist")];
    }
    return gCachedStatePath;
}

static NSDictionary *ReadState(void) {
    return [NSDictionary dictionaryWithContentsOfFile:StatePath()] ?: [NSDictionary dictionary];
}

static void SaveState(BOOL cutoff, BOOL sawUnplug, BOOL manualOverride,
                      NSInteger stopLevel, NSTimeInterval cutoffTime) {
    NSString *path = StatePath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *state = @{
        S("cutoff"): [NSNumber numberWithBool:cutoff],
        S("sawUnplug"): [NSNumber numberWithBool:sawUnplug],
        S("manualOverride"): [NSNumber numberWithBool:manualOverride],
        S("stopLevel"): [NSNumber numberWithInteger:stopLevel],
        S("cutoffTime"): [NSNumber numberWithDouble:cutoffTime]
    };
    [state writeToFile:path atomically:YES];
    PublishCutoffState(cutoff);
}

static io_service_t BatteryService(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleARMPMUPowerSource"));
    return service;
}

static NSDictionary *BatteryProperties(io_service_t service) {
    if (service == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef properties = NULL;
    if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) != KERN_SUCCESS || !properties)
        return nil;
    return CFBridgingRelease(properties);
}

static NSInteger IntegerValue(NSDictionary *dictionary, NSString *key, NSInteger fallback) {
    id value = dictionary[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void ReloadConfiguration(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: [NSDictionary dictionary];
    gSmartChargeEnabled = [prefs[S("smartChargeEnabled")] boolValue];
    gConfiguredStopLevel = MAX(70, MIN(100,
        IntegerValue(prefs, S("smartChargeStopLevel"), 80)));
}

static BOOL MeaningfulChargerType(NSString *type) {
    if (![type isKindOfClass:[NSString class]] || !type.length) return NO;
    return [type caseInsensitiveCompare:S("battery")] != NSOrderedSame &&
           [type caseInsensitiveCompare:S("none")] != NSOrderedSame &&
           [type caseInsensitiveCompare:S("unknown")] != NSOrderedSame;
}

// cutoffMode=YES 时不使用 ExternalConnected（该字段正是插件主动写成 false 的）。
// AdapterDetails/ChargerType/ExternalChargeCapable 用来识别真实拔出与重新插入。
static BOOL AdapterHardwarePresent(NSDictionary *properties, BOOL cutoffMode) {
    NSDictionary *adapter = [properties[S("AdapterDetails")] isKindOfClass:[NSDictionary class]]
        ? properties[S("AdapterDetails")] : nil;
    NSString *description = [adapter[S("Description")] isKindOfClass:[NSString class]]
        ? adapter[S("Description")] : nil;

    // 禁流后 ExternalConnected/ExternalChargeCapable 可能都为 false；沿用 ChargeLimiter
    // 已验证语义，通过 AdapterDetails 判断真实线缆。连续采样可过滤瞬时空字典。
    if (cutoffMode) {
        if (!adapter.count || !description.length || [description isEqualToString:S("batt")]) return NO;
        return YES;
    }

    if (adapter.count && ![description isEqualToString:S("batt")]) return YES;
    NSString *chargerType = [properties[S("ChargerType")] isKindOfClass:[NSString class]]
        ? properties[S("ChargerType")] : nil;
    if (MeaningfulChargerType(chargerType)) return YES;
    return [properties[S("ExternalChargeCapable")] boolValue] ||
           [properties[S("ExternalConnected")] boolValue];
}

static BOOL SetProperties(io_service_t service, NSDictionary *values) {
    if (service == IO_OBJECT_NULL || !values.count) return NO;
    return IORegistryEntrySetCFProperties(service, (__bridge CFTypeRef)values) == KERN_SUCCESS;
}

static NSDictionary *CutoffValues(void) {
    return @{
        S("PredictiveChargingInhibit"): [NSNumber numberWithBool:YES],
        S("ExternalConnected"): [NSNumber numberWithBool:NO],
        S("IsCharging"): [NSNumber numberWithBool:NO]
    };
}

// 阈值停充拥有最高优先级：先发布 cutoff=1，让 powerd 温度模块立即停止清除阻断位，
// 再原子写入“停止电流 + 外部电源断开 + 取消充电图标”。
static BOOL EnterCutoff(io_service_t service, NSInteger stopLevel) {
    PublishCutoffState(YES);
    BOOL ok = SetProperties(service, CutoffValues());
    if (ok) SaveState(YES, NO, NO, stopLevel, (NSTimeInterval)time(NULL));
    else PublishCutoffState(NO);
    return ok;
}

static void EnforceCutoff(io_service_t service) {
    SetProperties(service, CutoffValues());
}

// 关闭功能或完成一次真实拔插后恢复。manualOverride=YES 时，本轮插线不会因仍高于
// 阈值而马上再次断流；电量降至阈值以下后自动重新布防。
static BOOL ResumeCharging(io_service_t service, NSDictionary *properties,
                           BOOL manualOverride, NSInteger stopLevel) {
    (void)properties;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    values[S("PredictiveChargingInhibit")] = [NSNumber numberWithBool:NO];
    // 所有恢复路径都撤销本插件写入的 ExternalConnected=false/IsCharging=false；
    // 物理未接线时底层驱动会立即校正，接线仍在时可直接恢复输入。
    values[S("ExternalConnected")] = [NSNumber numberWithBool:YES];
    values[S("IsCharging")] = [NSNumber numberWithBool:YES];
    BOOL ok = SetProperties(service, values);
    if (ok) SaveState(NO, NO, manualOverride, stopLevel, 0);
    return ok;
}

static void EvaluateBattery(void) {
    BOOL enabled = gSmartChargeEnabled;
    NSInteger stopLevel = gConfiguredStopLevel;

    io_service_t service = BatteryService();
    if (service == IO_OBJECT_NULL) return;
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { IOObjectRelease(service); return; }

    NSDictionary *state = ReadState();
    BOOL cutoff = [state[S("cutoff")] boolValue];
    BOOL sawUnplug = [state[S("sawUnplug")] boolValue];
    BOOL manualOverride = [state[S("manualOverride")] boolValue];
    NSTimeInterval cutoffTime = [state[S("cutoffTime")] doubleValue];
    NSInteger capacity = IntegerValue(properties, S("CurrentCapacity"), -1);
    NSInteger resumeLevel = MAX(5, stopLevel - 5);

    if (!enabled) {
        if (cutoff || [properties[S("PredictiveChargingInhibit")] boolValue])
            ResumeCharging(service, properties, NO, stopLevel);
        else {
            if (manualOverride) SaveState(NO, NO, NO, stopLevel, 0);
            else PublishCutoffState(NO);
        }
        IOObjectRelease(service);
        return;
    }

    if (manualOverride) {
        PublishCutoffState(NO);
        if (capacity >= 0 && capacity < stopLevel)
            SaveState(NO, NO, NO, stopLevel, 0);
        IOObjectRelease(service);
        return;
    }

    if (cutoff) {
        // 双恢复路径：用户真实拔插立即恢复；长时间未拔插但电量自然降到阈值-5%时兜底恢复。
        if (capacity >= 0 && capacity <= resumeLevel) {
            ResumeCharging(service, properties, NO, stopLevel);
            IOObjectRelease(service);
            return;
        }
        PublishCutoffState(YES);
        NSTimeInterval now = (NSTimeInterval)time(NULL);
        // daemon/powerd 启动初期 AdapterDetails 可能短暂为空，前 5 秒不把它误判成拔线。
        if (now - gProcessStartTime < 5.0 || now - cutoffTime < 2.0) {
            EnforceCutoff(service);
            IOObjectRelease(service);
            return;
        }

        BOOL physical = AdapterHardwarePresent(properties, YES);
        if (!physical) {
            // 连续 4 次（约 4 秒）均无适配器证据才确认拔线，过滤驱动瞬时空字典。
            if (gMissingAdapterSamples < 100u) gMissingAdapterSamples++;
            if (gMissingAdapterSamples >= 4u && !sawUnplug)
                SaveState(YES, YES, NO, stopLevel, cutoffTime);
            IOObjectRelease(service);
            return;
        }
        gMissingAdapterSamples = 0;
        if (sawUnplug) {
            ResumeCharging(service, properties, YES, stopLevel);
            IOObjectRelease(service);
            return;
        }

        // 系统若尝试恢复充电状态，立即重新锁定断流；未发生真实拔插时不自动恢复。
        BOOL stateDrift = ![properties[S("PredictiveChargingInhibit")] boolValue] ||
                          [properties[S("ExternalConnected")] boolValue] ||
                          [properties[S("IsCharging")] boolValue];
        if (stateDrift) EnforceCutoff(service);
        IOObjectRelease(service);
        return;
    }

    gMissingAdapterSamples = 0;
    PublishCutoffState(NO);
    BOOL physical = AdapterHardwarePresent(properties, NO);
    if (capacity >= 0 && capacity >= stopLevel && physical)
        EnterCutoff(service, stopLevel);

    IOObjectRelease(service);
}

static BOOL ResetCharging(void) {
    io_service_t service = BatteryService();
    if (service == IO_OBJECT_NULL) {
        SaveState(NO, NO, NO, 80, 0);
        return NO;
    }
    NSDictionary *properties = BatteryProperties(service) ?: [NSDictionary dictionary];
    BOOL ok = ResumeCharging(service, properties, NO, 80);
    IOObjectRelease(service);
    return ok;
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;
        signal(SIGTERM, SignalHandler);
        signal(SIGINT, SignalHandler);
        signal(SIGHUP, SignalHandler);

        gProcessStartTime = (NSTimeInterval)time(NULL);
        ReloadConfiguration();
        PublishCutoffState([ReadState()[S("cutoff")] boolValue]);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gNotifyToken,
                                 dispatch_get_main_queue(), ^(int token) {
            (void)token;
            ReloadConfiguration();
            EvaluateBattery();
        });
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES
                                          block:^(__unused NSTimer *timer) {
            EvaluateBattery();
        }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
