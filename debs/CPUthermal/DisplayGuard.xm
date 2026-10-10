// CPUthermalDisplay — IOKit brightness-write guard (backboardd / SpringBoard).
// Only verified 16.16 keys are rewritten. This does NOT bypass firmware protection.
// Slider -> nits is a linear heuristic, not a calibrated panel transfer curve.
// Power-mode selection is not an input: CPU policy must not select brightness.

#import <Foundation/Foundation.h>
#include <string.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <math.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <notify.h>
#import <CPUthermalPaths.h>
#include <pthread.h>

#include <substrate.h>

// All state shared by hook threads is protected; recursion is per-thread.
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static __thread unsigned int gWriteDepth = 0;
struct WriteScope { WriteScope() { ++gWriteDepth; } ~WriteScope() { --gWriteDepth; } };
static double gSliderTime = -1.0;
static double gSlider = -1.0;
static int gLockToken = -1, gDisplayToken = -1;
static int64_t gCapTargetRaw = 0;
static io_registry_entry_t gCapNode = IO_OBJECT_NULL;
static double Now(void) { return [NSProcessInfo processInfo].systemUptime; }
static int64_t NitsToRaw(double nits) { return (int64_t)llround(nits * 65536.0); }
static double RawToNits(int64_t raw) { return (double)raw / 65536.0; }

// No getValue: CFNumberGetValue performs conversion, not byte reinterpretation.
static BOOL NumberDouble(CFTypeRef value, double *out) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return NO;
    double n = 0.0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &n) || !isfinite(n)) return NO;
    *out = n;
    return YES;
}
static BOOL NumberRaw(CFTypeRef value, int64_t *out) {
    double n = 0.0;
    if (!NumberDouble(value, &n) || n < 0.0 || n > 20000.0 * 65536.0 || floor(n) != n) return NO;
    return CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, out);
}
static BOOL BrightnessProtectionEnabled(void) {
    // Match main module: loadPrefs forces enabled=YES, including legacy false.
    return YES;
}
static void InvalidateCaches(BOOL prefs) {
    pthread_mutex_lock(&gStateLock);
    (void)prefs;
    gSliderTime = -1.0;
    pthread_mutex_unlock(&gStateLock);
}
static BOOL ScreenIsActive(void) {
    uint64_t locked = 1, blanked = 1;
    // Missing/failed/unknown notification states fail closed.
    return gLockToken >= 0 && gDisplayToken >= 0 &&
        notify_get_state(gLockToken, &locked) == NOTIFY_STATUS_OK && locked == 0 &&
        notify_get_state(gDisplayToken, &blanked) == NOTIFY_STATUS_OK && blanked == 0;
}

// Read current slider, never a cached historic Nits request or NitsPhysical.
// copyPropertyForKey: returns +1 ownership despite dispatch via objc_msgSend.
static double ReadSlider(void) {
    @try {
        Class cls = objc_getClass("BrightnessSystemClient");
        id client = cls ? [[cls alloc] init] : nil;
        SEL sel = sel_registerName("copyPropertyForKey:");
        if ([client respondsToSelector:sel]) {
            CFTypeRef copied = ((CFTypeRef (*)(id, SEL, id))objc_msgSend)(client, sel, S("DisplayBrightness"));
            id display = CFBridgingRelease(copied);
            if ([display isKindOfClass:[NSDictionary class]]) {
                double level = -1.0;
                if (NumberDouble((__bridge CFTypeRef)display[S("Brightness")], &level) && level >= 0.0 && level <= 1.0) return level;
            }
        }
        // Live CoreBrightness slider takes priority over persisted defaults.
        NSUserDefaults *sb = [[NSUserDefaults alloc] initWithSuiteName:S("com.apple.springboard")];
        for (NSString *key in @[@"SBBacklightLevel2", @"SBBacklightLevel", @"SBBacklightLevel3"]) {
            id value = [sb objectForKey:key];
            double level = -1.0;
            if (NumberDouble((__bridge CFTypeRef)value, &level) && level >= 0.0 && level <= 1.0) return level;
        }
    } @catch (__unused NSException *e) { }
    return -1.0;
}
static double UserSlider(void) {
    pthread_mutex_lock(&gStateLock);
    double now = Now();
    if (gSliderTime < 0.0 || now - gSliderTime >= 0.2) {
        gSlider = ReadSlider();
        gSliderTime = now;
    }
    double level = gSlider;
    pthread_mutex_unlock(&gStateLock);
    return level;
}

