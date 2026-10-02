// CPUthermalDisplay — 屏幕亮度守护（注入 backboardd / SpringBoard）
//
// 现场实测（iPhone 13 Pro / iOS 16.1.2）：
//   真正的热降亮度旋钮是 AppleCLCD2 节点的 BLNitsCap（16.16 定点 nits）：
//     boot      69468160 = 1060.00 nits（固件默认）
//     810918611 55713464 =  850.12 nits（面板实际能力）
//     810918632 33151308 =  505.85 nits  ← 热压一档，物理亮度跟着掉
//     810918679 44071076 =  672.47 nits  ← 回升
//     810918689 55713464 =  850.12 nits  ← 恢复
//   同一时刻 AppleARMBacklight.brightness-nits 是“请求/应用值”，
//   DisplayBrightness 字典中的 NitsPhysical 才是最终物理亮度。
//
// 本模块只做两件事，且只“往高里抬”，绝不改用户滑块：
//   1) BLNitsCap 被写到低于本机已学习的面板上限时，立刻改写回上限；
//   2) brightness-nits 被压到低于“滑块请求值与上限的较小者”时，补齐；
//   并在进程加载时、以及每 3 秒自检一次，覆盖注销 / 重启用户空间 / 重新越狱。

#import <Foundation/Foundation.h>
#include <ctype.h>
#include <string.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <dlfcn.h>
#include <math.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <notify.h>
#import <CPUthermalPaths.h>
#include <pthread.h>
#include <stdarg.h>

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
static NSString *gProcTag = @"?";


static void DLog(NSString *format, ...) { (void)format; }   // 诊断日志已移除（156）


// ---------------------------------------------------------------------------
// 上限学习与持久化（16.16 定点）
// ---------------------------------------------------------------------------
static int64_t gCapTargetRaw = 0;
static BOOL gCapTargetFromPhysical = NO;   // 目标是否来自面板实际物理亮度（权威来源）
static double  gRequestedNits = 0;   // 最近一次 DisplayBrightness 请求 nits
static pthread_mutex_t gCapLock = PTHREAD_MUTEX_INITIALIZER;

static inline int64_t NitsToRaw(double nits) { return (int64_t)llround(nits * 65536.0); }
static inline double RawToNits(int64_t raw) { return (double)raw / 65536.0; }

// 用户要求：本机（13 Pro）面板满值 850 nits 是底线，低于它即视为“被降亮度/降背光”。
// 低于该值一律不学习、不写回，避免在已压低状态下把 163 之类的值学成上限并锁死。
static const double kDisplayMinPlausibleNits = 850.0;
static inline int64_t MinPlausibleRaw(void) { return NitsToRaw(kDisplayMinPlausibleNits); }

// 前置声明（定义在后文）
static CFTypeRef NodeCopyProperty(io_registry_entry_t entry, const char *name);

static NSString *CapStorePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[@"/var/mobile/Library/CPUthermal", @"/var/tmp", @"/tmp"]) {
        if ([fm fileExistsAtPath:dir]) return [dir stringByAppendingPathComponent:@"cputhermal-displaycap.txt"];
    }
    return nil;
}

