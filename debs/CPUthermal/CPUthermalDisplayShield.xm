// Narrow display-process thermal cap shield.
// It only prevents a learned display cap from being lowered; zero/lifecycle writes pass through.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <CPUthermalPaths.h>

static BOOL gCPUthermalDisplayShieldEnabled = NO;
static os_unfair_lock gCPUthermalDisplayCapLock = OS_UNFAIR_LOCK_INIT;
static double gCPUthermalDisplayCapNits = 0.0;
static const double kCPUthermalDisplayMinimumCapNits = 400.0;
static const double kCPUthermalDisplayFixedPointScale = 65536.0;
// 面板上限的上限：任何高于此值的读数都不可能是真实面板上限，直接丢弃。
static const double kCPUthermalDisplayMaximumPlausibleCapNits = 10000.0;

// 从 CoreBrightness 客户端读取面板原生最大亮度（滑块最大值，不受温控压低影响）。
// 用于在上限已被温控压暗时仍能拿到真实面板上限，是防降亮度通道的“锚点”。
static double CPUthermalCopyPanelMaximumNits(void) {
    const char *paths[]={
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness",NULL};
    for (int i=0;paths[i];i++) if (dlopen(paths[i], RTLD_NOW|RTLD_LOCAL)) break;
    Class cls = objc_getClass("BrightnessSystemClient");
    if (!cls) return 0.0;
    id client = nil;
    @try { client = [[cls alloc] init]; } @catch (__unused NSException *e) { return 0.0; }
    if (!client || ![client respondsToSelector:NSSelectorFromString(S("copyPropertyForKey:"))]) return 0.0;
    NSArray *keys = @[
        @"DisplayBrightnessMax", @"BrightnessMax", @"SliderMax",
        @"MaxBrightness", @"BrightnessMaxNits",
        @"DisplayBrightness", @"DisplayBrightnessLimit", @"BrightnessLimit"];
    double best = 0.0;
    for (NSString *key in keys) {
        id value = nil;
        @try { value = ((id(*)(id,SEL,id))objc_msgSend)(client, NSSelectorFromString(S("copyPropertyForKey:")), key); }
        @catch (__unused NSException *e) { value = nil; }
        if (!value || ![value respondsToSelector:@selector(doubleValue)]) continue;
        double v = [value doubleValue];
        if (v > best && v >= kCPUthermalDisplayMinimumCapNits && v <= kCPUthermalDisplayMaximumPlausibleCapNits) best = v;
    }
    return best;
}

static void CPUthermalBootstrapDisplayCap(void) {
    // 进程启动时先锚定面板上限，而不是从 0 开始。
    // 若上限已被温控压暗（如 163 nits），400 nits 下限会把所有写入都过滤掉，
    // 防降亮度通道会永远失效；先读到滑块最大值（如 1060）才能在后续写入时抬升。
    double panelMax = CPUthermalCopyPanelMaximumNits();
    if (panelMax > gCPUthermalDisplayCapNits) gCPUthermalDisplayCapNits = panelMax;
}

typedef kern_return_t (*CPUthermalRegistrySetFn)(io_registry_entry_t, CFStringRef, CFTypeRef);
typedef kern_return_t (*CPUthermalServiceSetFn)(io_service_t, CFStringRef, CFTypeRef);
static CPUthermalRegistrySetFn gCPUthermalOrigRegistrySet = NULL;
static CPUthermalServiceSetFn gCPUthermalOrigServiceSet = NULL;

static BOOL CPUthermalDisplayCapKey(CFStringRef rawKey) {
    if (!rawKey || CFGetTypeID(rawKey) != CFStringGetTypeID()) return NO;
    NSString *key = [(__bridge NSString *)rawKey lowercaseString];
    if ([key containsString:@"idle"] || [key containsString:@"sleep"] || [key containsString:@"blank"] ||
        [key containsString:@"powerstate"] || [key containsString:@"displaystate"] || [key containsString:@"proximity"]) return NO;
    if ([key isEqualToString:@"blnitscap"] || [key isEqualToString:@"brightness-nits"] ||
        [key isEqualToString:@"iomfb_brightness_limit"] || [key isEqualToString:@"max-brightness"] ||
        [key isEqualToString:@"brightness-limit"] || [key isEqualToString:@"brightness_limit"] ||
        [key isEqualToString:@"maxbrightness"] || [key isEqualToString:@"brightnesscap"]) return YES;
    BOOL brightness = [key containsString:@"brightness"] || [key containsString:@"luminance"] || [key containsString:@"nits"];
    BOOL cap = [key containsString:@"limit"] || [key containsString:@"ceiling"] || [key containsString:@"maximum"] || [key containsString:@"cap"];
    BOOL owner = [key containsString:@"thermal"] || [key containsString:@"mitigation"] || [key containsString:@"iomfb"] || [key containsString:@"backlight"] || [key containsString:@"display"];
    return brightness && cap && owner;
}

static id CPUthermalProtectedDisplayCapValue(CFTypeRef rawValue) {
    if (!rawValue) return nil;
    id value = (__bridge id)rawValue;
    if (![value respondsToSelector:@selector(doubleValue)]) return nil;
    double raw = [value doubleValue];
    if (raw <= 0.0) return nil;
    BOOL fixed = raw > kCPUthermalDisplayFixedPointScale;
    double nits = fixed ? raw / kCPUthermalDisplayFixedPointScale : raw;
    os_unfair_lock_lock(&gCPUthermalDisplayCapLock);
    if (nits >= kCPUthermalDisplayMinimumCapNits && nits <= 10000.0 && nits > gCPUthermalDisplayCapNits) gCPUthermalDisplayCapNits = nits;
    double learned = gCPUthermalDisplayCapNits;
    os_unfair_lock_unlock(&gCPUthermalDisplayCapLock);
    if (!gCPUthermalDisplayShieldEnabled || learned < kCPUthermalDisplayMinimumCapNits || nits + 0.5 >= learned) return nil;
    double replacement = fixed ? learned * kCPUthermalDisplayFixedPointScale : learned;
    if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"%.0f", replacement];
    return fixed ? @((long long)(replacement + 0.5)) : @(replacement);
}

