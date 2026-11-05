// 解除温控模式下的显示亮度纠正守护（isolation.53）。
//
// 为什么是独立进程：thermalmonitord（核心 tweak 所在进程）写面板亮度属性会被内核拒绝
// （kr=0xE00002E2），带显示 IOKit 授权的普通用户态进程写同一个属性才是 kr=0 且立即生效。
// 所以“判断”可以放在核心，真正的“写”必须在这里。
//
// isolation.48 为什么被撤掉：它把“用户请求的 nits”当目标值，每 2 秒无条件比对一次。
// CoreBrightness 自己还有一层 请求→面板级 映射（实测请求 97.28 nits 时面板 83.57，约 0.86），
// 于是守护的“纠正”其实是在系统正常值之上再抬一截，拖滑块就会二次跳变/闪屏。
//
// isolation.51/52 的判据（保留）：按请求亮度分桶学习系统自身的 面板级/请求 比例，只补回落差、
// 只升不降、请求稳定后才判定、带冷却与分段渐变；满亮度区（请求接近面板上限）正常映射就是
// 1.0，目标直接取请求，且禁止把该区被压低的比例学成“健康样本”。
//
// isolation.53 跨机型适配：面板亮度不再是写死的 AppleCLCD2 + IOMFBBrightnessLevel(16.16)。
//   - DCP 机型（iPhone 12–15）：AppleCLCD2 / AppleCLCD / AppleDCP / IOMobileFramebuffer
//     上的 IOMFBBrightnessLevel，16.16 定点 nits；
//   - LCD 机型（iPhone 8/X/XR/11）：AppleARMBacklight 的 CurrentNits，或 IODisplayParameters
//     里 BrightnessMilliNits.value（毫 nit，写入要回写整个参数字典）；
//   - 单位不写死：候选比例 65536 / 1000 / 1 逐个比对“读数值 ÷ CoreBrightness 请求”，
//     落在合理区间（5–3000 nits 且与请求同量级）的第一个即采用，iOS 版本改单位也能自适应；
//   - 节点读不到或数值长期为 0（外接屏、关闭状态、机型不支持）时，只记一条日志、绝不写。
//
// 只在「解除温控」模式（powerMode=fullPower）且总开关打开时工作；其余情况一律不写。
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <os/log.h>
#import <unistd.h>
#import <string.h>
#import <CPUthermalPaths.h>

#define kIOMasterPortDefault MACH_PORT_NULL
extern kern_return_t CPUthermalIORegistryEntrySetCFProperty(io_registry_entry_t, CFStringRef, CFTypeRef) __asm("_IORegistryEntrySetCFProperty");

static os_log_t DisplayLevelLog(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.huayuarc.cputhermal", "display-level"); });
    return logger;
}

// —— 行为判据 ——
static const double kDisplayFloorNits = 40.0;          // 低于此亮度完全不管（暗环境/待机）
static const double kDisplayDeadbandNits = 5.0;        // 小于此差值不值得写
static const double kDisplayAbsoluteCeilingNits = 2000.0;
static const double kDisplayStableSeconds = 0.35;      // isolation.57：缩短到 0.35s，被压后几乎立刻判定
static const double kDisplayClampRatioFactor = 0.80;   // 比例跌到已学值的 80% 以下 = 被压
static const double kDisplaySampleProximity = 0.20;    // 当前请求离学习样本不超过 20% 才判定
static const double kDisplayPlausibleRatioMin = 0.50;
static const double kDisplayPlausibleRatioMax = 1.05;
static const double kDisplayCorrectionCooldown = 0.5;  // isolation.57：每 0.5s 可再次纠正，不再等 20s
static const double kDisplayLearnMuteAfterCorrection = 0.5;
static const double kDisplayRampThreshold = 0.25;      // 落差超过目标的 25% 时分两段
static const useconds_t kDisplayRampDelayMicroseconds = 120000;
static const double kDisplayHighRequestNits = 700.0;   // 满亮度区起点
static const double kDisplayTopRegionRatio = 0.90;     // 满亮度区应有 ≥90% 的输出
static const double kDisplayTopRegionCapRatio = 0.95;  // 上限不低于请求的 95% 才按满亮度区处理
static const double kDisplayCapFloorNits = 600.0;      // isolation.59：400 太低，会把被压低的上限学成原生值
static const double kDisplayCapCooldown = 2.0;
static const useconds_t kDisplayTickMicroseconds = 500000;  // isolation.57：每 0.5s 巡检一次
static const double kDisplayHeartbeatSeconds = 300.0;
static const double kDisplayRediscoverSeconds = 30.0;  // 没有可用节点时的重试间隔
static const int kDisplayIdleTicksBeforeRediscover = 20;