static void CapPersist(void) {
    NSString *path = CapStorePath();
    if (!path) return;
    @try {
        [[NSString stringWithFormat:@"%lld\n%@", (long long)gCapTargetRaw,
            gCapTargetFromPhysical ? @"physical" : @"provisional"]
            writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) { }
}

static void CapLoadPersisted(void) {
    if (gCapTargetRaw > 0) return;
    NSString *path = CapStorePath();
    if (!path) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    long long value = text ? [[[text componentsSeparatedByString:S("\n")] firstObject] longLongValue] : 0;
    BOOL fromPhysical = [text containsString:S("physical")];
    if (value >= MinPlausibleRaw() && value < 20000LL * 65536LL) {
        gCapTargetRaw = (int64_t)value;
        gCapTargetFromPhysical = fromPhysical;
        DLog(@"panel max restored from disk: %.2f nits (%@)", RawToNits(gCapTargetRaw), fromPhysical ? @"physical" : @"provisional");
    }
}

// 只升不降：避免在已经处于热压状态时把低值学成上限
// 面板实际物理亮度是面板能力的权威来源：直接作为目标（可升可降，但不低于 850 nits）。
// 这样每台设备都用自己的真实上限（例如 13 Pro 是 850.12 nits），而不是固件默认的 1060 上限值。
static void CapLearnPhysicalNits(double nits) {
    if (!(nits >= kDisplayMinPlausibleNits) || nits > 20000.0) return;
    int64_t raw = NitsToRaw(nits);
    pthread_mutex_lock(&gCapLock);
    BOOL changed = (raw != gCapTargetRaw) || !gCapTargetFromPhysical;
    if (changed) { gCapTargetRaw = raw; gCapTargetFromPhysical = YES; }
    pthread_mutex_unlock(&gCapLock);
    if (changed) { CapPersist(); DLog(@"panel max learned (physical): %.2f nits", nits); }
}

// BLNitsCap 写入值只作启动兜底：固件默认可能是 1060（上限），并非面板真实能力，
// 因此仅在尚无物理亮度目标时采用，且一旦学到物理亮度就会被替换。
// 直接读取本机面板最大亮度（nits 或 16.16 定点）：不做“学习”，
// 直接拿设备自身声明的上限作为强制目标，避免依赖历史观测。
static double PanelMaxNitsFromRegistry(void) {
    // 只取“面板能力”类键：排除 BLNitsCap / IOMFB_brightness_limit / brightnesscap 等
    // “上限/cap”值（固件默认可能是 1060，并非面板真实能力）。
    static const char *keys[] = {"IOMFB_max_brightness","IOMFB_brightness_max","max-brightness","maxbrightness",
                                 "MaxBrightness","brightness-max","DisplayBrightnessNitsNVRAM",
                                 "PanelMaxBrightness","nitsMax",NULL};
    double best = 0.0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS || iterator == IO_OBJECT_NULL)
        return 0.0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        for (int i = 0; keys[i]; i++) {
            CFTypeRef value = NodeCopyProperty(entry, keys[i]);
            if (!value) continue;
            double raw = 0.0;
            if (CFGetTypeID(value) == CFNumberGetTypeID()) {
                int64_t numberValue = 0;
                [(__bridge NSNumber *)value getValue:&numberValue];
                raw = (double)numberValue;
            } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
                raw = [(__bridge NSString *)value doubleValue];
            }
            CFRelease(value);
            double nits = raw > 65536.0 ? raw / 65536.0 : raw;   // 16.16 定点 → nits
            if (nits >= kDisplayMinPlausibleNits && nits <= 20000.0 && nits > best) best = nits;
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return best;
}

// 各机型持续全屏最大亮度（Battman 面板上限，单位 nits）：
// 直接按机型取值作为强制目标，不做学习、也不会因此产生日志。
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

static void CapAdoptDeviceMaximum(void) {
    if (gCapTargetFromPhysical && gCapTargetRaw >= MinPlausibleRaw()) return;   // 已有权威值
    double tableNits = PanelMaxNitsForCurrentDevice();   // 优先用机型表（权威）
    if (tableNits >= kDisplayMinPlausibleNits) { CapLearnPhysicalNits(tableNits); return; }
    double nits = PanelMaxNitsFromRegistry();
    if (nits >= kDisplayMinPlausibleNits) CapLearnPhysicalNits(nits);
}

// 从 CoreBrightness 读取当前滑块与请求值：用于在“实际亮度”被压下时补齐。
// 这些写入可能来自其它进程，只有同时核对滑块才能判断该抬多少。
static double CPUthermalSliderValue(void) {
    Class cls = objc_getClass("BrightnessSystemClient");
    if (!cls) return -1.0;
    id client = nil;
    @try { client = [[cls alloc] init]; } @catch (__unused NSException *e) { return -1.0; }
    if (!client) return -1.0;
    SEL copySel = sel_registerName("copyPropertyForKey:");
    if (![client respondsToSelector:copySel]) return -1.0;
    id dict = nil;
    @try { dict = ((id (*)(id, SEL, id))objc_msgSend)(client, copySel, S("DisplayBrightness")); }
    @catch (__unused NSException *e) { return -1.0; }
    if (![dict isKindOfClass:[NSDictionary class]]) return -1.0;
    id brightness = [(NSDictionary *)dict objectForKey:S("Brightness")];
    if (![brightness respondsToSelector:@selector(doubleValue)]) return -1.0;
    return [brightness doubleValue];
}

