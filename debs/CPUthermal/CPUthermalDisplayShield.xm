// Narrow display-process thermal cap shield.
// It only prevents a learned display cap from being lowered; zero/lifecycle writes pass through.
//
// isolation.45 黑屏修复：本 dylib 会注入 backboardd，而 backboardd 自身承载亮度 XPC 服务。
// 早期版本在 %ctor 里实例化 BrightnessSystemClient（CoreBrightness）取面板最大亮度，
// 等于在服务端进程加载期同步调用它自己的服务，直接死锁 -> 开机/注销后黑屏。
// 现在 %ctor 里绝不做任何 XPC / dlopen：面板上限改用 IORegistry 本地读取，
// 且只在第一次真正需要抬高上限时做一次，失败也不影响任何写入。
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <os/log.h>
#import <CPUthermalPaths.h>

// iOS 上没有可用的 kIOMasterPortDefault 常量（被标记为 unavailable），
// 与本工程其它文件一致，统一用空的 master port 走默认内核端口。
#define kIOMasterPortDefault MACH_PORT_NULL

static BOOL gCPUthermalDisplayShieldEnabled = NO;
static os_unfair_lock gCPUthermalDisplayCapLock = OS_UNFAIR_LOCK_INIT;
static double gCPUthermalDisplayCapNits = 0.0;
static const double kCPUthermalDisplayMinimumCapNits = 600.0;
static const double kCPUthermalDisplayFixedPointScale = 65536.0;
// 面板上限的上限：任何高于此值的读数都不可能是真实面板上限，直接丢弃。
static const double kCPUthermalDisplayMaximumPlausibleCapNits = 10000.0;

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

// 只读的本地锚点：从显示的 IORegistry 节点读取面板原生最大亮度（nits）。
// 纯内核属性读取，不发任何跨进程消息，可在 backboardd 里安全调用。
static double CPUthermalRegistryPanelMaximumNits(void) {
    static const char * const kServices[] = {
        "AppleCLCD2", "AppleCLCD", "AppleDCP", "IOMobileFramebuffer",
        "AppleDisplay", "AppleBacklightDisplay", NULL};
    static const char * const kKeys[] = {
        "IOMFB_max_brightness", "IOMFB_brightness_max", "IOMFB_maxBrightness",
        "max-brightness", "MaxBrightness", "brightness-max", NULL};
    double best = 0.0;
    for (int s = 0; kServices[s]; s++) {
        CFMutableDictionaryRef matching = IOServiceMatching(kServices[s]);
        if (!matching) continue;
        io_iterator_t iterator = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS ||
            iterator == IO_OBJECT_NULL) continue;
        io_registry_entry_t entry;
        while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            for (int k = 0; kKeys[k]; k++) {
                CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, kKeys[k], kCFStringEncodingUTF8);
                if (!key) continue;
                CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
                if (value) {
                    if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID()) {
                        double raw = [(__bridge id)value doubleValue];
                        double nits = raw > kCPUthermalDisplayFixedPointScale ? raw / kCPUthermalDisplayFixedPointScale : raw;
                        if (nits >= kCPUthermalDisplayMinimumCapNits && nits <= kCPUthermalDisplayMaximumPlausibleCapNits && nits > best) best = nits;
                    }
                    CFRelease(value);
                }
                CFRelease(key);
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }
    return best;
}

