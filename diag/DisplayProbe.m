// 只读诊断探针：打印显示子系统（DCP / IOMFB / CLCD）在 IORegistry 里的全部属性，
// 以及 CoreBrightness 通过 BrightnessSystemClient 暴露的亮度相关键值。
// 不写任何属性，只用于定位“滑块 1060 但实际 163 nits”这类压制来自哪个键。
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define kIOMasterPortDefault MACH_PORT_NULL

static void dumpService(const char *className) {
    CFMutableDictionaryRef matching = IOServiceMatching(className);
    if (!matching) return;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) return;
    io_registry_entry_t entry;
    int index = 0;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);
        printf("=== %s[%d] %s\n", className, index++, name);
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
            NSDictionary *dict = (__bridge_transfer NSDictionary *)properties;
            for (NSString *key in [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                NSString *value = [dict[key] description];
                if ([value length] > 150) value = [[value substringToIndex:150] stringByAppendingString:@"…"];
                printf("   %-40s = %s\n", [key UTF8String], [value UTF8String]);
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
}

static void probeCoreBrightness(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) &&
        !dlopen("/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness", RTLD_NOW)) {
        printf("!! CoreBrightness 无法加载\n");
        return;
    }
    Class cls = objc_getClass("BrightnessSystemClient");
    if (!cls) { printf("!! 没有 BrightnessSystemClient\n"); return; }
    id client = nil;
    @try { client = [[cls alloc] init]; } @catch (__unused NSException *e) { printf("!! client init 抛异常\n"); return; }
    NSArray *keys = @[
        @"DisplayBrightness", @"DisplayBrightnessLimit", @"DisplayBrightnessMax",
        @"BrightnessLimit", @"BrightnessMax", @"SliderMax", @"MaxBrightness", @"BrightnessMaxNits",
        @"DisplayBrightnessFactor", @"DisplayBrightnessFactors", @"BrightnessCapabilities",
        @"DisplayBrightnessAuto", @"DisplayBrightnessDimming", @"BrightnessDimming"];
    for (NSString *key in keys) {
        id value = nil;
        @try { value = ((id(*)(id,SEL,id))objc_msgSend)(client, sel_registerName("copyPropertyForKey:"), key); }
        @catch (__unused NSException *e) { value = nil; }
        printf("CB %-32s = %s\n", [key UTF8String], value ? [[value description] UTF8String] : "(nil)");
    }
}

static double registryNumber(io_registry_entry_t entry, const char *key);

typedef kern_return_t (*SetPropertyFn)(io_registry_entry_t, CFStringRef, CFTypeRef);

static int setDisplayProperty(const char *keyName, double nits, int fixedPoint) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleCLCD2"));
    if (!service) { printf("!! 找不到 AppleCLCD2\n"); return 1; }
    // iOS 上 IORegistryEntrySetCFProperty 被标记 unavailable，运行时按符号取。
    SetPropertyFn setProperty = (SetPropertyFn)dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperty");
    if (!setProperty) { printf("!! 取不到 IORegistryEntrySetCFProperty\n"); IOObjectRelease(service); return 1; }
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, keyName, kCFStringEncodingUTF8);
    CFNumberRef value = NULL;
    if (fixedPoint) {
        long long raw = (long long)(nits * 65536.0 + 0.5);
        value = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &raw);
    } else {
        value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &nits);
    }
    kern_return_t kr = setProperty(service, key, value);
    double after = registryNumber(service, keyName);
    printf("set %s = %.2f%s -> kr=0x%x, 读回 = %.2f\n", keyName, nits,
           fixedPoint ? " (16.16)" : "", kr, after);
    if (value) CFRelease(value);
    if (key) CFRelease(key);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? 0 : 1;
}

static double probeSliderNits(int verbose);

static double registryNumber(io_registry_entry_t entry, const char *key) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!k) return -1.0;
    double result = -1.0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, k, kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double raw = [(__bridge NSNumber *)value doubleValue];
            result = raw > 65536.0 ? raw / 65536.0 : raw;
        }
        CFRelease(value);
    }
    CFRelease(k);
    return result;
}

static io_registry_entry_t openDisplay(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleCLCD2"));
    return service;
}