// 读取“系统设置里的亮度滑块”比例（0..1）。这是用户意图的可信来源：
// 热压只会压低“实际亮度/请求值”，不会改动滑块本身；因此恢复时必须以滑块为准，
// 否则会被已经压暗的请求值（实测 163.3 nits）拖住而永远无法恢复。
static double CPUthermalUserSliderLevel(void) {
    @try {
        NSUserDefaults *sb = [[NSUserDefaults alloc] initWithSuiteName:S("com.apple.springboard")];
        if (!sb) return -1.0;
        NSArray *keys = @[@"SBBacklightLevel2", @"SBBacklightLevel", @"SBBacklightLevel3"];
        for (NSString *key in keys) {
            id value = [sb objectForKey:key];
            if ([value respondsToSelector:@selector(doubleValue)]) {
                double level = [value doubleValue];
                if (level > 0.0 && level <= 1.0) return level;
            }
        }
    } @catch (__unused NSException *e) { }
    return -1.0;
}

static void CapLearnRawFallback(int64_t rawCap) {
    if (rawCap <= 0 || rawCap > 20000LL * 65536LL) return;
    if (rawCap < MinPlausibleRaw()) return;   // 被压低的值不采信
    pthread_mutex_lock(&gCapLock);
    // v90 语义：取“历史最大值”，学习到的更高值（例如开机固件 1060 nits）可以抬高机型表值；
    // 此前 !gCapTargetFromPhysical 的条件把机型表当成了天花板，导致 1060 永远无法被采纳。
    BOOL adopt = (gCapTargetRaw <= 0) || (rawCap > gCapTargetRaw);
    if (adopt) gCapTargetRaw = rawCap;
    pthread_mutex_unlock(&gCapLock);
    if (adopt) { CapPersist(); DLog(@"panel cap provisional: %.2f nits", RawToNits(rawCap)); }
}

static void CapLearnFromNits(double nits) { CapLearnPhysicalNits(nits); }

// ---------------------------------------------------------------------------
// 节点定位 / 读写
// ---------------------------------------------------------------------------
static io_registry_entry_t FindNodeWithKey(const char *keyName) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS || iterator == IO_OBJECT_NULL)
        return IO_OBJECT_NULL;
    CFStringRef want = CFStringCreateWithCString(kCFAllocatorDefault, keyName, kCFStringEncodingUTF8);
    io_registry_entry_t entry;
    io_registry_entry_t found = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (want) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(entry, want, kCFAllocatorDefault, 0);
            if (value) { CFRelease(value); found = entry; break; }
        }
        IOObjectRelease(entry);
    }
    if (want) CFRelease(want);
    IOObjectRelease(iterator);
    return found;
}

static CFTypeRef NodeCopyProperty(io_registry_entry_t entry, const char *name) {
    if (entry == IO_OBJECT_NULL || !name) return NULL;
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!key) return NULL;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    CFRelease(key);
    return value;
}

static BOOL NodeWriteRaw(io_registry_entry_t entry, const char *name, int64_t raw) {
    if (entry == IO_OBJECT_NULL || !name) return NO;
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!key) return NO;
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &raw);
    BOOL ok = NO;
    if (value) {
        ok = (IORegistryEntrySetCFProperty(entry, key, value) == KERN_SUCCESS);
        CFRelease(value);
    }
    CFRelease(key);
    return ok;
}

static int64_t NodeReadRaw(io_registry_entry_t entry, const char *name) {
    int64_t raw = 0;
    CFTypeRef value = NodeCopyProperty(entry, name);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) [(__bridge NSNumber *)value getValue:&raw];
        CFRelease(value);
    }
    return raw;
}