// —— 跨机型节点候选：按发现顺序尝试，命中即用 ——
typedef struct {
    const char *serviceClass;   // IORegistry 服务类
    const char *levelKey;       // 亮度级属性名
    const char *capKey;         // 上限属性名（可空）
    BOOL parametersDict;        // YES = 写 IODisplayParameters 里的 BrightnessMilliNits.value
} DisplayCandidate;

static const DisplayCandidate kDisplayCandidates[] = {
    {"AppleCLCD2", "IOMFBBrightnessLevel", "BLNitsCap", NO},
    {"AppleCLCD", "IOMFBBrightnessLevel", "BLNitsCap", NO},
    {"AppleDCP", "IOMFBBrightnessLevel", "BLNitsCap", NO},
    {"IOMobileFramebuffer", "IOMFBBrightnessLevel", "BLNitsCap", NO},
    {"AppleARMBacklight", "CurrentNits", NULL, NO},
    {"AppleARMBacklight", "BrightnessMilliNits", NULL, YES},
    {"AppleBacklightDisplay", "CurrentNits", NULL, NO},
    {NULL, NULL, NULL, NO},
};

// 单位候选：16.16 定点（DCP）、毫 nit（LCD 参数字典）、原始 nits
static const double kDisplayScaleCandidates[] = {65536.0, 1000.0, 1.0};

typedef struct {
    io_service_t service;
    CFStringRef levelKey;
    CFStringRef capKey;
    double scale;
    BOOL parametersDict;
    BOOL valid;
} DisplayBackend;

static DisplayBackend gBackend;
static double gLastDiscoverAttempt;
static int gIdleTicks;

#define kDisplayBucketCount 5

typedef struct {
    double req;
    double reqSince;
    double knownRatio[kDisplayBucketCount];
    double sampleReq[kDisplayBucketCount];   // 该档学习到健康样本时对应的请求亮度
    double maxCapNits;
    double lastCorrection;
    double lastCapCorrection;
    double lastHeartbeat;
} DisplayLevelState;

static DisplayLevelState gState;

static double Now(void) { return CFAbsoluteTimeGetCurrent(); }

static void EnsureCoreBrightness(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness", NULL};
    for (int i = 0; paths[i]; i++) if (dlopen(paths[i], RTLD_NOW | RTLD_LOCAL)) break;
}

// 用户当前请求的面板亮度（nits）。滑块 100% 时是面板峰值，随滑块与自动亮度变化。
static id gCBClient = nil;

static id CoreBrightnessClient(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        EnsureCoreBrightness();
        Class cls = objc_getClass("BrightnessSystemClient");
        if (!cls) return;
        @try { gCBClient = [[cls alloc] init]; } @catch (__unused NSException *e) { gCBClient = nil; }
    });
    return gCBClient;
}

static double RequestedNits(void) {
    id client = CoreBrightnessClient();
    if (!client) return 0.0;
    id display = nil;
    @try { display = ((id(*)(id, SEL, id))objc_msgSend)(client, sel_registerName("copyPropertyForKey:"), @"DisplayBrightness"); }
    @catch (__unused NSException *e) { display = nil; }
    if (![display isKindOfClass:[NSDictionary class]]) return 0.0;
    id nits = ((NSDictionary *)display)[@"Nits"];
    if (![nits respondsToSelector:@selector(doubleValue)]) return 0.0;
    double value = [nits doubleValue];
    return (value > 0.0 && value <= 10000.0) ? value : 0.0;
}

