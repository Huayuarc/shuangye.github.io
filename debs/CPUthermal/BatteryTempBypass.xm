#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

// Rootless / RootHide 共用同一实现，仅注入 powerd。
// 1) 覆盖批量、单属性与搜索式电池温度读取；2) 清除热停充/暂停标志；
// 3) 不注入 thermalmonitord；4) 不改 CPU/GPU/Package 功率字段；
// 5) 不清 PredictiveChargingInhibit，避免破坏项目自带智能停充。

static _Atomic(bool) gEnabled = false;
static _Atomic(bool) gSmartChargeCutoff = false;
static _Atomic(uint64_t) gBatteryID = 0;
static _Atomic(uint64_t) gPowerSourceID = 0;
static _Atomic(uint64_t) gPMUPowerSourceID = 0;
static _Atomic(uint64_t) gBatteryManagerID = 0;
static _Atomic(uint64_t) gPMUChargerID = 0;
static _Atomic(uint64_t) gAccessoryPowerID = 0;
static _Atomic(int64_t) gMaxChargeCurrent = 0;
static _Atomic(int64_t) gNominalChargeCurrent = 0;
static _Atomic(int64_t) gChargeCurrentLimit = 0;
static _Atomic(int64_t) gChargeLimit = 0;
static _Atomic(int64_t) gChargeRate = 0;
static _Atomic(int64_t) gAnyPositiveChargeCurrent = 0;
static int gSettingsToken = 0;
static int gSmartCutoffToken = 0;
static dispatch_queue_t gWorkerQueue;
static dispatch_source_t gKeepAliveTimer;
static unsigned int gKeepAliveTicks = 0;
static kern_return_t (*origCreateProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits) = NULL;

static uint64_t RegistryID(io_registry_entry_t entry) {
    uint64_t value = 0;
    if (entry != IO_OBJECT_NULL) IORegistryEntryGetRegistryEntryID(entry, &value);
    return value;
}

static void CacheServiceID(const char *className, _Atomic(uint64_t) *slot) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(className));
    uint64_t value = RegistryID(service);
    atomic_store_explicit(slot, value, memory_order_release);
    if (service != IO_OBJECT_NULL) IOObjectRelease(service);
}

static void RefreshBatteryServiceIDs(void) {
    CacheServiceID("AppleSmartBattery", &gBatteryID);
    CacheServiceID("IOPMPowerSource", &gPowerSourceID);
    CacheServiceID("AppleARMPMUPowerSource", &gPMUPowerSourceID);
    CacheServiceID("AppleSmartBatteryManager", &gBatteryManagerID);
    CacheServiceID("AppleARMPMUCharger", &gPMUChargerID);
    CacheServiceID("IOAccessoryPowerSource", &gAccessoryPowerID);
}

static BOOL IsKnownBatteryEntry(io_registry_entry_t entry) {
    uint64_t value = RegistryID(entry);
    if (!value) return NO;
    return value == atomic_load_explicit(&gBatteryID, memory_order_acquire) ||
           value == atomic_load_explicit(&gPowerSourceID, memory_order_acquire) ||
           value == atomic_load_explicit(&gPMUPowerSourceID, memory_order_acquire);
}

static BOOL IsKnownChargeEntry(io_registry_entry_t entry) {
    uint64_t value = RegistryID(entry);
    if (!value) return NO;
    return IsKnownBatteryEntry(entry) ||
           value == atomic_load_explicit(&gBatteryManagerID, memory_order_acquire) ||
           value == atomic_load_explicit(&gPMUChargerID, memory_order_acquire) ||
           value == atomic_load_explicit(&gAccessoryPowerID, memory_order_acquire);
}

static BOOL IsBatteryDictionary(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return NO;
    BOOL capacity = dictionary[S("CurrentCapacity")] ||
                    dictionary[S("AppleRawCurrentCapacity")] ||
                    dictionary[S("NominalChargeCapacity")];
    BOOL identity = dictionary[S("ExternalConnected")] ||
                    dictionary[S("ExternalChargeCapable")] ||
                    dictionary[S("BatteryInstalled")] ||
                    dictionary[S("CycleCount")];
    return capacity && identity;
}