static io_registry_entry_t gCapNode = IO_OBJECT_NULL;   // 持有 BLNitsCap 的节点
static io_registry_entry_t gNitsNode = IO_OBJECT_NULL;  // 持有 brightness-nits 的节点

static io_registry_entry_t CapNode(void) {
    if (gCapNode != IO_OBJECT_NULL && NodeCopyProperty(gCapNode, "BLNitsCap")) return gCapNode;
    if (gCapNode != IO_OBJECT_NULL) { IOObjectRelease(gCapNode); gCapNode = IO_OBJECT_NULL; }
    gCapNode = FindNodeWithKey("BLNitsCap");
    return gCapNode;
}

static io_registry_entry_t NitsNode(void) {
    if (gNitsNode != IO_OBJECT_NULL && NodeCopyProperty(gNitsNode, "brightness-nits")) return gNitsNode;
    if (gNitsNode != IO_OBJECT_NULL) { IOObjectRelease(gNitsNode); gNitsNode = IO_OBJECT_NULL; }
    gNitsNode = FindNodeWithKey("brightness-nits");
    return gNitsNode;
}

// ---------------------------------------------------------------------------
// 核心：把上限顶回面板能力，并把被压掉的请求值补齐
// ---------------------------------------------------------------------------
// 性能：该函数会被“每一条 IORegistry/IOService 属性写入”调用，
// 原先每次都读偏好 plist（磁盘 I/O）导致系统级卡顿与不跟手；改为 5 秒缓存。
static BOOL gProtectionEnabledCache = YES;
static CFAbsoluteTime gProtectionCacheTime = 0;
static BOOL BrightnessProtectionEnabled(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gProtectionCacheTime < 5.0) return gProtectionEnabledCache;
    gProtectionCacheTime = now;
    @try {
        NSDictionary *prefs = CPUthermalReadPrefs();
        id enabledValue = prefs[S("enabled")];
        gProtectionEnabledCache = enabledValue ? [enabledValue boolValue] : YES;
    } @catch (__unused NSException *e) { gProtectionEnabledCache = YES; }
    return gProtectionEnabledCache;
}

// 性能：滑块值改为 2 秒缓存（原先每调用一次都新建 NSUserDefaults 读域）
static double gSliderLevelCache = -1.0;
static CFAbsoluteTime gSliderCacheTime = 0;
static double CPUthermalUserSliderLevelCached(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gSliderCacheTime < 2.0) return gSliderLevelCache;
    gSliderCacheTime = now;
    gSliderLevelCache = CPUthermalUserSliderLevel();
    return gSliderLevelCache;
}

// 亮度上限类键名匹配：BLNitsCap / *NitsCap / *BrightnessCap 等一律处理
static BOOL KeyIsNitsCapKey(CFStringRef key) {
    if (!key || CFGetTypeID(key) != CFStringGetTypeID()) return NO;
    char buf[160] = {0};
    if (!CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8)) return NO;
    for (char *p = buf; *p; p++) *p = (char)tolower((unsigned char)*p);
    if (strstr(buf, "nitscap") || strstr(buf, "nits-cap")) return YES;
    if (strstr(buf, "brightnesscap") || strstr(buf, "brightness-cap")) return YES;
    return NO;
}