// 惰性锚定：只在第一次需要判断“是否被压低”时做一次本地读取。
// 绝不在 %ctor 里执行，避免拖慢/阻塞任何被注入进程的启动。
static double CPUthermalDisplayLearnedCap(void) {
    os_unfair_lock_lock(&gCPUthermalDisplayCapLock);
    double learned = gCPUthermalDisplayCapNits;
    os_unfair_lock_unlock(&gCPUthermalDisplayCapLock);
    if (learned >= kCPUthermalDisplayMinimumCapNits) return learned;
    @try {
        double panelMax = CPUthermalRegistryPanelMaximumNits();
        if (panelMax >= kCPUthermalDisplayMinimumCapNits) {
            os_unfair_lock_lock(&gCPUthermalDisplayCapLock);
            if (panelMax > gCPUthermalDisplayCapNits) gCPUthermalDisplayCapNits = panelMax;
            learned = gCPUthermalDisplayCapNits;
            os_unfair_lock_unlock(&gCPUthermalDisplayCapLock);
        }
    } @catch (__unused NSException *e) { }
    return learned;
}

static id CPUthermalProtectedDisplayCapValue(CFTypeRef rawValue) {
    if (!rawValue) return nil;
    id value = (__bridge id)rawValue;
    if (![value respondsToSelector:@selector(doubleValue)]) return nil;
    double raw = [value doubleValue];
    if (raw <= 0.0) return nil;
    BOOL fixed = raw > kCPUthermalDisplayFixedPointScale;
    double nits = fixed ? raw / kCPUthermalDisplayFixedPointScale : raw;
    if (nits >= kCPUthermalDisplayMinimumCapNits && nits <= kCPUthermalDisplayMaximumPlausibleCapNits) {
        os_unfair_lock_lock(&gCPUthermalDisplayCapLock);
        if (nits > gCPUthermalDisplayCapNits) gCPUthermalDisplayCapNits = nits;
        os_unfair_lock_unlock(&gCPUthermalDisplayCapLock);
    }
    double learned = CPUthermalDisplayLearnedCap();
    if (!gCPUthermalDisplayShieldEnabled || learned < kCPUthermalDisplayMinimumCapNits || nits + 0.5 >= learned) return nil;
    double replacement = fixed ? learned * kCPUthermalDisplayFixedPointScale : learned;
    if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"%.0f", replacement];
    return fixed ? @((long long)(replacement + 0.5)) : @(replacement);
}

// isolation.57：热压暗的“事前拦截”。
// 系统（thermalmonitord / CoreBrightness 的温度缓解）压暗面板时，写进来的是面板亮度级
// 从满档直接跌到 90% 以下的断崖；用户自己拖滑块是连续小步，不会这样跳。
// 判据全部用本地 IORegistry 读取（不做任何跨进程调用，backboardd 内安全）：
//   - 面板上限 cap >= 400 nits；
//   - 节点当前值 >= cap 的 90%（原本满档）；
//   - 新值 < cap 的 90%；
//   - 面板温度 >= 36°C（温控压暗的必要条件）。
// 命中就丢弃这次写入（返回 KERN_SUCCESS，一个值都不写），屏幕不会暗下去。
static const double kShieldSuppressTemperatureC = 36.0;
static const double kShieldSuppressTopRatio = 0.90;

static double CPUthermalNitsFromRaw(CFTypeRef value) {
    if (!value) return 0.0;
    if (CFGetTypeID(value) != CFNumberGetTypeID() && CFGetTypeID(value) != CFStringGetTypeID()) return 0.0;
    double raw = [(__bridge id)value doubleValue];
    if (raw <= 0.0) return 0.0;
    return raw > kCPUthermalDisplayFixedPointScale ? raw / kCPUthermalDisplayFixedPointScale : raw;
}

static double CPUthermalPanelTemperatureC(void) {
    static const char * const kClasses[] = {"AppleCLCD2", "AppleCLCD", "AppleDCP", NULL};
    for (int c = 0; kClasses[c]; c++) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(kClasses[c]));
        if (!service) continue;
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("APTPDCTemperature"), kCFAllocatorDefault, 0);
        double temp = CPUthermalNitsFromRaw(value);
        if (value) CFRelease(value);
        IOObjectRelease(service);
        if (temp > 0.0) return temp;
    }
    return -1.0;
}