// Exact keys, exact units. No substring/case folding or guessed IOConnect selector.
// Other cap-like keys can use normalized brightness or different units: leave alone.
enum KeyKind { KeyOther, KeyCap, KeyNits };
static KeyKind BrightnessKey(CFTypeRef key) {
    if (!key || CFGetTypeID(key) != CFStringGetTypeID()) return KeyOther;
    if (CFEqual(key, CFSTR("BLNitsCap"))) return KeyCap;
    if (CFEqual(key, CFSTR("brightness-nits"))) return KeyNits;
    return KeyOther;
}
static CFTypeRef NodeCopyProperty(io_registry_entry_t entry, CFStringRef key) {
    return entry ? IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0) : NULL;
}

// Unknown devices require a declared panel capability, not a thermal cap/output.
// 300..3000 nits includes 625/800 devices without the old fixed 850-nit floor.
static double PanelMaxNitsFromRegistry(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane,
            kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS || !iterator) return 0.0;
    double best = 0.0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS &&
            (strstr(name, "AppleCLCD") || strstr(name, "AppleARMBacklight") || strstr(name, "IOMobileFramebuffer"))) {
            for (NSString *key in @[@"PanelMaxBrightness", @"nitsMax", @"IOMFB_max_brightness", @"IOMFB_brightness_max"]) {
                CFTypeRef value = NodeCopyProperty(entry, (__bridge CFStringRef)key);
                double n = 0.0;
                BOOL numeric = NumberDouble(value, &n);
                if (value) CFRelease(value);
                // Accept declared nits or integral 16.16; never normalized 0..1.
                if (numeric && n > 65536.0 && floor(n) == n) n /= 65536.0;
                if (numeric && n >= 300.0 && n <= 3000.0 && n > best) best = n;
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return best;
}

static double PanelMaxNitsForCurrentDevice(void) {
    static NSDictionary *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @"iPhone9,1":@625, @"iPhone9,3":@625, @"iPhone9,2":@625, @"iPhone9,4":@625,
            @"iPhone10,1":@625, @"iPhone10,4":@625, @"iPhone10,2":@625, @"iPhone10,5":@625,
            @"iPhone10,3":@625, @"iPhone10,6":@625,
            @"iPhone11,2":@625, @"iPhone11,4":@625, @"iPhone11,6":@625, @"iPhone11,8":@625,
            @"iPhone12,1":@625, @"iPhone12,3":@800, @"iPhone12,5":@800,
            @"iPhone13,1":@625, @"iPhone13,2":@625, @"iPhone13,3":@800, @"iPhone13,4":@800,
            @"iPhone14,4":@800, @"iPhone14,5":@800, @"iPhone14,2":@850, @"iPhone14,3":@850,
            @"iPhone14,7":@800, @"iPhone14,8":@800, @"iPhone15,2":@1000, @"iPhone15,3":@1000,
            @"iPhone15,4":@1000, @"iPhone15,5":@1000, @"iPhone16,1":@1000, @"iPhone16,2":@1000,
            @"iPhone17,1":@1000, @"iPhone17,2":@1000, @"iPhone17,3":@1000, @"iPhone17,4":@1000,
        };
    });
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size < 2) return 0.0;
    char *model = (char *)calloc(1, size);
    if (!model) return 0.0;
    double nits = 0.0;
    if (sysctlbyname("hw.machine", model, &size, NULL, 0) == 0) {
        NSNumber *value = table[[NSString stringWithUTF8String:model]];
        if ([value isKindOfClass:[NSNumber class]]) nits = [value doubleValue];
    }
    free(model);
    return nits;
}

static void AdoptPanelMaximum(void) {
    // Table is a conservative sustained-output estimate, not physical telemetry.
    double nits = PanelMaxNitsForCurrentDevice();
    if (!(nits >= 300.0 && nits <= 3000.0)) nits = PanelMaxNitsFromRegistry();
    gCapTargetRaw = nits >= 300.0 && nits <= 3000.0 ? NitsToRaw(nits) : 0;
    // Initialized before hooking; immutable afterwards. No persisted physical maxima.
}