// 面板实际输出亮度（CoreBrightness 上报的 NitsPhysical）。只用于判断“主机侧已满、面板仍低”的硬件温补。
static double PhysicalNits(void) {
    id client = CoreBrightnessClient();
    if (!client) return 0.0;
    id display = nil;
    @try { display = ((id(*)(id, SEL, id))objc_msgSend)(client, sel_registerName("copyPropertyForKey:"), @"DisplayBrightness"); }
    @catch (__unused NSException *e) { display = nil; }
    if (![display isKindOfClass:[NSDictionary class]]) return 0.0;
    id nits = ((NSDictionary *)display)[@"NitsPhysical"];
    if (![nits respondsToSelector:@selector(doubleValue)]) return 0.0;
    double value = [nits doubleValue];
    return (value > 0.0 && value <= 5000.0) ? value : 0.0;
}

static CFTypeRef CopyRegistryValue(io_registry_entry_t service, CFStringRef key) {
    if (!service || !key) return NULL;
    return IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
}

static double NumberFromCF(CFTypeRef value) {
    if (!value) return -1.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID())
        return [(__bridge id)value doubleValue];
    return -1.0;
}

// 读取 LCD 参数字典里的 BrightnessMilliNits.value（毫 nit）。
static double ParametersMilliNits(io_registry_entry_t service) {
    CFTypeRef params = CopyRegistryValue(service, CFSTR("IODisplayParameters"));
    if (!params) return -1.0;
    double result = -1.0;
    if (CFGetTypeID(params) == CFDictionaryGetTypeID()) {
        NSDictionary *dict = (__bridge NSDictionary *)params;
        id entry = dict[@"BrightnessMilliNits"];
        if ([entry isKindOfClass:[NSDictionary class]]) {
            id value = ((NSDictionary *)entry)[@"value"];
            if ([value respondsToSelector:@selector(doubleValue)]) result = [value doubleValue];
        }
    }
    CFRelease(params);
    return result;
}

static double ReadLevelRaw(void) {
    if (!gBackend.valid) return -1.0;
    if (gBackend.parametersDict) return ParametersMilliNits(gBackend.service);
    CFTypeRef value = CopyRegistryValue(gBackend.service, gBackend.levelKey);
    double raw = NumberFromCF(value);
    if (value) CFRelease(value);
    return raw;
}

static double ReadLevelNits(void) {
    double raw = ReadLevelRaw();
    if (raw <= 0.0 || gBackend.scale <= 0.0) return 0.0;
    return raw / gBackend.scale;
}

static double ReadCapNits(void) {
    if (!gBackend.valid || !gBackend.capKey) return 0.0;
    CFTypeRef value = CopyRegistryValue(gBackend.service, gBackend.capKey);
    double raw = NumberFromCF(value);
    if (value) CFRelease(value);
    if (raw <= 0.0) return 0.0;
    double scale = (raw > kDisplayAbsoluteCeilingNits) ? kDisplayScaleCandidates[0] : 1.0;
    return raw / scale;
}