static BOOL CPUthermalIsPanelLevelKey(CFStringRef rawKey) {
    if (!rawKey || CFGetTypeID(rawKey) != CFStringGetTypeID()) return NO;
    return [[(__bridge NSString *)rawKey lowercaseString] isEqualToString:@"iomfbbrightnesslevel"];
}

static BOOL CPUthermalShouldSuppressLevelDrop(io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    if (!gCPUthermalDisplayShieldEnabled || !CPUthermalIsPanelLevelKey(key)) return NO;
    double next = CPUthermalNitsFromRaw(value);
    if (next <= 0.0) return NO;   // 关机/关屏/关闭指令一律放行
    CFTypeRef capRaw = IORegistryEntryCreateCFProperty(entry, CFSTR("BLNitsCap"), kCFAllocatorDefault, 0);
    double cap = CPUthermalNitsFromRaw(capRaw);
    if (capRaw) CFRelease(capRaw);
    if (cap < kCPUthermalDisplayMinimumCapNits) return NO;
    double threshold = cap * kShieldSuppressTopRatio;
    if (next >= threshold) return NO;                             // 新值仍在满档区，不算压暗
    CFTypeRef currentRaw = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    double current = CPUthermalNitsFromRaw(currentRaw);
    if (currentRaw) CFRelease(currentRaw);
    if (current < threshold) return NO;                           // 本来就不在满档区，是用户在调暗
    return CPUthermalPanelTemperatureC() >= kShieldSuppressTemperatureC;
}

static kern_return_t CPUthermalHookedRegistrySet(io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    if (CPUthermalShouldSuppressLevelDrop(entry, key, value)) {
        os_log_error(os_log_create("com.huayuarc.cputhermal", "display-shield"),
                     "suppressed thermal panel level drop");
        return KERN_SUCCESS;
    }
    id replacement = nil;
    if (gCPUthermalDisplayShieldEnabled && CPUthermalDisplayCapKey(key)) {
        @try { replacement = CPUthermalProtectedDisplayCapValue(value); } @catch (__unused NSException *e) { replacement = nil; }
    }
    return gCPUthermalOrigRegistrySet ? gCPUthermalOrigRegistrySet(entry, key, replacement ? (__bridge CFTypeRef)replacement : value) : KERN_NOT_SUPPORTED;
}

static kern_return_t CPUthermalHookedServiceSet(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (CPUthermalShouldSuppressLevelDrop(service, key, value)) return KERN_SUCCESS;
    id replacement = nil;
    if (gCPUthermalDisplayShieldEnabled && CPUthermalDisplayCapKey(key)) {
        @try { replacement = CPUthermalProtectedDisplayCapValue(value); } @catch (__unused NSException *e) { replacement = nil; }
    }
    return gCPUthermalOrigServiceSet ? gCPUthermalOrigServiceSet(service, key, replacement ? (__bridge CFTypeRef)replacement : value) : KERN_NOT_SUPPORTED;
}

%ctor {
    // 加载期只做本地操作：读偏好 plist、解析符号、挂 hook。
    // 这里一旦出现任何跨进程调用（尤其 BrightnessSystemClient），在 backboardd 里就会自锁黑屏。
    @autoreleasepool {
        @try {
            NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
            id enabled = prefs[S("enabled")];
            gCPUthermalDisplayShieldEnabled = enabled ? [enabled boolValue] : YES;
        } @catch (__unused NSException *e) {
            gCPUthermalDisplayShieldEnabled = YES;
        }
        void *registrySet = dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperty");
        void *serviceSet = dlsym(RTLD_DEFAULT, "IOServiceSetProperty");
        if (registrySet) MSHookFunction(registrySet, (void *)CPUthermalHookedRegistrySet, (void **)&gCPUthermalOrigRegistrySet);
        if (serviceSet) MSHookFunction(serviceSet, (void *)CPUthermalHookedServiceSet, (void **)&gCPUthermalOrigServiceSet);
    }
}
