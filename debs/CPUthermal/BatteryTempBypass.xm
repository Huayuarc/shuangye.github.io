#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <objc/runtime.h>
#import <string.h>
#import <CPUthermalPaths.h>

// Rootless / RootHide 共用同一实现，仅注入 powerd。
// 1) 覆盖批量、单属性与搜索式电池温度读取；2) 清除热停充/暂停标志；
// 3) 不注入 thermalmonitord；4) 不改 CPU/GPU/Package 功率字段；
// 5) 不清 PredictiveChargingInhibit，避免破坏项目自带智能停充。

static _Atomic(bool) gEnabled = false;
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
static dispatch_queue_t gWorkerQueue;
static dispatch_source_t gKeepAliveTimer;
static unsigned int gKeepAliveTicks = 0;
static BOOL CanClearThermalChargeBlocks(void);
static BOOL CanForceChargeCurrent(void);
static kern_return_t (*GetRegistryEntryID)(io_registry_entry_t, uint64_t *) = NULL;
static kern_return_t (*origCreateProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits) = NULL;

static uint64_t RegistryID(io_registry_entry_t entry) {
    uint64_t value = 0;
    if (entry != IO_OBJECT_NULL && GetRegistryEntryID)
        GetRegistryEntryID(entry, &value);
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
    double normal = magnitude >= 1000.0 ? 2500.0 : (magnitude >= 100.0 ? 250.0 : 25.0);
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
        BOOL mayResumeCharge = !CPUthermalSmartChargeCutoffState();
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

// 仅处理明确的高温停充字段；PredictiveChargingInhibit 由智能停充守护独占。
static NSDictionary *DictionaryByClearingThermalBlocks(NSDictionary *source) {
    if (![source isKindOfClass:[NSDictionary class]] || !CanForceChargeCurrent()) return source;
    NSMutableDictionary *result=[source mutableCopy]; BOOL changed=NO;
    for(id rawKey in source) {
        if(![rawKey isKindOfClass:NSString.class])continue;
        NSString *key=rawKey; id original=source[key];
        _Atomic(int64_t) *slot=ChargeCurrentSlot(key);
        if(slot && [original respondsToSelector:@selector(longLongValue)]) {
            CachePositiveChargeValue(key,original);
            if([original longLongValue]<=0) { int64_t cached=CachedChargeValue(key); if(cached>0){result[key]=IntegerMatchingValue(cached,original);changed=YES;} }
        }
        if(IsThermalChargeBlockKey(key)) { result[key]=IsNotChargingReasonKey(key)?IntegerMatchingValue(0,original):[NSNumber numberWithBool:NO];changed=YES; }
    }
    return changed?result:source;
}

static void ReloadPreferences(void) {
    BOOL enabled=[CPUthermalReadPrefs()[S("bypassBatteryChargeTemperature")] boolValue];
    atomic_store_explicit(&gEnabled,enabled,memory_order_release);
    if(enabled)RefreshBatteryServiceIDs();
}

static BOOL AnyChargeBypassEnabled(void) { return atomic_load_explicit(&gEnabled,memory_order_acquire); }

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
        for (int i = 0; CanClearThermalChargeBlocks() && kThermalChargeBlockKeys[i]; i++) {
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
    return atomic_load_explicit(&gEnabled, memory_order_acquire);
}

static void ApplyBypassState(void) {
    if(!CanForceChargeCurrent())return;
    ClearThermalChargeBlocksOnClass("AppleSmartBatteryManager"); ClearThermalChargeBlocksOnClass("AppleSmartBattery");
    ClearThermalChargeBlocksOnClass("IOPMPowerSource"); ClearThermalChargeBlocksOnClass("AppleARMPMUPowerSource");
    ClearThermalChargeBlocksOnClass("AppleARMPMUCharger"); ClearThermalChargeBlocksOnClass("IOAccessoryPowerSource");
}

static kern_return_t HookCreateProperties(io_registry_entry_t entry, CFMutableDictionaryRef *out, CFAllocatorRef allocator, IOOptionBits options) {
    kern_return_t result = origCreateProperties(entry, out, allocator, options);
    if (result != KERN_SUCCESS || !out || !*out || !AnyChargeBypassEnabled()) return result;
    // 批量读取温度伪装只由“屏蔽电池充电温度检测”开关控制。
    if (!atomic_load_explicit(&gEnabled, memory_order_acquire)) return result;
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
    CFTypeRef original=origCreateProperty(entry,keyRef,allocator,options);
    if(!original||!CanClearThermalChargeBlocks())return original;
    NSString *key=(__bridge NSString*)keyRef; id value=(__bridge id)original;
    if(IsKnownBatteryEntry(entry)&&IsTemperatureKey(key)){id normal=NormalTemperatureMatchingValue(value);if(normal){CFRelease(original);return CFBridgingRetain(normal);}}
    if(CanForceChargeCurrent()&&IsKnownChargeEntry(entry)){
        _Atomic(int64_t)*slot=ChargeCurrentSlot(key);
        if(slot&&[value respondsToSelector:@selector(longLongValue)]){CachePositiveChargeValue(key,value);if([value longLongValue]<=0){int64_t cached=CachedChargeValue(key);if(cached>0){CFRelease(original);return CFBridgingRetain(IntegerMatchingValue(cached,value));}}}
        if(IsThermalChargeBlockKey(key)&&[value respondsToSelector:@selector(longLongValue)]&&[value longLongValue]!=0){CFRelease(original);return CFBridgingRetain(IsNotChargingReasonKey(key)?IntegerMatchingValue(0,value):[NSNumber numberWithBool:NO]);}
    }
    return original;
}

static CFTypeRef (*origSearchProperty)(io_registry_entry_t, const io_name_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef HookSearchProperty(io_registry_entry_t entry,const io_name_t plane,CFStringRef keyRef,CFAllocatorRef allocator,IOOptionBits options) {
    CFTypeRef original=origSearchProperty(entry,plane,keyRef,allocator,options);
    if(!original||!CanClearThermalChargeBlocks())return original;
    NSString *key=(__bridge NSString*)keyRef; id value=(__bridge id)original;
    if(IsKnownBatteryEntry(entry)&&IsTemperatureKey(key)){id normal=NormalTemperatureMatchingValue(value);if(normal){CFRelease(original);return CFBridgingRetain(normal);}}
    return original;
}

static kern_return_t (*origSetProperty)(io_registry_entry_t, CFStringRef, CFTypeRef);
static kern_return_t HookSetProperty(io_registry_entry_t entry,CFStringRef keyRef,CFTypeRef value) {
    if(!CanForceChargeCurrent()||!IsKnownChargeEntry(entry))return origSetProperty(entry,keyRef,value);
    NSString *key=(__bridge NSString*)keyRef; id originalValue=(__bridge id)value;
    _Atomic(int64_t)*slot=ChargeCurrentSlot(key);
    if(slot&&[originalValue respondsToSelector:@selector(longLongValue)]){CachePositiveChargeValue(key,originalValue);if([originalValue longLongValue]<=0){int64_t cached=CachedChargeValue(key);if(cached>0)return origSetProperty(entry,keyRef,(__bridge CFTypeRef)IntegerMatchingValue(cached,originalValue));}}
    if(IsThermalChargeBlockKey(key)){id replacement=IsNotChargingReasonKey(key)?IntegerMatchingValue(0,originalValue):[NSNumber numberWithBool:NO];return origSetProperty(entry,keyRef,(__bridge CFTypeRef)replacement);}
    return origSetProperty(entry,keyRef,value);
}

static kern_return_t (*origSetProperties)(io_registry_entry_t, CFTypeRef);
static kern_return_t HookSetProperties(io_registry_entry_t entry,CFTypeRef properties) {
    if(!CanForceChargeCurrent()||!IsKnownChargeEntry(entry)||!properties||CFGetTypeID(properties)!=CFDictionaryGetTypeID())return origSetProperties(entry,properties);
    NSDictionary *replacement=DictionaryByClearingThermalBlocks((__bridge NSDictionary*)properties);
    return origSetProperties(entry,(__bridge CFTypeRef)replacement);
}

static void (*origSetChargingCurrentMethod)(id, SEL, long long) = NULL;
static void (*origSetNotChargingReasonMethod)(id, SEL, int) = NULL;
static void (*origSetPostChargeWaitSecondsMethod)(id, SEL, int) = NULL;

static BOOL CanForceChargeCurrent(void) {
    return CanClearThermalChargeBlocks() && !CPUthermalSmartChargeCutoffState();
}

static void HookedSetChargingCurrent(id self, SEL selector, long long current) {
    long long finalCurrent = current;
    if (CanForceChargeCurrent() && finalCurrent <= 0) finalCurrent = 1000;
    if (origSetChargingCurrentMethod) origSetChargingCurrentMethod(self, selector, finalCurrent);
}

static void HookedSetNotChargingReason(id self, SEL selector, int reason) {
    int finalReason = reason;
    if (CanForceChargeCurrent() && finalReason == 16) finalReason = 0;
    if (origSetNotChargingReasonMethod) origSetNotChargingReasonMethod(self, selector, finalReason);
}

static void HookedSetPostChargeWaitSeconds(id self, SEL selector, int seconds) {
    int finalSeconds = CanForceChargeCurrent() ? 0 : seconds;
    if (origSetPostChargeWaitSecondsMethod) origSetPostChargeWaitSecondsMethod(self, selector, finalSeconds);
}

static char MethodArgumentCode(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return '\0';
    char type[16] = {0}; method_getArgumentType(method, index, type, sizeof(type));
    const char *cursor = type; while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor;
}

static void InstallChargingManagerHooks(void) {
    Class manager = objc_getClass("BatteryChargingManager");
    SEL currentSelector = sel_registerName("setChargingCurrent:");
    Method currentMethod = manager ? class_getInstanceMethod(manager, currentSelector) : NULL;
    if (!origSetChargingCurrentMethod && currentMethod && method_getNumberOfArguments(currentMethod) == 3 &&
        MethodArgumentCode(currentMethod, 2) == 'q') {
        MSHookMessageEx(manager, currentSelector, (IMP)HookedSetChargingCurrent, (IMP *)&origSetChargingCurrentMethod);
    }
    SEL waitSelector = sel_registerName("setPostChargeWaitSeconds:");
    Method waitMethod = manager ? class_getInstanceMethod(manager, waitSelector) : NULL;
    char waitType = MethodArgumentCode(waitMethod, 2);
    if (!origSetPostChargeWaitSecondsMethod && waitMethod && method_getNumberOfArguments(waitMethod) == 3 &&
        waitType && strchr("iI", waitType)) {
        MSHookMessageEx(manager, waitSelector, (IMP)HookedSetPostChargeWaitSeconds, (IMP *)&origSetPostChargeWaitSecondsMethod);
    }

    Class chargerData = objc_getClass("ChargerData");
    SEL reasonSelector = sel_registerName("setNotChargingReason:");
    Method reasonMethod = chargerData ? class_getInstanceMethod(chargerData, reasonSelector) : NULL;
    char reasonType = MethodArgumentCode(reasonMethod, 2);
    if (!origSetNotChargingReasonMethod && reasonMethod && method_getNumberOfArguments(reasonMethod) == 3 &&
        reasonType && strchr("iI", reasonType)) {
        MSHookMessageEx(chargerData, reasonSelector, (IMP)HookedSetNotChargingReason, (IMP *)&origSetNotChargingReasonMethod);
    }
}

static void HookIOKitSymbol(void *image, const char *name, void *replacement, void **original) {
    void *symbol = dlsym(image, name);
    if (symbol) MSHookFunction(symbol, replacement, original);
}

%ctor {
    @autoreleasepool {
        gWorkerQueue = dispatch_queue_create("com.huayuarc.cputhermal.batterytemp", DISPATCH_QUEUE_SERIAL);

        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (iokit) {
            GetRegistryEntryID = (kern_return_t (*)(io_registry_entry_t, uint64_t *))
                dlsym(iokit, "IORegistryEntryGetRegistryEntryID");
            HookIOKitSymbol(iokit, "IORegistryEntryCreateCFProperties", (void *)HookCreateProperties, (void **)&origCreateProperties);
            HookIOKitSymbol(iokit, "IORegistryEntryCreateCFProperty", (void *)HookCreateProperty, (void **)&origCreateProperty);
            HookIOKitSymbol(iokit, "IORegistryEntrySearchCFProperty", (void *)HookSearchProperty, (void **)&origSearchProperty);
            HookIOKitSymbol(iokit, "IORegistryEntrySetCFProperty", (void *)HookSetProperty, (void **)&origSetProperty);
            HookIOKitSymbol(iokit, "IORegistryEntrySetCFProperties", (void *)HookSetProperties, (void **)&origSetProperties);
        }
        ReloadPreferences();
        InstallChargingManagerHooks();

        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gSettingsToken, gWorkerQueue, ^(int token) {
            (void)token;
            ReloadPreferences();
            InstallChargingManagerHooks();
            ApplyBypassState();
        });


        gKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gWorkerQueue);
        dispatch_source_set_timer(gKeepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  2ull * NSEC_PER_SEC, 200ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gKeepAliveTimer, ^{
            // 服务对象会在 powerd/驱动重建后变化，约每 30 秒刷新一次 Registry ID。
            if ((++gKeepAliveTicks % 15u) == 0u) {
                RefreshBatteryServiceIDs();
                        }
            InstallChargingManagerHooks();
            ApplyBypassState();
        });
        dispatch_resume(gKeepAliveTimer);
        dispatch_async(gWorkerQueue, ^{ ApplyBypassState(); });
    }
}