// —— 参考 Battman（Torrekie）的机型/版本无关实现 ——
// Battman 通过 CoreBrightness 的 VirtualBrightnessLimits 取每台机型、每个 iOS 版本
// 真正可用的最高亮度（硬件可达 / 用户可达），并用 IOMobileFramebuffer 的 block 0
// （温度补偿状态）读取面板硬件温度。这里沿用同样两条通道：
//   * 上限不再靠“学到的最大值”猜，直接取机型自报的 UserAccessibleMaxNits，
//     并用 HardwareAccessibleMaxNits 做硬保护，任何写入都不超过它；
//   * 面板温度取 IOMFB block 0 的 Q16.16 温度（v3 第 92 项 / v1 第 84 项），
//     只用于判定与日志，不写任何温度属性。
// 面板温度回退来源：AppleCLCD2 / AppleCLCD / AppleDCP 的 APTPDCTemperature（Q16.16）。
// 本机（iPhone 14,2 / iOS 16.1.2）实测可用，IOMFB block 0 不可用，所以两条都留着。
static double CPUthermalRegistryPanelTemperature(void) {
    static const char * const kClasses[] = {"AppleCLCD2", "AppleCLCD", "AppleDCP", NULL};
    for (int c = 0; kClasses[c]; c++) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(kClasses[c]));
        if (!service) continue;
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("APTPDCTemperature"), kCFAllocatorDefault, 0);
        double temp = -1.0;
        if (value && (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID())) {
            double raw = [(__bridge id)value doubleValue];
            if (raw > 0.0) temp = raw > 65536.0 ? raw / 65536.0 : raw;
        }
        if (value) CFRelease(value);
        IOObjectRelease(service);
        if (temp > 0.0) return temp;
    }
    return -1.0;
}

typedef struct {
    BOOL digitalDimming;
    BOOL edr;
    int hardwareMax;
    int hardwareMin;
    int minDimmingNits;
    int userMax;
    BOOL valid;
} CPUthermalBrightnessLimits;

static CPUthermalBrightnessLimits BrightnessLimits(void) {
    CPUthermalBrightnessLimits limits = {NO, NO, 0, 0, 0, 0, NO};
    id client = CoreBrightnessClient();
    if (!client) return limits;
    id dict = nil;
    @try { dict = ((id(*)(id, SEL, id))objc_msgSend)(client, sel_registerName("copyPropertyForKey:"), @"VirtualBrightnessLimits"); }
    @catch (__unused NSException *e) { dict = nil; }
    if (![dict isKindOfClass:[NSDictionary class]]) return limits;
    NSDictionary *d = dict;
    limits.digitalDimming = [d[@"DigitalDimmingSupported"] boolValue];
    limits.edr = [d[@"ExtrabrightEDRSupported"] boolValue];
    limits.hardwareMax = [d[@"HardwareAccessibleMaxNits"] intValue];
    limits.hardwareMin = [d[@"HardwareAccessibleMinNits"] intValue];
    limits.minDimmingNits = [d[@"MinNitsAccessibleWithDigitalDimming"] intValue];
    limits.userMax = [d[@"UserAccessibleMaxNits"] intValue];
    limits.valid = (limits.hardwareMax > 0 || limits.userMax > 0);
    return limits;
}

// 面板硬件温度（摄氏度）。IOMobileFramebuffer block 0 = 温度补偿状态，
// 96 个 uint32 的 Q16.16 结构；v3 用 [92]，v1 用 [84]。取不到返回 -1。
static double PanelHardwareTemperatureC(void) {
    static void *framework = NULL;
    static BOOL tried = NO;
    static IOReturn (*getMainDisplay)(void **) = NULL;
    static IOReturn (*getBlock)(void *, int, void *, ssize_t, void *, ssize_t) = NULL;
    if (!tried) {
        tried = YES;
        framework = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
        if (framework) {
            getMainDisplay = (IOReturn (*)(void **))dlsym(framework, "IOMobileFramebufferGetMainDisplay");
            getBlock = (IOReturn (*)(void *, int, void *, ssize_t, void *, ssize_t))dlsym(framework, "IOMobileFramebufferGetBlock");
        }
    }
    if (!getMainDisplay || !getBlock) return CPUthermalRegistryPanelTemperature();
    void *fb = NULL;
    if (getMainDisplay(&fb) != KERN_SUCCESS || !fb) return CPUthermalRegistryPanelTemperature();
    uint32_t block[96] = {0};
    // iOS 16.1.2 / iPhone 14,2 实测：block 0 返回 kIOReturnUnsupported(0xE00002C7)，
    // 只有使用 DCP 亮度且支持该 block 的机型才有值，所以必须回退 IORegistry。
    if (getBlock(fb, 0, block, sizeof(block), NULL, 0) != KERN_SUCCESS) return CPUthermalRegistryPanelTemperature();
    if (block[0] == 3) return (double)(int32_t)block[92] / 65536.0;
    if (block[0] == 1) return (double)(int32_t)block[84] / 65536.0;
    return CPUthermalRegistryPanelTemperature();
}