static void EnforcePanelBrightness(NSString *reason) {
    @try {
        if (!BrightnessProtectionEnabled()) return;
        CapAdoptDeviceMaximum();
        io_registry_entry_t capNode = CapNode();
        if (capNode == IO_OBJECT_NULL) return;

        int64_t rawCap = NodeReadRaw(capNode, "BLNitsCap");
        if (rawCap > 0) CapLearnRawFallback(rawCap);

        int64_t target = 0;
        pthread_mutex_lock(&gCapLock);
        target = gCapTargetRaw;
        pthread_mutex_unlock(&gCapLock);

        if (rawCap > 0 && target > 0 && rawCap < target) {
            if (NodeWriteRaw(capNode, "BLNitsCap", target))
                DLog(@"BLNitsCap raised %.2f -> %.2f nits (%@)", RawToNits(rawCap), RawToNits(target), reason);
            else
                DLog(@"BLNitsCap raise FAILED to %.2f nits (%@)", RawToNits(target), reason);
        }

        io_registry_entry_t nitsNode = NitsNode();
        if (nitsNode == IO_OBJECT_NULL || target <= 0) return;

        double requested = 0.0;
        pthread_mutex_lock(&gCapLock);
        requested = gRequestedNits;
        pthread_mutex_unlock(&gCapLock);

        // 实际亮度维持：热压会把 brightness-nits（实际亮度）压低。
        // 若尚未从 DisplayBrightness 字典拿到请求值，则用“滑块 × 面板上限”推算，
        // 这样即使写入来自其它进程也能正确补齐（不低于该值）。
        if (!(requested > 0.0)) {
            double slider = CPUthermalSliderValue();
            if (slider > 0.02) requested = RawToNits(target) * MIN(1.0, slider);
        }
        // 以系统设置里的亮度滑块为基准（用户意图）：滑块 100% -> 面板上限。
        // 这样即使“请求值”已被热压写低（163.3 nits），也能把实际亮度抬回用户设定，
        // 修复“切到低功耗/高温后亮度掉下去且再也回不来”。
        double sliderLevel = CPUthermalUserSliderLevelCached();
        if (sliderLevel >= 0.95) {
            // 滑块几乎拉满：直接以面板上限为目标，忽略可能已被热压写低的请求值。
            // 这是修复“实际亮度卡在 163.3 抬不回去”的关键：此前 desired=min(被压低的请求值, 上限)，
            // 于是永远没有可抬的余量（日志里也就没有 brightness-nits raised）。
            requested = RawToNits(target);
        } else if (sliderLevel > 0.02) {
            double sliderNits = RawToNits(target) * MIN(1.0, sliderLevel);
            if (sliderNits > requested) requested = sliderNits;
        }
        if (!(requested > 0.0)) return;

        double desired = RawToNits(target);
        if (requested < desired) desired = requested;

        int64_t rawApplied = NodeReadRaw(nitsNode, "brightness-nits");
        if (rawApplied <= 0) {
            static BOOL loggedMissingNits = NO;
            if (!loggedMissingNits) { loggedMissingNits = YES; DLog(@"brightness-nits node has no readable value (skip raise)"); }
            return;
        }
        if (RawToNits(rawApplied) < desired - 1.0) {
            if (NodeWriteRaw(nitsNode, "brightness-nits", NitsToRaw(desired)))
                DLog(@"brightness-nits raised %.2f -> %.2f nits (%@)", RawToNits(rawApplied), desired, reason);
            else
                DLog(@"brightness-nits raise FAILED to %.2f nits (%@)", desired, reason);
        }
    } @catch (__unused NSException *e) { }
}

// ---------------------------------------------------------------------------
// 自检定时器
// ---------------------------------------------------------------------------
static void BrightnessGuardTick(void) {
    // 仅做“只抬不压”的节点级恢复；不再向 CoreBrightness 提交任何亮度
    // （实测提交无法改变实际亮度，反而三个进程同时刷是噪音来源，已按用户要求移除）。
    EnforcePanelBrightness(@"tick");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ BrightnessGuardTick(); });
}

// ---------------------------------------------------------------------------
// Hook：截获 BLNitsCap 写入（谁写都拦下来改高）
// ---------------------------------------------------------------------------
// ---------- 底层拦截：把“任何降低亮度/亮度上限的写入”替换为不降低的值 ----------
// 说明：系统压低屏幕亮度有两个入口：
//   1) IORegistryEntrySetCFProperty（旧版已拦）；
//   2) IOServiceSetProperty / IORegistryEntrySetCFProperties（此前未拦，实测实际亮度被压低
//      正是走这两个入口，导致“写入没被拦截、亮度掉下去没人管”）。
// 本函数只做一件事：识别亮度类键（BLNitsCap / brightness-nits 等），
// 若写入值会降低亮度，则返回抬高后的替换值（+1 引用），否则返回 NULL 原样放行。
static double CFBacklightNumericValue(CFTypeRef value) {
    if (!value) return 0.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) return [(__bridge NSNumber *)value doubleValue];
    if (CFGetTypeID(value) == CFStringGetTypeID()) return [(__bridge NSString *)value doubleValue];
    return 0.0;
}