static BOOL IsTemperatureKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key caseInsensitiveCompare:S("Temperature")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("VirtualTemperature")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("BatteryTemperature")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("BatteryTemp")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("CellTemperature")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("PackTemperature")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("GaugeTemperature")] == NSOrderedSame ||
           [key caseInsensitiveCompare:S("GasGaugeTemperature")] == NSOrderedSame;
}

static id NormalTemperatureMatchingValue(id original) {
    if (![original respondsToSelector:@selector(doubleValue)]) return nil;
    double value = [original doubleValue];
    double magnitude = value < 0.0 ? -value : value;
    double normal = magnitude >= 1000.0 ? 3200.0 : (magnitude >= 100.0 ? 320.0 : 32.0);
    if ([original isKindOfClass:[NSString class]])
        return [NSString stringWithFormat:S("%.0f"), normal];
    const char *type = [original respondsToSelector:@selector(objCType)] ? [original objCType] : NULL;
    if (type && (type[0] == 'f' || type[0] == 'd')) return [NSNumber numberWithDouble:normal];
    return [NSNumber numberWithLongLong:(long long)normal];
}

static BOOL IsNotChargingReasonKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    const char *names[] = {
        "BatteryNotChargingReason", "NotChargingReason", "ChargeInhibitReason",
        "ChargingStoppedReason", "ChargingPauseReason", "NotChargingReasonCode", NULL
    };
    for (int i = 0; names[i]; i++)
        if ([key caseInsensitiveCompare:S(names[i])] == NSOrderedSame) return YES;
    return NO;
}

static _Atomic(int64_t) *ChargeCurrentSlot(NSString *key) {
    if ([key caseInsensitiveCompare:S("MaxChargeCurrent")] == NSOrderedSame) return &gMaxChargeCurrent;
    if ([key caseInsensitiveCompare:S("NominalChargeCurrent")] == NSOrderedSame) return &gNominalChargeCurrent;
    if ([key caseInsensitiveCompare:S("ChargeCurrentLimit")] == NSOrderedSame) return &gChargeCurrentLimit;
    if ([key caseInsensitiveCompare:S("ChargeLimit")] == NSOrderedSame) return &gChargeLimit;
    if ([key caseInsensitiveCompare:S("ChargeRate")] == NSOrderedSame) return &gChargeRate;
    return NULL;
}

static id IntegerMatchingValue(int64_t value, id original) {
    if ([original isKindOfClass:[NSString class]])
        return [NSString stringWithFormat:S("%lld"), (long long)value];
    const char *type = [original respondsToSelector:@selector(objCType)] ? [original objCType] : NULL;
    if (type && (type[0] == 'f' || type[0] == 'd')) return [NSNumber numberWithDouble:(double)value];
    return [NSNumber numberWithLongLong:value];
}

static void CachePositiveChargeValue(NSString *key, id value) {
    if (![value respondsToSelector:@selector(longLongValue)]) return;
    int64_t numeric = [value longLongValue];
    if (numeric <= 0) return;
    _Atomic(int64_t) *slot = ChargeCurrentSlot(key);
    if (slot) atomic_store_explicit(slot, numeric, memory_order_release);
    atomic_store_explicit(&gAnyPositiveChargeCurrent, numeric, memory_order_release);
}

static int64_t CachedChargeValue(NSString *key) {
    _Atomic(int64_t) *slot = ChargeCurrentSlot(key);
    int64_t value = slot ? atomic_load_explicit(slot, memory_order_acquire) : 0;
    if (value > 0) return value;

    BOOL isCurrentField = [key caseInsensitiveCompare:S("MaxChargeCurrent")] == NSOrderedSame ||
                          [key caseInsensitiveCompare:S("NominalChargeCurrent")] == NSOrderedSame ||
                          [key caseInsensitiveCompare:S("ChargeCurrentLimit")] == NSOrderedSame;
    if (!isCurrentField) return 0;

    value = atomic_load_explicit(&gNominalChargeCurrent, memory_order_acquire);
    if (value > 0) return value;
    value = atomic_load_explicit(&gMaxChargeCurrent, memory_order_acquire);
    if (value > 0) return value;
    return atomic_load_explicit(&gAnyPositiveChargeCurrent, memory_order_acquire);
}

