#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <CPUthermalPaths.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static BOOL simulationEnabled(void) { return CPUthermalMaximumCapacityState(); }

static BOOL keyContains(NSString *key, const char *token) {
    return [key rangeOfString:S(token) options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL healthPercentKey(NSString *key) {
    return keyContains(key, "batteryhealth") || keyContains(key, "healthpercent") ||
           keyContains(key, "maximumcapacitypercent") || keyContains(key, "maxcapacitypercent");
}

static BOOL maximumChargeKey(NSString *key) {
    if (keyContains(key, "current") || keyContains(key, "remaining") ||
        keyContains(key, "instant") || keyContains(key, "cycle") ||
        [key caseInsensitiveCompare:S("MaxCapacity")] == NSOrderedSame) return NO;
    return keyContains(key, "nominalchargecapacity") || keyContains(key, "applerawmaxcapacity") ||
           keyContains(key, "maximumcapacity") || keyContains(key, "fullchargecapacity") ||
           keyContains(key, "fcccomp") || [key caseInsensitiveCompare:S("Qmax")] == NSOrderedSame;
}

static NSNumber *designCapacityFromDictionary(NSDictionary *dict) {
    static const char *keys[] = {"DesignCapacity", "AppleRawDesignCapacity", "designCapacity"};
    for (NSUInteger i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) {
        id value = dict[S(keys[i])];
        if ([value isKindOfClass:[NSNumber class]] && [value longLongValue] > 0) return value;
    }
    return nil;
}

static id capacityValueLike(id original, NSNumber *design) {
    if ([original isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[original count]];
        for (NSUInteger i = 0; i < [original count]; i++) [result addObject:design];
        return result;
    }
    return design;
}

static id patchBatteryNode(id node, NSNumber *inheritedDesign) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *source = node;
        NSMutableDictionary *result = [source mutableCopy];
        NSNumber *design = designCapacityFromDictionary(source) ?: inheritedDesign;
        for (id rawKey in [source allKeys]) {
            id value = source[rawKey];
            if (![rawKey isKindOfClass:[NSString class]]) {
                result[rawKey] = patchBatteryNode(value, design) ?: value;
                continue;
            }
            NSString *key = rawKey;
            if (healthPercentKey(key)) result[key] = [NSNumber numberWithInt:100];
            else if ([key caseInsensitiveCompare:S("MaxCapacity")] == NSOrderedSame) result[key] = [NSNumber numberWithInt:100];
            else if (design && maximumChargeKey(key)) result[key] = capacityValueLike(value, design);
            else result[key] = patchBatteryNode(value, design) ?: value;
        }
        return result;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[node count]];
        for (id value in node) [result addObject:patchBatteryNode(value, inheritedDesign) ?: value];
        return result;
    }
    return node;
}

static CFTypeRef patchProperty(CFStringRef keyRef, CFTypeRef value) {
    if (!simulationEnabled() || !keyRef || !value) return value ? CFRetain(value) : NULL;
    NSString *key = (__bridge NSString *)keyRef;
    if (healthPercentKey(key) || [key caseInsensitiveCompare:S("MaxCapacity")] == NSOrderedSame)
        return CFRetain((__bridge CFTypeRef)[NSNumber numberWithInt:100]);
    if (CFGetTypeID(value) == CFDictionaryGetTypeID() || CFGetTypeID(value) == CFArrayGetTypeID()) {
        id patched = patchBatteryNode((__bridge id)value, nil);
        return (CFTypeRef)CFBridgingRetain(patched);
    }
    return CFRetain(value);
}

static CFDictionaryRef patchDictionary(CFDictionaryRef properties) {
    if (!properties) return NULL;
    if (!simulationEnabled()) return (CFDictionaryRef)CFRetain(properties);
    id patched = patchBatteryNode((__bridge NSDictionary *)properties, nil);
    return (CFDictionaryRef)CFBridgingRetain(patched);
}

static CFTypeRef (*origCreateProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef hookedCreateProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef value = origCreateProperty(entry, key, allocator, options);
    if (!value || !simulationEnabled()) return value;
    NSString *keyString = (__bridge NSString *)key;
    if (maximumChargeKey(keyString)) {
        static const char *designNames[] = {"DesignCapacity", "AppleRawDesignCapacity"};
        for (NSUInteger i = 0; i < 2; i++) {
            CFStringRef designKey = CFStringCreateWithCString(kCFAllocatorDefault, designNames[i], kCFStringEncodingUTF8);
            CFTypeRef design = origCreateProperty(entry, designKey, allocator, options);
            if (designKey) CFRelease(designKey);
            if (design && CFGetTypeID(design) == CFNumberGetTypeID()) {
                CFRelease(value);
                return design;
            }
            if (design) CFRelease(design);
        }
    }
    CFTypeRef patched = patchProperty(key, value);
    CFRelease(value);
    return patched;
}

static CFTypeRef (*origSearchProperty)(io_registry_entry_t, const io_name_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef hookedSearchProperty(io_registry_entry_t entry, const io_name_t plane, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef value = origSearchProperty(entry, plane, key, allocator, options);
    if (!value || !simulationEnabled()) return value;
    NSString *keyString = (__bridge NSString *)key;
    if (maximumChargeKey(keyString)) {
        static const char *designNames[] = {"DesignCapacity", "AppleRawDesignCapacity"};
        for (NSUInteger i = 0; i < 2; i++) {
            CFStringRef designKey = CFStringCreateWithCString(kCFAllocatorDefault, designNames[i], kCFStringEncodingUTF8);
            CFTypeRef design = origSearchProperty(entry, plane, designKey, allocator, options);
            if (designKey) CFRelease(designKey);
            if (design && CFGetTypeID(design) == CFNumberGetTypeID()) {
                CFRelease(value);
                return design;
            }
            if (design) CFRelease(design);
        }
    }
    CFTypeRef patched = patchProperty(key, value);
    CFRelease(value);
    return patched;
}

static kern_return_t (*origCreateProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits);
static kern_return_t hookedCreateProperties(io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, IOOptionBits options) {
    kern_return_t result = origCreateProperties(entry, properties, allocator, options);
    if (result != KERN_SUCCESS || !properties || !*properties || !simulationEnabled()) return result;
    CFDictionaryRef patched = patchDictionary(*properties);
    CFRelease(*properties);
    *properties = (CFMutableDictionaryRef)patched;
    return result;
}

static BOOL excludedProcess(void) {
    NSString *name = [[NSProcessInfo processInfo] processName];
    static const char *excluded[] = {"powerd", "thermalmonitord", "batteryintelligenced", "aggregated", "diagnosticd"};
    for (NSUInteger i = 0; i < sizeof(excluded)/sizeof(excluded[0]); i++) {
        if ([name caseInsensitiveCompare:S(excluded[i])] == NSOrderedSame) return YES;
    }
    return NO;
}

%ctor {
    if (excludedProcess()) return;
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) return;
    void *property = dlsym(handle, "IORegistryEntryCreateCFProperty");
    void *properties = dlsym(handle, "IORegistryEntryCreateCFProperties");
    void *search = dlsym(handle, "IORegistryEntrySearchCFProperty");
    if (property) MSHookFunction(property, (void *)hookedCreateProperty, (void **)&origCreateProperty);
    if (properties) MSHookFunction(properties, (void *)hookedCreateProperties, (void **)&origCreateProperties);
    if (search) MSHookFunction(search, (void *)hookedSearchProperty, (void **)&origSearchProperty);
    NSLog(@"[CPUthermalBatteryData] hooked process=%@", [[NSProcessInfo processInfo] processName]);
}