// 连续采样：把“实际面板亮度 / 上限 / 环境光 / DCP 温度”放在同一时间轴上，
// 用来区分环境光补偿造成的正常压暗与温控造成的额外压暗。
static int watchDisplay(int seconds, int intervalMs) {
    if (seconds <= 0) seconds = 60;
    if (intervalMs <= 0) intervalMs = 1000;
    printf("# t=秒  面板nits  BLNitsCap  环境光  DCP温度C  APT亮度  滑块亮度nits\n");
    fflush(stdout);
    for (int i = 0; i < seconds; i++) {
        io_registry_entry_t fb = openDisplay();
        double level = -1, cap = -1, ambient = -1, temp = -1, apt = -1, slotNits = -1;
        if (fb) {
            level = registryNumber(fb, "IOMFBBrightnessLevel");
            cap = registryNumber(fb, "BLNitsCap");
            ambient = registryNumber(fb, "AmbientBrightness");
            temp = registryNumber(fb, "APTPDCTemperature");
            apt = registryNumber(fb, "APTPDCBrightness");
            IOObjectRelease(fb);
        }
        slotNits = probeSliderNits(0); // 0 = 只读不打印
        printf("%5d  %10.2f  %9.2f  %7.1f  %8.2f  %8.2f  %12.2f\n",
               i, level, cap, ambient, temp, apt, slotNits);
        fflush(stdout);
        usleep((useconds_t)intervalMs * 1000);
    }
    return 0;
}

// 读取 CoreBrightness 的 DisplayBrightness 字典并返回 Nits；verbose 时打印全部。
static double probeSliderNits(int verbose) {
    static Class cachedClass = Nil;
    static id cachedClient = nil;
    if (!cachedClass) {
        if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) &&
            !dlopen("/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness", RTLD_NOW)) return -1.0;
        cachedClass = objc_getClass("BrightnessSystemClient");
        if (!cachedClass) return -1.0;
    }
    if (!cachedClient) {
        @try { cachedClient = [[cachedClass alloc] init]; } @catch (__unused NSException *e) { return -1.0; }
        if (!cachedClient) return -1.0;
    }
    id display = nil;
    @try { display = ((id(*)(id,SEL,id))objc_msgSend)(cachedClient, sel_registerName("copyPropertyForKey:"), @"DisplayBrightness"); }
    @catch (__unused NSException *e) { return -1.0; }
    if (![display isKindOfClass:[NSDictionary class]]) return -1.0;
    if (verbose) printf("CB DisplayBrightness = %s\n", [[display description] UTF8String]);
    id nits = display[@"Nits"];
    return [nits respondsToSelector:@selector(doubleValue)] ? [nits doubleValue] : -1.0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "set") == 0 && argc > 3) {
            return setDisplayProperty(argv[2], atof(argv[3]), argc > 4 ? atoi(argv[4]) : 1);
        }
        if (argc > 1 && strcmp(argv[1], "watch") == 0) {
            int seconds = argc > 2 ? atoi(argv[2]) : 60;
            int interval = argc > 3 ? atoi(argv[3]) : 1000;
            return watchDisplay(seconds, interval);
        }
        printf("===== CoreBrightness 属性 =====\n");
        probeCoreBrightness();
        printf("\n===== IORegistry 显示服务 =====\n");
        const char *classes[] = {"AppleCLCD2", "AppleCLCD", "AppleDCP", "IOMobileFramebuffer",
                                 "AppleDisplay", "AppleBacklightDisplay", "AppleARMBacklight", NULL};
        for (int i = 0; classes[i]; i++) dumpService(classes[i]);
        printf("\n===== 含 brightness/nits 关键字的服务名 =====\n");
        io_iterator_t iter = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOService"), &iter) == KERN_SUCCESS) {
            io_registry_entry_t e;
            while ((e = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
                io_name_t name = {0};
                IORegistryEntryGetName(e, name);
                NSString *n = [NSString stringWithUTF8String:name];
                NSString *lower = [n lowercaseString];
                if ([lower containsString:@"backlight"] || [lower containsString:@"clcd"] ||
                    [lower containsString:@"dcp"] || [lower containsString:@"display"]) {
                    printf(" - %s\n", name);
                }
                IOObjectRelease(e);
            }
            IOObjectRelease(iter);
        }
    }
    return 0;
}