static CFTypeRef CPUthermalBacklightLoweringReplacement(CFStringRef key, CFTypeRef value) {
    if (!key || !value) return NULL;
    if (CFGetTypeID(key) != CFStringGetTypeID()) return NULL;
    char buf[160] = {0};
    if (!CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8)) return NULL;
    for (char *p = buf; *p; p++) *p = (char)tolower((unsigned char)*p);
    BOOL isCap = (strcmp(buf, "blnitscap") == 0) || KeyIsNitsCapKey(key);
    BOOL isNits = (strcmp(buf, "brightness-nits") == 0) || (strcmp(buf, "brightness_nits") == 0);
    if (!isCap && !isNits) return NULL;          // 绝大多数写入在这里直接返回（零开销）
    if (!BrightnessProtectionEnabled()) return NULL;

    double incoming = CFBacklightNumericValue(value);
    if (!(incoming > 0.0)) return NULL;

    int64_t capTarget = 0;
    double requested = 0.0;
    pthread_mutex_lock(&gCapLock);
    capTarget = gCapTargetRaw;
    requested = gRequestedNits;
    pthread_mutex_unlock(&gCapLock);
    if (capTarget <= 0) return NULL;

    // 目标 = min(max(请求值, 滑块×面板上限), 面板上限)
    double sliderLevel = CPUthermalUserSliderLevelCached();
    if (sliderLevel > 0.02) {
        double sliderNits = RawToNits(capTarget) * MIN(1.0, sliderLevel);
        if (sliderNits > requested) requested = sliderNits;
    }
    if (!(requested > 0.0)) return NULL;
    double desired = RawToNits(capTarget);
    if (requested < desired) desired = requested;
    if (desired < 100.0) return NULL;   // 用户主动调暗时不干预

    // 兼容两种数值空间：16.16 定点（大数）与普通 nits（小数）
    BOOL fixedPoint = (incoming > 100000.0);
    double incomingNits = fixedPoint ? (incoming / 65536.0) : incoming;
    double floorNits = isCap ? RawToNits(capTarget) : desired;
    if (incomingNits + 0.5 >= floorNits) return NULL;   // 不会降低亮度 -> 放行

    double out = fixedPoint ? (floorNits * 65536.0) : floorNits;
    static CFAbsoluteTime lastLog = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastLog > 2.0) {
        lastLog = now;
        DLog(@"lowering blocked: %s %.1f -> %.1f nits", buf, incomingNits, floorNits);
    }
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &out);
}

// 这两个符号不在公共 SDK 头文件中（内核导出、SDK 无声明），
// 因此不用 %hookf，改用 dlsym + MSHookFunction（与主模块 Tweak.x 同款做法，已验证可编译）。
typedef kern_return_t (*CPUthermalServiceSetPropertyFn)(io_service_t, CFStringRef, CFTypeRef);
static CPUthermalServiceSetPropertyFn gOrigIOServiceSetProperty = NULL;

static kern_return_t CPUthermalHookedIOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    @try {
        CFTypeRef replacement = CPUthermalBacklightLoweringReplacement(key, value);
        if (replacement) {
            kern_return_t kr = gOrigIOServiceSetProperty ? gOrigIOServiceSetProperty(service, key, replacement) : KERN_FAILURE;
            CFRelease(replacement);
            return kr;
        }
    } @catch (__unused NSException *e) { }
    return gOrigIOServiceSetProperty ? gOrigIOServiceSetProperty(service, key, value) : KERN_FAILURE;
}

typedef kern_return_t (*CPUthermalEntrySetCFPropertiesFn)(io_registry_entry_t, CFTypeRef);
static CPUthermalEntrySetCFPropertiesFn gOrigIOEntrySetCFProperties = NULL;

