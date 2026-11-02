// isolation.39: 显示路径 nits 上限学习模块（只注入 SpringBoard / backboardd /
// brightnessd / displaypolicyd）。在写入侧拦截显示限制键，把被温控压低的 nits 上限
// 抬回动态学到的面板上限；只抬不压，并且从不提交“用户亮度”。
// 不读取、不修改运行模式偏好，不触碰低功耗 2500mW / 45% / Level2 的 CPU 链。
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <CPUthermalPaths.h>

// 任何 iPhone 面板上限都远高于 400 nits；低于它的一律视为已被压低的值，不作为上限采信。
static const double kCPUthermalShieldMinimumPlausibleNits = 400.0;
static const double kCPUthermalShieldMaximumPlausibleNits = 10000.0;
// 部分显示键（如 AppleCLCD2 的 BLNitsCap）使用 16.16 定点 nits。
static const double kCPUthermalShieldFixedPointScale = 65536.0;

static BOOL gDisplayShieldEnabled = YES;
static double gLearnedNitsCeiling = 0.0;
static os_unfair_lock gNitsCeilingLock = OS_UNFAIR_LOCK_INIT;
static int gDisplayShieldSettingsToken = -1;

static const char * const kCPUthermalDisplayNitsKeys[] = {
    "BLNitsCap", "brightness-nits",
    "IOMFB_brightness_limit", "IOMFB_max_brightness", "IOMFB_brightness_max",
    "brightness-limit", "brightness_limit", "brightness-max", "brightness-cap",
    "max-brightness", "maxbrightness", "MaxBrightness", "brightnesscap", "BrightnessCap",
    NULL
};

static BOOL CPUthermalDisplayShieldIsEnabled(void) {
    return __atomic_load_n(&gDisplayShieldEnabled, __ATOMIC_ACQUIRE);
}

static void CPUthermalReloadDisplayShieldPreferences(void) {
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id value = prefs ? prefs[S("displayShieldEnabled")] : nil;
        BOOL enabled = YES;                              // 缺失 = 启用
        if ([value respondsToSelector:@selector(boolValue)]) enabled = [value boolValue];
        __atomic_store_n(&gDisplayShieldEnabled, enabled, __ATOMIC_RELEASE);
    }
}

// 0 / 生命周期 / 状态类键一律不参与：这些键的 0 表示关机或关闭指令，必须原样透传。
static BOOL CPUthermalDisplayIsLifecycleKey(NSString *key) {
    if (key.length == 0) return NO;
    NSString *lower = [key lowercaseString];
    return [lower containsString:S("idle")] || [lower containsString:S("autolock")] ||
           [lower containsString:S("lockstate")] || [lower containsString:S("sleep")] ||
           [lower containsString:S("blank")] || [lower containsString:S("screenoff")] ||
           [lower containsString:S("screen-off")] || [lower containsString:S("powerstate")] ||
           [lower containsString:S("power-state")] || [lower containsString:S("displaystate")] ||
           [lower containsString:S("screenstate")] || [lower containsString:S("wake")] ||
           [lower containsString:S("proximity")] || [lower containsString:S("backlightpower")];
}

// 只认“亮度/nits 的上限类键”，绝不匹配亮度滑块本身（用户亮度）。
static BOOL CPUthermalDisplayIsNitsLimitKey(NSString *key) {
    if (key.length == 0) return NO;
    if (CPUthermalDisplayIsLifecycleKey(key)) return NO;
    NSString *lower = [key lowercaseString];
    for (int i = 0; kCPUthermalDisplayNitsKeys[i]; i++) {
        if ([lower isEqualToString:[[NSString stringWithUTF8String:kCPUthermalDisplayNitsKeys[i]] lowercaseString]]) return YES;
    }
    BOOL brightnessValue = [lower containsString:S("brightness")] ||
                           [lower containsString:S("luminance")] ||
                           [lower containsString:S("nits")];
    BOOL explicitCap = [lower containsString:S("limit")] ||
                       [lower containsString:S("ceiling")] ||
                       [lower containsString:S("maximum")] ||
                       [lower containsString:S("max-")] ||
                       [lower containsString:S("cap")];
    BOOL displayOwner = [lower containsString:S("iomfb")] ||
                        [lower containsString:S("backlight")] ||
                        [lower containsString:S("display")];
    return brightnessValue && explicitCap && displayOwner;
}

// 原始值 → 可信 nits（同时兼容 16.16 定点）；不可信返回 0。
static double CPUthermalDisplayPlausibleNits(double raw) {
    if (!(raw > 0.0)) return 0.0;
    double nits = raw;
    if (raw > kCPUthermalShieldFixedPointScale) {
        double decoded = raw / kCPUthermalShieldFixedPointScale;
        if (decoded >= kCPUthermalShieldMinimumPlausibleNits &&
            decoded <= kCPUthermalShieldMaximumPlausibleNits) {
            nits = decoded;
        }
    }
    if (nits < kCPUthermalShieldMinimumPlausibleNits ||
        nits > kCPUthermalShieldMaximumPlausibleNits) return 0.0;
    return nits;
}