static void CacheChargeValuesFromDictionary(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return;
    const char *keys[] = {
        "MaxChargeCurrent", "NominalChargeCurrent", "ChargeCurrentLimit",
        "ChargeLimit", "ChargeRate", NULL
    };
    for (int i = 0; keys[i]; i++) {
        NSString *key = S(keys[i]);
        CachePositiveChargeValue(key, dictionary[key]);
    }
    NSDictionary *adapter = [dictionary[S("AdapterDetails")] isKindOfClass:[NSDictionary class]]
        ? dictionary[S("AdapterDetails")] : nil;
    id current = adapter[S("Current")];
    if ([current respondsToSelector:@selector(longLongValue)] && [current longLongValue] > 0)
        atomic_store_explicit(&gAnyPositiveChargeCurrent, [current longLongValue], memory_order_release);
}

static BOOL NestedKeyIsBatteryContext(NSString *key) {
    NSString *lower = [key lowercaseString];
    return [lower containsString:S("battery")] ||
           [lower containsString:S("gasgauge")] ||
           [lower containsString:S("gas-gauge")] ||
           [lower containsString:S("power source")] ||
           [lower containsString:S("powersource")] ||
           [lower containsString:S("cell")];
}

static BOOL IsThermalChargeBlockKey(NSString *key);

static void PatchBatteryDictionary(NSMutableDictionary *dictionary, BOOL batteryContext) {
    if (![dictionary isKindOfClass:[NSMutableDictionary class]]) return;
    BOOL isBattery = batteryContext || IsBatteryDictionary(dictionary);
    if (isBattery) CacheChargeValuesFromDictionary(dictionary);
    NSArray *keys = [dictionary.allKeys copy];
    for (id rawKey in keys) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        NSString *key = rawKey;
        id value = dictionary[key];
        BOOL mayResumeCharge = !atomic_load_explicit(&gSmartChargeCutoff, memory_order_acquire);
        _Atomic(int64_t) *currentSlot = ChargeCurrentSlot(key);
        if (isBattery && currentSlot) {
            CachePositiveChargeValue(key, value);
            if (mayResumeCharge && [value respondsToSelector:@selector(longLongValue)] &&
                [value longLongValue] <= 0) {
                int64_t cached = CachedChargeValue(key);
                if (cached > 0) dictionary[key] = IntegerMatchingValue(cached, value);
            }
            continue;
        }
        if (isBattery && IsTemperatureKey(key)) {
            id normal = NormalTemperatureMatchingValue(value);
            if (normal) dictionary[key] = normal;
            continue;
        }
        if (isBattery && mayResumeCharge && IsNotChargingReasonKey(key) &&
            [value respondsToSelector:@selector(longLongValue)] && [value longLongValue] != 0) {
            dictionary[key] = IntegerMatchingValue(0, value);
            continue;
        }
        if (isBattery && mayResumeCharge && IsThermalChargeBlockKey(key) &&
            [value respondsToSelector:@selector(boolValue)]) {
            dictionary[key] = [NSNumber numberWithBool:NO];
            continue;
        }
        if ([value isKindOfClass:[NSDictionary class]]) {
            BOOL childContext = NestedKeyIsBatteryContext(key) || IsBatteryDictionary(value);
            if (!childContext) continue;
            NSMutableDictionary *child = [value mutableCopy];
            PatchBatteryDictionary(child, YES);
            dictionary[key] = child;
        } else if ([value isKindOfClass:[NSArray class]] && NestedKeyIsBatteryContext(key)) {
            NSMutableArray *array = [value mutableCopy];
            for (NSUInteger i = 0; i < array.count; i++) {
                if (![array[i] isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *child = [array[i] mutableCopy];
                PatchBatteryDictionary(child, YES);
                array[i] = child;
            }
            dictionary[key] = array;
        }
    }
}

static const char *kThermalChargeBlockKeys[] = {
    "ChargeInhibit", "ChargeBlocked", "ChargingPaused",
    "ThermalChargeInhibit", "ThermalChargingInhibit",
    "TemperatureChargeInhibit", "HeatChargeInhibit",
    "ChargingDisabledDueToTemperature", "BatteryTemperatureTooHigh",
    "BatteryOverTemperature", "BatteryOverTemp", "TemperatureTooHigh",
    "OverTemperature", "OverTemp", "ChargingTemperatureFault",
    "BatteryNotChargingReason", "NotChargingReason", "ChargeInhibitReason",
    "ChargingStoppedReason", "ChargingPauseReason", "NotChargingReasonCode", NULL
};

static BOOL IsThermalChargeBlockKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    for (int i = 0; kThermalChargeBlockKeys[i]; i++)
        if ([key caseInsensitiveCompare:S(kThermalChargeBlockKeys[i])] == NSOrderedSame) return YES;
    return NO;
}