static kern_return_t CPUthermalHookedRegistrySet(io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    id replacement = CPUthermalDisplayCapKey(key) ? CPUthermalProtectedDisplayCapValue(value) : nil;
    return gCPUthermalOrigRegistrySet ? gCPUthermalOrigRegistrySet(entry, key, replacement ? (__bridge CFTypeRef)replacement : value) : KERN_NOT_SUPPORTED;
}

static kern_return_t CPUthermalHookedServiceSet(io_service_t service, CFStringRef key, CFTypeRef value) {
    id replacement = CPUthermalDisplayCapKey(key) ? CPUthermalProtectedDisplayCapValue(value) : nil;
    return gCPUthermalOrigServiceSet ? gCPUthermalOrigServiceSet(service, key, replacement ? (__bridge CFTypeRef)replacement : value) : KERN_NOT_SUPPORTED;
}

%ctor {
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id enabled = prefs[S("enabled")];
        gCPUthermalDisplayShieldEnabled = enabled ? [enabled boolValue] : YES;
        void *registrySet = dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperty");
        void *serviceSet = dlsym(RTLD_DEFAULT, "IOServiceSetProperty");
        if (registrySet) MSHookFunction(registrySet, (void *)CPUthermalHookedRegistrySet, (void **)&gCPUthermalOrigRegistrySet);
        if (serviceSet) MSHookFunction(serviceSet, (void *)CPUthermalHookedServiceSet, (void **)&gCPUthermalOrigServiceSet);
        CPUthermalBootstrapDisplayCap();
    }
}
