// 解除温控模式下的显示亮度纠正守护（isolation.51）。
//
// 为什么仍然是独立进程：实测 thermalmonitord（核心 tweak 所在进程）写 AppleCLCD2 的
// IOMFBBrightnessLevel 会被内核拒绝（kr=0xE00002E2），而带显示 IOKit 授权的普通用户态
// 进程写同一个属性是 kr=0 且立即生效。所以“判断”可以放在核心，真正的“写”必须在这里。
//
// isolation.48 的版本为什么被撤掉：它把“用户请求的 nits”当成目标值，每 2 秒无条件比对
// 一次。CoreBrightness 自己会把请求映射成面板级（实测请求 97.28 nits 时面板 83.57，
// 约 0.86），于是守护进程的“纠正”实际上是在系统正常映射之上再抬 16%，用户一拖滑块就
// 出现二次跳变/闪屏。
//
// isolation.51 的判据改成“只补回落差”：
//   1. 按请求亮度分桶，学习系统自身的 面板级/请求 比例（= 系统的正常映射，不硬编码）；
//   2. 只有请求稳定 2 秒后，比例突然跌到已学比例的 80% 以下，才认定是被压暗；
//   3. 目标 = 请求 × 已学比例（不是原始请求），所以不会高于系统本来该给的亮度；
//   4. 只升不降，单次纠正后冷却 20 秒，落差过大时分两段渐变写入；
//   5. 高亮度区（请求 ≥ 700 nits）在第一桶还没学到时用兜底规则，因为该区间映射接近 1.0；
//   6. BLNitsCap 被压低时按已见最大值抬回（只升不降、30 秒冷却）。
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

static const double kDisplayFixedPointScale = 65536.0;
static const double kDisplayFloorNits = 40.0;          // 低于此亮度完全不管（暗环境/待机）
static const double kDisplayDeadbandNits = 8.0;        // 小于此差值不值得写
static const double kDisplayAbsoluteCeilingNits = 2000.0;
static const double kDisplayStableSeconds = 2.0;       // 请求必须稳定这么久才判定
static const double kDisplayClampRatioFactor = 0.80;   // 比例跌到已学值的 80% 以下 = 被压
static const double kDisplaySampleProximity = 0.20;    // 当前请求离学习样本不超过 20% 才判定
static const double kDisplayPlausibleRatioMin = 0.50;
static const double kDisplayPlausibleRatioMax = 1.05;
static const double kDisplayCorrectionCooldown = 20.0;
static const double kDisplayLearnMuteAfterCorrection = 3.0;
static const double kDisplayRampThreshold = 0.25;      // 落差超过目标的 25% 时分两段
static const useconds_t kDisplayRampDelayMicroseconds = 120000;
static const double kDisplayHighRequestNits = 700.0;   // 高亮度兜底
static const double kDisplayHighRequestRatio = 0.75;
static const double kDisplayCapFloorNits = 400.0;      // 低于此值的上限读数不可信
static const double kDisplayCapCooldown = 30.0;
static const useconds_t kDisplayTickMicroseconds = 500000;
static const double kDisplayHeartbeatSeconds = 300.0;

// 请求亮度分桶：系统映射随亮度区间变化，逐桶学习才不会跨区间互相污染。
#define kDisplayBucketCount 5
static const double kDisplayBucketUpper[kDisplayBucketCount] = {100.0, 300.0, 600.0, 900.0, 2000.0};

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

// 用户当前请求的面板亮度（nits）。滑块 100% 时是面板峰值，随滑块与自动亮度实时变化。
static double RequestedNits(void) {
    static id client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        EnsureCoreBrightness();
        Class cls = objc_getClass("BrightnessSystemClient");
        if (!cls) return;
        @try { client = [[cls alloc] init]; } @catch (__unused NSException *e) { client = nil; }
    });
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

static double RegistryNits(io_registry_entry_t service, CFStringRef key) {
    if (!service || !key) return 0.0;
    double result = 0.0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID()) {
            double raw = [(__bridge id)value doubleValue];
            result = raw > kDisplayFixedPointScale ? raw / kDisplayFixedPointScale : raw;
        }
        CFRelease(value);
    }
    return (result > 0.0) ? result : 0.0;
}

static void WriteRegistryNits(io_registry_entry_t service, CFStringRef key, double nits) {
    long long raw = (long long)(nits * kDisplayFixedPointScale + 0.5);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &raw);
    if (!number) return;
    CPUthermalIORegistryEntrySetCFProperty(service, key, number);
    CFRelease(number);
}