static NSDictionary *DictionaryByClearingThermalBlocks(NSDictionary *source) {
    if (![source isKindOfClass:[NSDictionary class]]) return source;
    NSMutableDictionary *result = [source mutableCopy];
    BOOL changed = NO;
    for (id rawKey in source) {
        if (![rawKey isKindOfClass:[NSString class]]) continue;
        NSString *key = rawKey;
        id original = source[key];
        if (ChargeCurrentSlot(key) && [original respondsToSelector:@selector(longLongValue)]) {
            CachePositiveChargeValue(key, original);
            if ([original longLongValue] <= 0) {
                int64_t cached = CachedChargeValue(key);
                if (cached > 0) {
                    result[key] = IntegerMatchingValue(cached, original);
                    changed = YES;
                    continue;
                }
            }
        }
        if (IsThermalChargeBlockKey(key)) {
            result[key] = IsNotChargingReasonKey(key)
                ? IntegerMatchingValue(0, original) : [NSNumber numberWithBool:NO];
            changed = YES;
        }
    }
    return changed ? result : source;
}

static BOOL PersistedSmartChargeCutoff(void) {
    NSString *directory = [CPUthermalCurrentPrefPath() stringByDeletingLastPathComponent];
    NSString *path = [directory stringByAppendingPathComponent:S("CPUthermalChargeState.plist")];
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:path];
    return [state[S("cutoff")] boolValue];
}

static void ReloadSmartCutoffState(void) {
    BOOL cutoff = CPUthermalSmartChargeCutoffState() || PersistedSmartChargeCutoff();
    atomic_store_explicit(&gSmartChargeCutoff, cutoff, memory_order_release);
}

static void ReloadPreferences(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: [NSDictionary dictionary];
    BOOL enabled = [prefs[S("bypassBatteryChargeTemperature")] boolValue];
    atomic_store_explicit(&gEnabled, enabled, memory_order_release);
    ReloadSmartCutoffState();
    if (enabled) RefreshBatteryServiceIDs();
}

static void ClearThermalChargeBlocksOnClass(const char *className) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(className));
    if (service == IO_OBJECT_NULL) return;

    CFMutableDictionaryRef raw = NULL;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    kern_return_t readResult = origCreateProperties
        ? origCreateProperties(service, &raw, kCFAllocatorDefault, 0)
        : IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0);
    if (readResult == KERN_SUCCESS && raw) {
        NSDictionary *properties = CFBridgingRelease(raw);
        CacheChargeValuesFromDictionary(properties);
        const char *currentKeys[] = {
            "MaxChargeCurrent", "NominalChargeCurrent", "ChargeCurrentLimit",
            "ChargeLimit", "ChargeRate", NULL
        };
        for (int i = 0; currentKeys[i]; i++) {
            NSString *key = S(currentKeys[i]);
            id current = properties[key];
            if ([current respondsToSelector:@selector(longLongValue)] && [current longLongValue] <= 0) {
                int64_t cached = CachedChargeValue(key);
                if (cached > 0) values[key] = IntegerMatchingValue(cached, current);
            }
        }
        for (int i = 0; kThermalChargeBlockKeys[i]; i++) {
            NSString *key = S(kThermalChargeBlockKeys[i]);
            id current = properties[key];
            if ([current respondsToSelector:@selector(boolValue)] && [current boolValue])
                values[key] = IsNotChargingReasonKey(key)
                    ? IntegerMatchingValue(0, current) : [NSNumber numberWithBool:NO];
        }
    }
    if (values.count)
        IORegistryEntrySetCFProperties(service, (__bridge CFTypeRef)values);
    IOObjectRelease(service);
}

