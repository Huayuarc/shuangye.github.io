#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import <math.h>
#import <CPUthermalPaths.h>
#import <CPUthermalCompat.h>

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
    // 读取失败时绝不写回：否则会写出只含本模块键的字典，把 powerMode 等其它偏好一并抹掉
    // （曾导致“界面低功耗、频率却恢复到满血”）。
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs || prefs.count == 0) return;
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

// ===== 电流防降频（isolation.9）起始 =====
// 依据电池充放电流保护性能：充电中若仍在大电流放电则提高适配器输入电流上限；
// 放电大电流时向温控守护重申满预算。不触碰任何充电/停充键，不产生文件日志。
static const double kCurrentGuardAssistCurrentMA = -50.0;   // 净电流 ≤ -50mA 视为仍在大电流放电
static const int kCurrentGuardAssistSamples = 3;            // 连续 3 次采样（5s × 3 = 15s）
static const double kCurrentGuardRaiseLimitMA = 3000.0;     // 提升目标，同时是硬上限
static const double kCurrentGuardReleaseCurrentMA = -10.0;  // 净电流 > -10mA 视为不再放电
static const int kCurrentGuardReleaseSamples = 12;          // 连续 12 次采样（5s × 12 = 60s）
static const double kCurrentGuardStressCurrentMA = 2000.0;  // 放电压降风险阈值 |净电流| ≥ 2000mA
static const int kCurrentGuardStressSamples = 3;            // 连续 3 次采样
static const double kCurrentGuardStressClearMA = 1200.0;    // 低于该值视为电流压力解除
static const CFAbsoluteTime kCurrentGuardStressPostInterval = 30.0;  // 通知最短间隔（秒）

static int gCurrentGuardDischargeStreak = 0;
static int gCurrentGuardReleaseStreak = 0;
static int gCurrentGuardStressStreak = 0;
static BOOL gCurrentGuardOwnsLimits = NO;
static BOOL gCurrentGuardPreferSmart = YES;
static NSDictionary *gCurrentGuardOriginalLimits = nil;
static CFAbsoluteTime gLastCurrentGuardStressPost = 0;

static NSArray<NSString *> *CurrentGuardLimitKeys(void) {
    return @[S("AdapterCurrentLimit"), S("USBPDCurrentLimit")];
}

// 面板默认 NO（isolation.15：首次默认关闭）；键缺失按关闭处理。
static BOOL CurrentGuardEnabled(NSDictionary *prefs) {
    return BoolPreference(prefs, S("currentGuardEnabled"), NO);
}

static BOOL CurrentGuardHasOwnedLimits(void) {
    if (gCurrentGuardOwnsLimits && gCurrentGuardOriginalLimits.count) return YES;
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    id stored = prefs[S("__currentGuardOriginalLimits")];
    return [stored isKindOfClass:[NSDictionary class]] && [stored count] > 0;
}

// 写入/清理原值记录：读取失败时绝不回写，避免只含本模块键的字典覆盖其它偏好。
static void SaveCurrentGuardOriginalLimits(NSDictionary *limits) {
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
    if (!prefs || prefs.count == 0) return;
    if (limits.count) prefs[S("__currentGuardOriginalLimits")] = limits;
    else [prefs removeObjectForKey:S("__currentGuardOriginalLimits")];
    CPUthermalWritePrefs(prefs);
}

// 恢复原值并清记录：适配器断开、功能关闭、reset 或 SIGTERM/SIGINT/SIGHUP 时调用。
static void RestoreCurrentGuardLimits(void) {
    if (!CurrentGuardHasOwnedLimits()) {
        gCurrentGuardOwnsLimits = NO;
        gCurrentGuardOriginalLimits = nil;
        gCurrentGuardDischargeStreak = 0;
        gCurrentGuardReleaseStreak = 0;
        return;
    }
    NSDictionary *limits = gCurrentGuardOriginalLimits.count ? gCurrentGuardOriginalLimits : nil;
    if (!limits) {
        NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
        id stored = prefs[S("__currentGuardOriginalLimits")];
        if ([stored isKindOfClass:[NSDictionary class]]) limits = stored;
    }
    for (NSString *key in limits) {
        double original = 0;
        if (!CPUthermalNumberValue(limits[key], &original)) continue;
        SetProperties(gCurrentGuardPreferSmart, @{key: @((NSInteger)llround(original))});
    }
    gCurrentGuardOwnsLimits = NO;
    gCurrentGuardOriginalLimits = nil;
    gCurrentGuardDischargeStreak = 0;
    gCurrentGuardReleaseStreak = 0;
    SaveCurrentGuardOriginalLimits(nil);
}