static kern_return_t CPUthermalHookedIOEntrySetCFProperties(io_registry_entry_t entry, CFTypeRef properties) {
    @try {
        if (properties && CFGetTypeID(properties) == CFDictionaryGetTypeID()) {
            CFIndex count = CFDictionaryGetCount((CFDictionaryRef)properties);
            if (count > 0) {
                const void **keys = (const void **)calloc((size_t)count, sizeof(void *));
                const void **vals = (const void **)calloc((size_t)count, sizeof(void *));
                CFMutableDictionaryRef patched = NULL;
                if (keys && vals) {
                    CFDictionaryGetKeysAndValues((CFDictionaryRef)properties, keys, vals);
                    for (CFIndex i = 0; i < count; i++) {
                        if (!keys[i] || CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
                        CFTypeRef rep = CPUthermalBacklightLoweringReplacement((CFStringRef)keys[i], vals[i]);
                        if (!rep) continue;
                        if (!patched) patched = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, count, (CFDictionaryRef)properties);
                        if (patched) CFDictionarySetValue(patched, keys[i], rep);
                        CFRelease(rep);
                    }
                }
                if (keys) free((void *)keys);
                if (vals) free((void *)vals);
                if (patched) {
                    kern_return_t kr = gOrigIOEntrySetCFProperties ? gOrigIOEntrySetCFProperties(entry, (CFTypeRef)patched) : KERN_FAILURE;
                    CFRelease(patched);
                    return kr;
                }
            }
        }
    } @catch (__unused NSException *e) { }
    return gOrigIOEntrySetCFProperties ? gOrigIOEntrySetCFProperties(entry, properties) : KERN_FAILURE;
}

static void CPUthermalInstallWriteInterceptors(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    void *sym1 = dlsym(RTLD_DEFAULT, "IOServiceSetProperty");
    if (sym1) MSHookFunction(sym1, (void *)CPUthermalHookedIOServiceSetProperty, (void **)&gOrigIOServiceSetProperty);
    void *sym2 = dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperties");
    if (sym2) MSHookFunction(sym2, (void *)CPUthermalHookedIOEntrySetCFProperties, (void **)&gOrigIOEntrySetCFProperties);
    DLog(@"write interceptors installed (service=%d, entryDict=%d)", sym1 != NULL, sym2 != NULL);
}