static void CPUthermalRememberNitsCeiling(double nits) {
    if (nits < kCPUthermalShieldMinimumPlausibleNits ||
        nits > kCPUthermalShieldMaximumPlausibleNits) return;
    os_unfair_lock_lock(&gNitsCeilingLock);
    if (nits > gLearnedNitsCeiling) gLearnedNitsCeiling = nits;
    os_unfair_lock_unlock(&gNitsCeilingLock);
}

static double CPUthermalLearnedNitsCeiling(void) {
    os_unfair_lock_lock(&gNitsCeilingLock);
    double ceiling = gLearnedNitsCeiling;
    os_unfair_lock_unlock(&gNitsCeilingLock);
    return ceiling;
}

static BOOL CPUthermalDisplayNumberFromCF(CFTypeRef value, double *out) {
    if (!value) return NO;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFNumberGetTypeID()) {
        double number = 0.0;
        if (!CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number)) return NO;
        if (out) *out = number;
        return YES;
    }
    if (type == CFStringGetTypeID()) {
        const char *utf8 = [(__bridge NSString *)value UTF8String];
        if (!utf8 || !*utf8) return NO;
        char *end = NULL;
        double parsed = strtod(utf8, &end);
        if (end == utf8) return NO;
        while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r') end++;
        if (*end != '\0') return NO;                     // 带单位/尾随内容：视为未知值，透传
        if (out) *out = parsed;
        return YES;
    }
    return NO;
}

// 返回 nil 表示原样透传；返回对象表示替换写入值（只抬不压）。
static id CPUthermalDisplayReplacement(NSString *key, CFTypeRef value) {
    if (!CPUthermalDisplayIsNitsLimitKey(key)) return nil;
    double raw = 0.0;
    if (!CPUthermalDisplayNumberFromCF(value, &raw)) return nil;   // 未知类型/无法解析：透传
    if (!(raw > 0.0)) return nil;                                  // 0 = 关机/关闭指令：透传
    double observed = CPUthermalDisplayPlausibleNits(raw);
    if (observed > 0.0) CPUthermalRememberNitsCeiling(observed);   // 动态学习 400–10000 nits 上限
    double ceiling = CPUthermalLearnedNitsCeiling();
    if (ceiling <= 0.0) return nil;                                // 尚未学到上限：透传
    BOOL fixedPoint = (raw > kCPUthermalShieldFixedPointScale);
    double candidate = fixedPoint ? ceiling * kCPUthermalShieldFixedPointScale : ceiling;
    if (raw + 0.5 >= candidate) return nil;                        // 已不低于上限：不写，绝不反向压暗
    if (CFGetTypeID(value) == CFStringGetTypeID()) return [NSString stringWithFormat:@"%.0f", candidate];
    return @(candidate);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    if (!key || !value || !CPUthermalDisplayShieldIsEnabled()) return %orig(entry, key, value);
    id replacement = CPUthermalDisplayReplacement((__bridge NSString *)key, value);
    if (replacement) return %orig(entry, key, (__bridge CFTypeRef)replacement);
    return %orig(entry, key, value);
}

// IOServiceSetProperty 不在 IOKit 头文件中，必须像核心模块一样从 IOKit 动态解析后 MSHookFunction。
typedef kern_return_t (*CPUthermalIOServiceSetPropertyFn)(io_service_t, CFStringRef, CFTypeRef);
static CPUthermalIOServiceSetPropertyFn gOriginalIOServiceSetProperty = NULL;

static kern_return_t CPUthermalHookedIOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (!gOriginalIOServiceSetProperty) return KERN_FAILURE;
    if (!key || !value || !CPUthermalDisplayShieldIsEnabled()) return gOriginalIOServiceSetProperty(service, key, value);
    id replacement = CPUthermalDisplayReplacement((__bridge NSString *)key, value);
    return gOriginalIOServiceSetProperty(service, key, replacement ? (__bridge CFTypeRef)replacement : value);
}

static void CPUthermalInstallIOServiceSetPropertyHook(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!iokit) return;
    void *symbol = dlsym(iokit, "IOServiceSetProperty");
    if (!symbol) return;
    MSHookFunction(symbol, (void *)CPUthermalHookedIOServiceSetProperty,
                   (void **)&gOriginalIOServiceSetProperty);
}

%ctor {
    @autoreleasepool {
        CPUthermalReloadDisplayShieldPreferences();
        CPUthermalInstallIOServiceSetPropertyHook();
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.cputhermal.display-shield.prefs",
                                                       DISPATCH_QUEUE_SERIAL);
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gDisplayShieldSettingsToken,
                                 queue, ^(int token) {
            (void)token;
            CPUthermalReloadDisplayShieldPreferences();
        });
    }
}