// 只升不降：对存在的限流键（AdapterCurrentLimit → USBPDCurrentLimit），
// 现值 < 3000 时写到 3000；键不存在跳过，绝不写更高值，也绝不降低现值。
static void ApplyCurrentGuardRaise(io_service_t service, NSDictionary *prefs) {
    if (service == IO_OBJECT_NULL) return;
    NSMutableDictionary *originals = gCurrentGuardOriginalLimits.count
        ? [gCurrentGuardOriginalLimits mutableCopy]
        : [NSMutableDictionary dictionary];
    NSUInteger persistedCount = originals.count;
    BOOL wrote = NO;
    for (NSString *key in CurrentGuardLimitKeys()) {
        double present = 0;
        if (!CPUthermalPropertyNumber(service, @[key], &present, NULL)) continue;   // 键不存在：跳过该键
        if (present >= kCurrentGuardRaiseLimitMA) continue;                         // 已不低于目标：不降
        if (!originals[key]) originals[key] = @((NSInteger)llround(present));
        // 首个键实际写入前先把原值持久化到 prefs，避免进程被杀后无原值可恢复。
        if (!wrote && !gCurrentGuardOwnsLimits) SaveCurrentGuardOriginalLimits(originals);
        if (SetProperties(gCurrentGuardPreferSmart, @{key: @((NSInteger)llround(kCurrentGuardRaiseLimitMA))})) {
            wrote = YES;
            gCurrentGuardOwnsLimits = YES;
            gCurrentGuardOriginalLimits = originals;
        }
    }
    if (!wrote && !gCurrentGuardOwnsLimits) {
        // 无键可写（全部缺失或已不低于目标）：安全降级为 no-op，并清掉可能残留的脏记录。
        id stored = prefs[S("__currentGuardOriginalLimits")];
        if ([stored isKindOfClass:[NSDictionary class]]) SaveCurrentGuardOriginalLimits(nil);
    } else if (wrote && originals.count > persistedCount) {
        // 补齐本次新增的键原值（仅在确有新增时写一次，不在每 5 秒采样里重复写 prefs）。
        SaveCurrentGuardOriginalLimits(originals);
    }
}

static void PostCurrentGuardStressIfAllowed(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastCurrentGuardStressPost < kCurrentGuardStressPostInterval) return;
    gLastCurrentGuardStressPost = now;
    (void)notify_post(kCPUthermalCurrentStressNotifC);
}

// 独立 5 秒采样：不改动原有 15 秒智能停充节奏，也不读写任何充电/停充键。
static void EvaluateCurrentGuard(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    if (!CurrentGuardEnabled(prefs)) { RestoreCurrentGuardLimits(); return; }
    gCurrentGuardPreferSmart = BoolPreference(prefs, S("smartChargeUseSmartBatteryAPI"), NO);

    io_service_t service = BatteryService(gCurrentGuardPreferSmart);
    if (service == IO_OBJECT_NULL) return;
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { IOObjectRelease(service); return; }

    double amperage = 0;
    // 跨版本回退读取：InstantAmperage → Amperage（mA，负值 = 放电）
    BOOL haveAmperage = CPUthermalPropertyNumber(service, @[S("InstantAmperage"), S("Amperage")], &amperage, NULL);
    BOOL connected = AdapterConnected(properties);

    if (!connected) {
        // 放电分支：仅在适配器未连接时评估电流压力通知；断开适配器立即释放充电提升。
        if (haveAmperage && fabs(amperage) >= kCurrentGuardStressCurrentMA) {
            gCurrentGuardStressStreak++;
            if (gCurrentGuardStressStreak >= kCurrentGuardStressSamples) PostCurrentGuardStressIfAllowed();
        } else if (!haveAmperage || fabs(amperage) < kCurrentGuardStressClearMA) {
            gCurrentGuardStressStreak = 0;      // < 1200mA 停止
        }
        RestoreCurrentGuardLimits();
        IOObjectRelease(service);
        return;
    }

    gCurrentGuardStressStreak = 0;              // 已接适配器：不再评估放电压降通知
    if (!haveAmperage) { IOObjectRelease(service); return; }   // 电流不可读：不写不改，等下个采样

    if (amperage <= kCurrentGuardAssistCurrentMA) {
        gCurrentGuardReleaseStreak = 0;
        if (gCurrentGuardDischargeStreak < kCurrentGuardAssistSamples) gCurrentGuardDischargeStreak++;
        if (gCurrentGuardDischargeStreak >= kCurrentGuardAssistSamples) ApplyCurrentGuardRaise(service, prefs);
    } else if (amperage > kCurrentGuardReleaseCurrentMA) {
        gCurrentGuardDischargeStreak = 0;
        if (gCurrentGuardReleaseStreak < kCurrentGuardReleaseSamples) gCurrentGuardReleaseStreak++;
        if (gCurrentGuardReleaseStreak >= kCurrentGuardReleaseSamples) RestoreCurrentGuardLimits();
    }
    IOObjectRelease(service);
}
// ===== 电流防降频（isolation.9）结束 =====

static void EvaluateBattery(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    BOOL enabled = BoolPreference(prefs, S("smartChargeEnabled"), NO);
    BOOL preferSmart = BoolPreference(prefs, S("smartChargeUseSmartBatteryAPI"), NO);
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
// AppleSmartBattery 的 Temperature 为百分之一摄氏度（4600 => 46.0℃），兼容十分之一
static BOOL ResetCharging(void) {
    RestoreCurrentGuardLimits();   // 附加上：电流防降频提升值恢复并清记录
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
            (void)token; @autoreleasepool { EvaluateBattery(); }
        });
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateBattery(); }
        }];
        // 电流防降频：独立 5 秒电流采样，与上方 15 秒智能停充节奏互不影响。
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateCurrentGuard(); }
        }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