static void ReleaseBackend(void) {
    if (gBackend.levelKey) { CFRelease(gBackend.levelKey); gBackend.levelKey = NULL; }
    if (gBackend.capKey) { CFRelease(gBackend.capKey); gBackend.capKey = NULL; }
    if (gBackend.service) { IOObjectRelease(gBackend.service); gBackend.service = IO_OBJECT_NULL; }
    gBackend.valid = NO;
}

// 单位推断：候选比例逐个试，读数值 ÷ 请求 落在“和请求同量级”的合理区间即采用。
// 这样 16.16 定点、毫 nit、原始 nits 三种单位都能自适应，不依赖具体 iOS 版本。
static double InferScale(double raw, double requested) {
    for (size_t i = 0; i < sizeof(kDisplayScaleCandidates) / sizeof(kDisplayScaleCandidates[0]); i++) {
        double scale = kDisplayScaleCandidates[i];
        double nits = raw / scale;
        if (nits < 5.0 || nits > 3000.0) continue;
        if (requested > 0.0) {
            double ratio = nits / requested;
            if (ratio < 0.2 || ratio > 1.3) continue;
        }
        return scale;
    }
    return 0.0;
}

static BOOL DiscoverBackend(double requested) {
    ReleaseBackend();
    gLastDiscoverAttempt = Now();
    for (int i = 0; kDisplayCandidates[i].serviceClass; i++) {
        const DisplayCandidate *candidate = &kDisplayCandidates[i];
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(candidate->serviceClass));
        if (!service) continue;

        CFStringRef levelKey = CFStringCreateWithCString(kCFAllocatorDefault, candidate->levelKey, kCFStringEncodingUTF8);
        if (!levelKey) { IOObjectRelease(service); continue; }

        double raw = -1.0;
        if (candidate->parametersDict) raw = ParametersMilliNits(service);
        else {
            CFTypeRef value = CopyRegistryValue(service, levelKey);
            raw = NumberFromCF(value);
            if (value) CFRelease(value);
        }
        double scale = (raw > 0.0) ? InferScale(raw, requested) : 0.0;
        if (scale <= 0.0) { CFRelease(levelKey); IOObjectRelease(service); continue; }

        gBackend.service = service;
        gBackend.levelKey = levelKey;
        gBackend.parametersDict = candidate->parametersDict;
        gBackend.scale = scale;
        gBackend.capKey = candidate->capKey
            ? CFStringCreateWithCString(kCFAllocatorDefault, candidate->capKey, kCFStringEncodingUTF8) : NULL;
        gBackend.valid = YES;
        os_log(DisplayLevelLog(), "displayLevel backend %{public}s key=%{public}s scale=%{public}.0f dict=%{public}d",
               candidate->serviceClass, candidate->levelKey, scale, (int)candidate->parametersDict);
        return YES;
    }
    os_log(DisplayLevelLog(), "displayLevel backend unavailable (no writable display node)");
    return NO;
}

static void WriteLevelNits(double nits) {
    if (!gBackend.valid) return;
    if (gBackend.parametersDict) {
        CFTypeRef params = CopyRegistryValue(gBackend.service, CFSTR("IODisplayParameters"));
        if (!params) return;
        if (CFGetTypeID(params) == CFDictionaryGetTypeID()) {
            NSMutableDictionary *dict = [(__bridge NSDictionary *)params mutableCopy];
            id entry = dict[@"BrightnessMilliNits"];
            if ([entry isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *number = [entry mutableCopy];
                number[@"value"] = @(nits * 1000.0);
                dict[@"BrightnessMilliNits"] = number;
                CPUthermalIORegistryEntrySetCFProperty(gBackend.service, CFSTR("IODisplayParameters"),
                                                       (__bridge CFTypeRef)dict);
            }
        }
        CFRelease(params);
        return;
    }
    long long raw = (long long)(nits * gBackend.scale + 0.5);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &raw);
    if (!number) return;
    CPUthermalIORegistryEntrySetCFProperty(gBackend.service, gBackend.levelKey, number);
    CFRelease(number);
}