static BOOL CanClearThermalChargeBlocks(void) {
    return atomic_load_explicit(&gEnabled, memory_order_acquire) &&
           !atomic_load_explicit(&gSmartChargeCutoff, memory_order_acquire);
}

static void ApplyBypassState(void) {
    if (!CanClearThermalChargeBlocks()) return;
    ClearThermalChargeBlocksOnClass("AppleSmartBatteryManager");
    ClearThermalChargeBlocksOnClass("AppleSmartBattery");
    ClearThermalChargeBlocksOnClass("IOPMPowerSource");
    ClearThermalChargeBlocksOnClass("AppleARMPMUPowerSource");
    ClearThermalChargeBlocksOnClass("AppleARMPMUCharger");
    ClearThermalChargeBlocksOnClass("IOAccessoryPowerSource");
}

static kern_return_t HookCreateProperties(io_registry_entry_t entry, CFMutableDictionaryRef *out, CFAllocatorRef allocator, IOOptionBits options) {
    kern_return_t result = origCreateProperties(entry, out, allocator, options);
    if (result != KERN_SUCCESS || !out || !*out || !atomic_load_explicit(&gEnabled, memory_order_acquire)) return result;
    NSDictionary *source = (__bridge NSDictionary *)*out;
    BOOL batteryContext = IsKnownBatteryEntry(entry) || IsBatteryDictionary(source);
    if (!batteryContext) return result;
    NSMutableDictionary *patched = [source mutableCopy];
    PatchBatteryDictionary(patched, YES);
    CFRelease(*out);
    *out = (__bridge_retained CFMutableDictionaryRef)patched;
    return result;
}