static BOOL DesiredRaw(KeyKind kind, int64_t input, int64_t *output) {
    if (kind == KeyOther || !BrightnessProtectionEnabled() || !ScreenIsActive() || gCapTargetRaw <= 0) return NO;
    double slider = UserSlider();
    // Unknown/real zero/low slider: do not lift output, including a true off write.
    // <=2% intentionally remains completely untouched; no historic high-water mark.
    if (!(slider > 0.02 && slider <= 1.0)) return NO;
    int64_t target = kind == KeyCap ? gCapTargetRaw : NitsToRaw(RawToNits(gCapTargetRaw) * slider);
    // brightness-nits == 0 may be a power-off command, so never replace it.
    if (kind == KeyNits && (input == 0 || target - input <= NitsToRaw(1.0))) return NO;
    if (input >= target) return NO;   // do not lower legitimate/HDR values
    *output = target;
    return YES;
}

// Shared by all three entry points. Create rule: caller must release replacement.
// Only CFNumbers with integral nonnegative raw values are accepted; strings/data
// and unrelated dictionaries retain their original identity, not a shallow copy.
static CFNumberRef CopyReplacement(CFTypeRef key, CFTypeRef value) {
    KeyKind kind = BrightnessKey(key);   // key match BEFORE prefs/slider reads
    if (kind == KeyOther) return NULL;
    int64_t input = 0, output = 0;
    if (!NumberRaw(value, &input) || !DesiredRaw(kind, input, &output)) return NULL;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &output);
}

static kern_return_t (*OrigServiceSet)(io_service_t, CFStringRef, CFTypeRef) = NULL;
static kern_return_t (*OrigRegistrySet)(io_registry_entry_t, CFStringRef, CFTypeRef) = NULL;
static kern_return_t (*OrigRegistrySetMany)(io_registry_entry_t, CFTypeRef) = NULL;

static kern_return_t GuardServiceSet(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (gWriteDepth) return OrigServiceSet(service, key, value);
    WriteScope scope;
    CFNumberRef replacement = NULL;
    @try { replacement = CopyReplacement(key, value); } @catch (__unused NSException *e) { }
    kern_return_t result = OrigServiceSet(service, key, replacement ? replacement : value);
    if (replacement) {

        CFRelease(replacement);
    }
    return result;
}
static kern_return_t GuardRegistrySet(io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    if (gWriteDepth) return OrigRegistrySet(entry, key, value);
    WriteScope scope;
    CFNumberRef replacement = NULL;
    @try { replacement = CopyReplacement(key, value); } @catch (__unused NSException *e) { }
    kern_return_t result = OrigRegistrySet(entry, key, replacement ? replacement : value);
    if (replacement) {

        CFRelease(replacement);
    }
    return result;
}
struct DictionaryChanges { CFDictionaryRef original; CFMutableDictionaryRef changed; };
static void ReplaceDictionaryValue(const void *key, const void *value, void *context) {
    DictionaryChanges *changes = (DictionaryChanges *)context;
    CFNumberRef replacement = CopyReplacement((CFTypeRef)key, (CFTypeRef)value);
    if (!replacement) return;
    if (!changes->changed)
        changes->changed = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, changes->original);
    if (changes->changed) CFDictionarySetValue(changes->changed, key, replacement);
    CFRelease(replacement);
}
static kern_return_t GuardRegistrySetMany(io_registry_entry_t entry, CFTypeRef properties) {
    if (gWriteDepth) return OrigRegistrySetMany(entry, properties);
    WriteScope scope;
    DictionaryChanges changes = {NULL, NULL};
    @try {
        if (properties && CFGetTypeID(properties) == CFDictionaryGetTypeID()) {
            changes.original = (CFDictionaryRef)properties;
            CFDictionaryApplyFunction(changes.original, ReplaceDictionaryValue, &changes);
        }
    } @catch (__unused NSException *e) {
        if (changes.changed) CFRelease(changes.changed);
        changes.changed = NULL;    // fail open: no partially rewritten payload
    }
    kern_return_t result = OrigRegistrySetMany(entry, changes.changed ? (CFTypeRef)changes.changed : properties);
    if (changes.changed) {
        CFRelease(changes.changed);
    }
    return result;
}