static void WriteCapNits(double nits) {
    if (!gBackend.valid || !gBackend.capKey) return;
    long long raw = (long long)(nits * kDisplayScaleCandidates[0] + 0.5);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &raw);
    if (!number) return;
    CPUthermalIORegistryEntrySetCFProperty(gBackend.service, gBackend.capKey, number);
    CFRelease(number);
}

static int BucketForRequest(double req) {
    static const double upper[kDisplayBucketCount] = {100.0, 300.0, 600.0, 900.0, 2000.0};
    for (int i = 0; i < kDisplayBucketCount; i++) if (req <= upper[i]) return i;
    return kDisplayBucketCount - 1;
}

static BOOL LevelGuardEnabled(NSDictionary *prefs) {
    id enabled = prefs[S("enabled")];
    if (![enabled respondsToSelector:@selector(boolValue)]) return YES;
    return [enabled boolValue];
}

static BOOL FullPowerMode(NSDictionary *prefs) {
    id mode = prefs[S("powerMode")] ?: prefs[S("thermalRunMode")];
    if (![mode isKindOfClass:[NSString class]]) return YES;
    return [mode isEqualToString:S("fullPower")];
}

// 把面板亮度级抬到 target：落差大时分两段写，避免一次性跳变被看成闪屏。
// 只升不降由调用方保证；这里也再挡一次，防止任何路径把屏幕写暗。
static void RaiseLevel(double current, double target, double requested) {
    if (target <= current + kDisplayDeadbandNits) return;
    if (target > requested * 1.02) target = requested;
    if (target > kDisplayAbsoluteCeilingNits) target = kDisplayAbsoluteCeilingNits;
    double gap = target - current;
    if (gap > target * kDisplayRampThreshold) {
        WriteLevelNits(current + gap * 0.6);
        usleep(kDisplayRampDelayMicroseconds);
    }
    WriteLevelNits(target);
    double readback = ReadLevelNits();
    os_log(DisplayLevelLog(),
           "displayLevel raised req=%{public}.1f was=%{public}.1f target=%{public}.1f readback=%{public}.1f",
           requested, current, target, readback);
}

// isolation.57：巡检已到 0.5s 一次，偏好 plist 不再每一拍都读盘/解析，2 秒缓存一次。
static NSDictionary *CachedPrefs(void) {
    static NSDictionary *cached = nil;
    static double lastRead = 0.0;
    double now = Now();
    if (!cached || (now - lastRead) > 2.0) {
        cached = CPUthermalReadPrefs() ?: @{};
        lastRead = now;
    }
    return cached;
}