%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    @try {
        static CFStringRef capKey = NULL;
        if (capKey == NULL) capKey = CFStringCreateWithCString(kCFAllocatorDefault, "BLNitsCap", kCFStringEncodingUTF8);
        static CFStringRef nitsKey = NULL;
        if (nitsKey == NULL) nitsKey = CFStringCreateWithCString(kCFAllocatorDefault, "brightness-nits", kCFStringEncodingUTF8);
        static CFStringRef displayKey = NULL;
        if (displayKey == NULL) displayKey = CFStringCreateWithCString(kCFAllocatorDefault, "DisplayBrightness", kCFStringEncodingUTF8);

        BOOL isCapWrite = (capKey && CFEqual(key, capKey)) || KeyIsNitsCapKey(key);
        BOOL isNitsWrite = (nitsKey && CFEqual(key, nitsKey));
        BOOL isDisplayWrite = (displayKey && CFEqual(key, displayKey));
        // 性能：仅亮度相关键才读取保护开关（避免每条属性写入都读偏好）
        BOOL protectionOn = (isCapWrite || isNitsWrite) ? BrightnessProtectionEnabled() : NO;
        if (protectionOn && isCapWrite && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            int64_t raw = 0;
            [(__bridge NSNumber *)value getValue:&raw];
            CapLearnRawFallback(raw);
            int64_t target = 0;
            pthread_mutex_lock(&gCapLock);
            target = gCapTargetRaw;
            pthread_mutex_unlock(&gCapLock);
            if (target > 0 && raw < target) {
                DLog(@"BLNitsCap write intercepted %.2f -> %.2f nits", RawToNits(raw), RawToNits(target));
                CFNumberRef forced = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &target);
                kern_return_t kr = %orig(entry, key, forced ? (CFTypeRef)forced : value);
                if (forced) CFRelease(forced);
                return kr;
            }
        } else if (protectionOn && nitsKey && CFEqual(key, nitsKey) && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            int64_t raw = 0;
            [(__bridge NSNumber *)value getValue:&raw];
            int64_t target = 0;
            double requested = 0.0;
            pthread_mutex_lock(&gCapLock);
            target = gCapTargetRaw;
            requested = gRequestedNits;
            pthread_mutex_unlock(&gCapLock);
            if (target > 0 && requested > 0.0) {
                double desired = RawToNits(target);
                if (requested < desired) desired = requested;
                if (RawToNits(raw) < desired - 1.0) {
                    int64_t forcedRaw = NitsToRaw(desired);
                    DLog(@"brightness-nits write intercepted %.2f -> %.2f nits", RawToNits(raw), desired);
                    CFNumberRef forced = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &forcedRaw);
                    kern_return_t kr = %orig(entry, key, forced ? (CFTypeRef)forced : value);
                    if (forced) CFRelease(forced);
                    return kr;
                }
            }
        } else if (isDisplayWrite && value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            // 只学习请求值与实际物理亮度，不改写显示字典
            CFTypeRef nits = CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("Nits"));
            CFTypeRef physical = CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("NitsPhysical"));
            double nitsValue = 0.0, physicalValue = 0.0;
            if (nits && CFGetTypeID(nits) == CFNumberGetTypeID()) [(__bridge NSNumber *)nits getValue:&nitsValue];
            if (physical && CFGetTypeID(physical) == CFStringGetTypeID()) physicalValue = [(__bridge NSString *)physical doubleValue];
            else if (physical && CFGetTypeID(physical) == CFNumberGetTypeID()) [(__bridge NSNumber *)physical getValue:&physicalValue];
            pthread_mutex_lock(&gCapLock);
            if (nitsValue > 0.0) gRequestedNits = nitsValue;
            pthread_mutex_unlock(&gCapLock);
            if (physicalValue > 0.0) CapLearnFromNits(physicalValue);
            if (nitsValue > 0.0 && physicalValue > 0.0 && physicalValue < nitsValue - 1.0) {
                static CFAbsoluteTime lastDimLog = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastDimLog > 5.0) {
                    lastDimLog = now;
                    DLog(@"dim detected: request=%.2f applied=%.2f nits -> enforce", nitsValue, physicalValue);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        EnforcePanelBrightness(@"dim");
                    });
                }
            }
        }
    } @catch (__unused NSException *e) { }
    return %orig;
}

// ---------------------------------------------------------------------------
// Hook：CoreBrightness 客户端（记录用户滑块请求值）
// ---------------------------------------------------------------------------
%hook BrightnessSystemClient

- (void)setProperty:(id)value forKey:(id)key {
if ([key isKindOfClass:[NSString class]] && [(NSString *)key isEqualToString:@"DisplayBrightness"] &&
    [value isKindOfClass:[NSDictionary class]]) {
    id nits = [(NSDictionary *)value objectForKey:@"Nits"];
    if ([nits respondsToSelector:@selector(doubleValue)]) {
        double nitsValue = [nits doubleValue];
        if (nitsValue > 0.0) {
            pthread_mutex_lock(&gCapLock);
            gRequestedNits = nitsValue;
            pthread_mutex_unlock(&gCapLock);
        }
    }
}
%orig;
}

%end

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
%ctor {
    @autoreleasepool {
        NSString *name = [[NSProcessInfo processInfo] processName];
        if (name.length == 0) name = @"?";
        gProcTag = name;
        DLog(@"display brightness guard loaded (pid %d)", (int)getpid());
        CapLoadPersisted();
        CapAdoptDeviceMaximum();   // 立即读取并采用设备自身最大亮度（无需学习）
        DLog(@"brightness guard state: protection=%d, capTarget=%.2f nits",
             BrightnessProtectionEnabled(), RawToNits(gCapTargetRaw));
        CPUthermalInstallWriteInterceptors();   // 补 IOServiceSetProperty / IORegistryEntrySetCFProperties 拦截
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            EnforcePanelBrightness(@"load");
            BrightnessGuardTick();
        });
        // 亮屏/解锁后再补一次，避免刚唤醒时被系统写成低上限
        static int lockToken = 0;
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                EnforcePanelBrightness(@"lockstate");
            });
        });
    }
}