// Public registry APIs + optional IOServiceSetProperty (same 3-argument CF ABI).
// Resolve only from IOKit; never guess private symbols.
static void InstallWriteHooks(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!iokit) return;
    void *service = dlsym(iokit, "IOServiceSetProperty");
    void *single = dlsym(iokit, "IORegistryEntrySetCFProperty");
    void *many = dlsym(iokit, "IORegistryEntrySetCFProperties");
    if (service) MSHookFunction(service, (void *)&GuardServiceSet, (void **)&OrigServiceSet);
    if (single) MSHookFunction(single, (void *)&GuardRegistrySet, (void **)&OrigRegistrySet);
    if (many) MSHookFunction(many, (void *)&GuardRegistrySetMany, (void **)&OrigRegistrySetMany);

    // Keep framework loaded for trampoline lifetime.
}

// Only cap self-check, at 3 s. No polling/committing CoreBrightness actual output.
static io_registry_entry_t CapNode(void) {
    if (gCapNode) {
        CFTypeRef value = NodeCopyProperty(gCapNode, CFSTR("BLNitsCap"));
        BOOL valid = value != NULL;
        if (value) CFRelease(value);
        if (valid) return gCapNode;
        IOObjectRelease(gCapNode);
        gCapNode = IO_OBJECT_NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane,
            kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS || !iterator) return IO_OBJECT_NULL;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        CFTypeRef value = NodeCopyProperty(entry, CFSTR("BLNitsCap"));
        if (value) { CFRelease(value); gCapNode = entry; break; }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return gCapNode;
}
static void EnforcePanelCap(void) {
    if (gWriteDepth) return;
    WriteScope scope;   // our write must not re-enter any of the three policies
    @try {
        if (!BrightnessProtectionEnabled() || !ScreenIsActive() || gCapTargetRaw <= 0) return;
        double slider = UserSlider();
        if (!(slider > 0.02 && slider <= 1.0)) return;
        io_registry_entry_t entry = CapNode();
        if (!entry) return;
        CFTypeRef value = NodeCopyProperty(entry, CFSTR("BLNitsCap"));
        int64_t raw = 0, desired = 0;
        BOOL numeric = NumberRaw(value, &raw);
        if (value) CFRelease(value);
        if (!numeric || !DesiredRaw(KeyCap, raw, &desired)) return;
        CFNumberRef replacement = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &desired);
        if (!replacement) return;
        IORegistryEntrySetCFProperty(entry, CFSTR("BLNitsCap"), replacement);
        CFRelease(replacement);

    } @catch (__unused NSException *e) { }
}
static void BrightnessGuardTick(void) {
    @autoreleasepool { EnforcePanelCap(); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ BrightnessGuardTick(); });
}

%ctor {
    @autoreleasepool {
        // Register check tokens for state reads, separate dispatch tokens for invalidation.
        if (notify_register_check("com.apple.springboard.lockstate", &gLockToken) != NOTIFY_STATUS_OK) gLockToken = -1;
        if (notify_register_check("com.apple.springboard.hasBlankedScreen", &gDisplayToken) != NOTIFY_STATUS_OK) gDisplayToken = -1;
        static int settingsToken = 0, sliderToken = 0, lockEventToken = 0, displayEventToken = 0;
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &settingsToken, queue, ^(int token) {
            (void)token; InvalidateCaches(YES);
        });
        notify_register_dispatch("com.apple.springboard.brightness", &sliderToken, queue, ^(int token) {
            (void)token; InvalidateCaches(NO);
        });
        notify_register_dispatch("com.apple.springboard.lockstate", &lockEventToken, queue, ^(int token) {
            (void)token; InvalidateCaches(NO);
        });
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &displayEventToken, queue, ^(int token) {
            (void)token; InvalidateCaches(NO);
        });
        AdoptPanelMaximum();
        InstallWriteHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), queue, ^{ BrightnessGuardTick(); });
    }
}