static void GuardOnce(void) {
    NSDictionary *prefs = CachedPrefs();
    if (!LevelGuardEnabled(prefs) || !FullPowerMode(prefs)) return;

    double requested = RequestedNits();
    if (requested < kDisplayFloorNits) { gState.req = requested; gState.reqSince = Now(); return; }

    double now = Now();
    if (!gBackend.valid && (now - gLastDiscoverAttempt) > kDisplayRediscoverSeconds) {
        if (!DiscoverBackend(requested)) return;
    }
    if (!gBackend.valid) return;

    double level = ReadLevelNits();
    if (level <= 0.0) {
        // 外接屏、熄屏或节点暂时无值：长时间拿不到就重新发现一次，绝不瞎写。
        if (++gIdleTicks > kDisplayIdleTicksBeforeRediscover) { gIdleTicks = 0; ReleaseBackend(); }
        return;
    }
    gIdleTicks = 0;
    double cap = ReadCapNits();

    // 机型自报上限（Battman 方案）：UserAccessibleMaxNits 是守护目标，
    // HardwareAccessibleMaxNits 是硬顶，任何写入都不会越过它。
    CPUthermalBrightnessLimits limits = BrightnessLimits();
    double panelTemperature = PanelHardwareTemperatureC();
    double deviceCeiling = 0.0;
    if (limits.userMax > 0) deviceCeiling = limits.userMax;
    else if (limits.hardwareMax > 0) deviceCeiling = limits.hardwareMax;
    else if (cap > 0.0) deviceCeiling = cap;

    // 守护目标：用户请求，但不越过机型能力，也不越过面板上限。
    double guardTarget = requested;
    if (deviceCeiling > 0.0 && guardTarget > deviceCeiling) guardTarget = deviceCeiling;
    if (limits.hardwareMax > 0 && guardTarget > limits.hardwareMax) guardTarget = limits.hardwareMax;
    if (cap > 0.0 && guardTarget > cap) guardTarget = cap;

    if (fabs(requested - gState.req) > 2.0) { gState.req = requested; gState.reqSince = now; }
    if (gState.reqSince <= 0.0) gState.reqSince = now;
    BOOL stable = (now - gState.reqSince) >= kDisplayStableSeconds;

    if (cap > gState.maxCapNits && cap <= kDisplayAbsoluteCeilingNits) gState.maxCapNits = cap;

    double ratio = level / requested;
    int bucket = BucketForRequest(requested);
    double known = gState.knownRatio[bucket];
    BOOL muted = (now - gState.lastCorrection) < kDisplayLearnMuteAfterCorrection;
    BOOL ratioLooksHealthy = (ratio >= kDisplayPlausibleRatioMin && ratio <= kDisplayPlausibleRatioMax);
    // 满亮度区（请求已经接近面板上限）：这里的“正常映射”就是 1.0，面板应当输出到上限。
    // 实测户外请求 1060、上限也是 1060，面板级却只到上限的 80%，若把它当“健康比例”学进去，
    // 之后所有纠正都会被这 0.80 锁死、永远差 20%。所以这一区既不许学习，也不许按比例纠正。
    BOOL topRegion = (requested >= kDisplayHighRequestNits) &&
                     (cap <= 0.0 || cap >= requested * kDisplayTopRegionCapRatio);
    // 低亮度段系统的 请求→面板级 曲线本身很陡，同一个桶里换了请求值也可能差很多。
    // 所以“被压”只在两种条件同时成立时才算：该档学过健康样本，且当前请求离那个样本不远。
    BOOL nearby = (known > 0.0 && gState.sampleReq[bucket] > 0.0 &&
                   fabs(requested - gState.sampleReq[bucket]) <= gState.sampleReq[bucket] * kDisplaySampleProximity);
    BOOL ratioCollapsed = (known > 0.0 && ratio < known * kDisplayClampRatioFactor);

    // 1) 学习系统自身的映射比例。只采信“看起来正常”的样本，且绝不把被压后的低比例学进去。
    BOOL topRegionUnderDelivered = topRegion && ratio < kDisplayTopRegionRatio;
    if (stable && ratioLooksHealthy && !muted && !ratioCollapsed && !topRegionUnderDelivered) {
        gState.knownRatio[bucket] = (known > 0.0) ? (known * 0.7 + ratio * 0.3) : ratio;
        gState.sampleReq[bucket] = requested;
        known = gState.knownRatio[bucket];
    }

    // 2) 上限被压低时抬回已见最大值（只升不降）。
    if (cap > 0.0 && gBackend.capKey && gState.maxCapNits >= kDisplayCapFloorNits &&
        cap < gState.maxCapNits * 0.95 && requested >= 50.0 &&
        (now - gState.lastCapCorrection) > kDisplayCapCooldown) {
        WriteCapNits(gState.maxCapNits);
        double readback = ReadCapNits();
        os_log(DisplayLevelLog(), "displayLevel cap raised was=%{public}.1f target=%{public}.1f readback=%{public}.1f",
               cap, gState.maxCapNits, readback);
        gState.lastCapCorrection = now;
    }

    // 2.5) 机型守护（Battman 方案，优先于学习式纠正）：
    //      面板级只要明显低于“用户请求且不超过机型能力”的目标，就立刻抬回；
    //      与温度无关地执行——温控压低正是要挡的对象，温度只用于日志与诊断。
    BOOL deviceGuarded = (deviceCeiling > 0.0 && guardTarget > kDisplayFloorNits &&
                          level + kDisplayDeadbandNits < guardTarget * kDisplayTopRegionRatio);
    if (deviceGuarded && (now - gState.lastCorrection) > kDisplayCorrectionCooldown) {
        RaiseLevel(level, guardTarget, requested);
        gState.lastCorrection = Now();
        os_log(DisplayLevelLog(),
               "displayLevel device guard req=%{public}.1f level=%{public}.1f target=%{public}.1f userMax=%{public}d hwMax=%{public}d panelTemp=%{public}.2f",
               requested, level, guardTarget, limits.userMax, limits.hardwareMax, panelTemperature);
    }

    // 3) 纠正被压暗的面板亮度级。
    //    满亮度区：目标就是请求本身（面板应当到上限），阈值 95%；
    //    其余区间：目标 = 请求 × 已学系统映射比例，且必须是“邻近健康样本 + 比例塌陷”才动手。
    double expected = topRegion ? 1.0 : known;
    // isolation.57：还没有学到健康样本时，只要面板级跌到请求的一半以下也算被压，
    // 立刻按请求的 85% 抬回，不再等“先学样本、再判塌陷”。
    BOOL hardCollapse = (known <= 0.0 && requested >= kDisplayFloorNits && ratio < 0.5);
    BOOL clamped = topRegion ? (ratio < kDisplayTopRegionRatio)
                             : (hardCollapse || (nearby && ratioCollapsed) ||
                                (known <= 0.0 && expected > 0.0 && ratio < expected * kDisplayClampRatioFactor));
    if (stable && clamped && (now - gState.lastCorrection) > kDisplayCorrectionCooldown) {
        double target = requested * (hardCollapse ? 0.85 : expected);
        if (cap > 0.0 && target > cap) target = cap;
        if (target - level > kDisplayDeadbandNits) {
            RaiseLevel(level, target, requested);
            gState.lastCorrection = Now();
        }
    }

    // isolation.57 取证：主机侧已经把面板级抬到请求值、但 CoreBrightness 上报的物理亮度
    // 仍明显低于面板级时，说明压暗发生在面板/DCP 固件（温度补偿），主机侧写不动，只记日志。
    static double lastPhysicalLog = 0.0;
    if ((now - lastPhysicalLog) >= 5.0) {
        lastPhysicalLog = now;
        double physical = PhysicalNits();
        if (physical > 0.0 && level > 0.0 && physical < level * 0.75) {
            os_log(DisplayLevelLog(),
                   "displayLevel panel-limited req=%{public}.1f level=%{public}.1f physical=%{public}.1f userMax=%{public}d hwMax=%{public}d panelTemp=%{public}.2f",
                   requested, level, physical, limits.userMax, limits.hardwareMax, panelTemperature);
        }
    }

    if ((now - gState.lastHeartbeat) >= kDisplayHeartbeatSeconds) {
        gState.lastHeartbeat = now;
        os_log(DisplayLevelLog(),
               "displayLevel heartbeat req=%{public}.1f level=%{public}.1f ratio=%{public}.3f known=%{public}.3f cap=%{public}.1f bucket=%{public}d scale=%{public}.0f",
               requested, level, ratio, gState.knownRatio[bucket], cap, bucket, gBackend.scale);
    }
}

int main(void) {
    @autoreleasepool {
        memset(&gState, 0, sizeof(gState));
        memset(&gBackend, 0, sizeof(gBackend));
        os_log(DisplayLevelLog(), "displayLevel started isolation.53");
        while (1) {
            @autoreleasepool {
                @try { GuardOnce(); }
                @catch (__unused NSException *e) { }
            }
            usleep(kDisplayTickMicroseconds);
        }
    }
    return 0;
}