static CFTypeRef (*origCreateProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef HookCreateProperty(io_registry_entry_t entry, CFStringRef keyRef, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef original = origCreateProperty(entry, keyRef, allocator, options);
    if (!original || !atomic_load_explicit(&gEnabled, memory_order_acquire)) return original;
    NSString *key = (__bridge NSString *)keyRef;
    id value = (__bridge id)original;

    if (IsKnownBatteryEntry(entry) && IsTemperatureKey(key)) {
        id normal = NormalTemperatureMatchingValue(value);
        if (normal) { CFRelease(original); return CFBridgingRetain(normal); }
    }
    if (IsKnownChargeEntry(entry) && ChargeCurrentSlot(key)) {
        CachePositiveChargeValue(key, value);
        if (CanClearThermalChargeBlocks() && [value longLongValue] <= 0) {
            int64_t cached = CachedChargeValue(key);
            if (cached > 0) { CFRelease(original); return CFBridgingRetain(IntegerMatchingValue(cached, value)); }
        }
    }
    if (IsKnownChargeEntry(entry) && CanClearThermalChargeBlocks() &&
        IsThermalChargeBlockKey(key) && [value respondsToSelector:@selector(longLongValue)] &&
        [value longLongValue] != 0) {
        CFRelease(original);
        return CFBridgingRetain(IsNotChargingReasonKey(key)
            ? IntegerMatchingValue(0, value) : [NSNumber numberWithBool:NO]);
    }
    return original;
}

static CFTypeRef (*origSearchProperty)(io_registry_entry_t, const io_name_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef HookSearchProperty(io_registry_entry_t entry, const io_name_t plane, CFStringRef keyRef, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef original = origSearchProperty(entry, plane, keyRef, allocator, options);
    if (!original || !atomic_load_explicit(&gEnabled, memory_order_acquire)) return original;
    NSString *key = (__bridge NSString *)keyRef;
    if (!IsTemperatureKey(key) || !IsKnownBatteryEntry(entry)) return original;
    id normal = NormalTemperatureMatchingValue((__bridge id)original);
    if (!normal) return original;
    CFRelease(original);
    return CFBridgingRetain(normal);
}

static kern_return_t (*origSetProperty)(io_registry_entry_t, CFStringRef, CFTypeRef);
static kern_return_t HookSetProperty(io_registry_entry_t entry, CFStringRef keyRef, CFTypeRef value) {
    if (!CanClearThermalChargeBlocks() || !IsKnownChargeEntry(entry))
        return origSetProperty(entry, keyRef, value);
    NSString *key = (__bridge NSString *)keyRef;
    id originalValue = (__bridge id)value;
    if (ChargeCurrentSlot(key) && [originalValue respondsToSelector:@selector(longLongValue)]) {
        CachePositiveChargeValue(key, originalValue);
        if ([originalValue longLongValue] <= 0) {
            int64_t cached = CachedChargeValue(key);
            if (cached > 0)
                return origSetProperty(entry, keyRef, (__bridge CFTypeRef)IntegerMatchingValue(cached, originalValue));
        }
    }
    if (IsThermalChargeBlockKey(key)) {
        id replacement = IsNotChargingReasonKey(key)
            ? IntegerMatchingValue(0, originalValue) : [NSNumber numberWithBool:NO];
        return origSetProperty(entry, keyRef, (__bridge CFTypeRef)replacement);
    }
    return origSetProperty(entry, keyRef, value);
}

static kern_return_t (*origSetProperties)(io_registry_entry_t, CFTypeRef);
static kern_return_t HookSetProperties(io_registry_entry_t entry, CFTypeRef properties) {
    if (!CanClearThermalChargeBlocks() || !IsKnownChargeEntry(entry) ||
        !properties || CFGetTypeID(properties) != CFDictionaryGetTypeID())
        return origSetProperties(entry, properties);
    NSDictionary *replacement = DictionaryByClearingThermalBlocks((__bridge NSDictionary *)properties);
    return origSetProperties(entry, (__bridge CFTypeRef)replacement);
}

static void HookIOKitSymbol(void *image, const char *name, void *replacement, void **original) {
    void *symbol = dlsym(image, name);
    if (symbol) MSHookFunction(symbol, replacement, original);
}

%ctor {
    @autoreleasepool {
        gWorkerQueue = dispatch_queue_create("com.huayuarc.cputhermal.batterytemp", DISPATCH_QUEUE_SERIAL);
        ReloadPreferences();
        RefreshBatteryServiceIDs();

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            HookIOKitSymbol(iokit, "IORegistryEntryCreateCFProperties", (void *)HookCreateProperties, (void **)&origCreateProperties);
            HookIOKitSymbol(iokit, "IORegistryEntryCreateCFProperty", (void *)HookCreateProperty, (void **)&origCreateProperty);
            HookIOKitSymbol(iokit, "IORegistryEntrySearchCFProperty", (void *)HookSearchProperty, (void **)&origSearchProperty);
            HookIOKitSymbol(iokit, "IORegistryEntrySetCFProperty", (void *)HookSetProperty, (void **)&origSetProperty);
            HookIOKitSymbol(iokit, "IORegistryEntrySetCFProperties", (void *)HookSetProperties, (void **)&origSetProperties);
        }

        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gSettingsToken, gWorkerQueue, ^(int token) {
            (void)token;
            ReloadPreferences();
            ApplyBypassState();
        });
        notify_register_dispatch(kCPUthermalSmartChargeCutoffNotifC, &gSmartCutoffToken, gWorkerQueue, ^(int token) {
            (void)token;
            BOOL cutoff = CPUthermalSmartChargeCutoffState();
            atomic_store_explicit(&gSmartChargeCutoff, cutoff, memory_order_release);
            if (!cutoff) ApplyBypassState();
        });

        gKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gWorkerQueue);
        dispatch_source_set_timer(gKeepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  2ull * NSEC_PER_SEC, 200ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gKeepAliveTimer, ^{
            // 服务对象会在 powerd/驱动重建后变化，约每 30 秒刷新一次 Registry ID。
            if ((++gKeepAliveTicks % 15u) == 0u) {
                RefreshBatteryServiceIDs();
                ReloadSmartCutoffState();
            }
            ApplyBypassState();
        });
        dispatch_resume(gKeepAliveTimer);
        dispatch_async(gWorkerQueue, ^{ ApplyBypassState(); });
    }
}