static int BucketForRequest(double req) {
    for (int i = 0; i < kDisplayBucketCount; i++) if (req <= kDisplayBucketUpper[i]) return i;
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
static double RaiseLevel(io_registry_entry_t service, double current, double target, double requested) {
    if (target <= current + kDisplayDeadbandNits) return 0.0;
    if (target > requested * 1.02) target = requested;
    if (target > kDisplayAbsoluteCeilingNits) target = kDisplayAbsoluteCeilingNits;
    double gap = target - current;
    if (gap > target * kDisplayRampThreshold) {
        double step = current + gap * 0.6;
        WriteRegistryNits(service, CFSTR("IOMFBBrightnessLevel"), step);
        usleep(kDisplayRampDelayMicroseconds);
    }
    WriteRegistryNits(service, CFSTR("IOMFBBrightnessLevel"), target);
    double readback = RegistryNits(service, CFSTR("IOMFBBrightnessLevel"));
    os_log(DisplayLevelLog(),
           "displayLevel raised req=%{public}.1f was=%{public}.1f target=%{public}.1f readback=%{public}.1f",
           requested, current, target, readback);
    return readback;
}

static void GuardOnce(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    if (!LevelGuardEnabled(prefs) || !FullPowerMode(prefs)) return;

    double requested = RequestedNits();
    if (requested < kDisplayFloorNits) { gState.req = requested; gState.reqSince = Now(); return; }

    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleCLCD2"));
    if (!service) return;

    double level = RegistryNits(service, CFSTR("IOMFBBrightnessLevel"));
    double cap = RegistryNits(service, CFSTR("BLNitsCap"));
    if (level <= 0.0) { IOObjectRelease(service); return; }

    double now = Now();
    if (fabs(requested - gState.req) > 2.0) { gState.req = requested; gState.reqSince = now; }
    if (gState.reqSince <= 0.0) gState.reqSince = now;
    BOOL stable = (now - gState.reqSince) >= kDisplayStableSeconds;

    if (cap > gState.maxCapNits && cap <= kDisplayAbsoluteCeilingNits) gState.maxCapNits = cap;

    double ratio = level / requested;
    int bucket = BucketForRequest(requested);
    double known = gState.knownRatio[bucket];
    BOOL muted = (now - gState.lastCorrection) < kDisplayLearnMuteAfterCorrection;
    BOOL ratioLooksHealthy = (ratio >= kDisplayPlausibleRatioMin && ratio <= kDisplayPlausibleRatioMax);
    // 低亮度段系统的 请求→面板级 曲线本身很陡，同一个桶里换了请求值也可能差很多。
    // 所以“被压”只在两种条件同时成立时才算：该档学过健康样本，且当前请求离那个样本不远。
    BOOL nearby = (known > 0.0 && gState.sampleReq[bucket] > 0.0 &&
                   fabs(requested - gState.sampleReq[bucket]) <= gState.sampleReq[bucket] * kDisplaySampleProximity);
    BOOL ratioCollapsed = (known > 0.0 && ratio < known * kDisplayClampRatioFactor);

    // 1) 学习系统自身的映射比例。只采信“看起来正常”的样本，且绝不把被压后的低比例学进去。
    if (stable && ratioLooksHealthy && !muted && !ratioCollapsed) {
        gState.knownRatio[bucket] = (known > 0.0) ? (known * 0.7 + ratio * 0.3) : ratio;
        gState.sampleReq[bucket] = requested;
        known = gState.knownRatio[bucket];
    }

    // 2) BLNitsCap 被压低时抬回已见最大值（只升不降）。
    if (cap > 0.0 && gState.maxCapNits >= kDisplayCapFloorNits &&
        cap < gState.maxCapNits * 0.95 && requested >= 200.0 &&
        (now - gState.lastCapCorrection) > kDisplayCapCooldown) {
        WriteRegistryNits(service, CFSTR("BLNitsCap"), gState.maxCapNits);
        double readback = RegistryNits(service, CFSTR("BLNitsCap"));
        os_log(DisplayLevelLog(), "displayLevel cap raised was=%{public}.1f target=%{public}.1f readback=%{public}.1f",
               cap, gState.maxCapNits, readback);
        gState.lastCapCorrection = now;
    }

    // 3) 纠正被压暗的面板亮度级。目标 = 请求 × 已学映射比例；没有历史时对高亮度区兜底。
    double expected = known;
    if (expected <= 0.0 && requested >= kDisplayHighRequestNits &&
        (cap <= 0.0 || cap >= requested * 0.98) && ratio < kDisplayHighRequestRatio) {
        expected = 1.0;
    }
    BOOL clamped = (nearby && ratioCollapsed) ||
        (known <= 0.0 && expected > 0.0 && ratio < expected * kDisplayClampRatioFactor);
    if (stable && clamped && (now - gState.lastCorrection) > kDisplayCorrectionCooldown) {
        double target = requested * expected;
        if (cap > 0.0 && target > cap) target = cap;
        if (target - level > kDisplayDeadbandNits) {
            RaiseLevel(service, level, target, requested);
            gState.lastCorrection = Now();
        }
    }

    if ((now - gState.lastHeartbeat) >= kDisplayHeartbeatSeconds) {
        gState.lastHeartbeat = now;
        os_log(DisplayLevelLog(),
               "displayLevel heartbeat req=%{public}.1f level=%{public}.1f ratio=%{public}.3f known=%{public}.3f cap=%{public}.1f bucket=%{public}d",
               requested, level, ratio, gState.knownRatio[bucket], cap, bucket);
    }
    IOObjectRelease(service);
}

int main(void) {
    @autoreleasepool {
        memset(&gState, 0, sizeof(gState));
        os_log(DisplayLevelLog(), "displayLevel started isolation.51");
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
