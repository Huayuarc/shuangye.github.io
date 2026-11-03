// 解除温控模式下的显示亮度跟随守护进程。
//
// 为什么必须是独立进程：实测 thermalmonitord（核心 tweak 所在进程）写
// AppleCLCD2 的 IOMFBBrightnessLevel 会被内核拒绝（kr=0xE00002E2），而带显示
// IOKit 授权的普通用户态进程写同一个属性是 kr=0 且立即生效。核心 tweak 只能把
// “想写什么”算出来，真正落地的写必须放在有授权的进程里，所以做成这个守护进程。
//
// 行为：目标 = min(CoreBrightness 里用户滑块请求的 nits, 850)，每 2 秒比一次，
// 差值超过 8 nits 才写；低于 20 nits 不干预；只在总开关打开且「解除温控」模式生效。
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <os/log.h>
#import <unistd.h>
#import <CPUthermalPaths.h>
#import <CPUthermalCompat.h>

#define kIOMasterPortDefault MACH_PORT_NULL
extern kern_return_t CPUthermalIORegistryEntrySetCFProperty(io_registry_entry_t, CFStringRef, CFTypeRef) __asm("_IORegistryEntrySetCFProperty");

static os_log_t DisplayLevelLog(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.huayuarc.cputhermal", "display-level"); });
    return logger;
}

// 13 Pro 的 SDR 典型最大亮度；面板里可以让用户按自己设备改（100~2000）。
static const double kDisplayDefaultCeilingNits = 850.0;
static const double kDisplayMinimumCeilingNits = 100.0;
static const double kDisplayMaximumCeilingNits = 2000.0;
static const double kDisplayDeadbandNits = 8.0;
static const double kDisplayFloorNits = 20.0;
static const double kDisplayFixedPointScale = 65536.0;
static const useconds_t kDisplayTickMicroseconds = 2000000;

static void EnsureCoreBrightness(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness", NULL};
    for (int i = 0; paths[i]; i++) if (dlopen(paths[i], RTLD_NOW | RTLD_LOCAL)) break;
}

// 用户当前请求的面板亮度（nits）。滑块 100% 时是面板峰值，随滑块实时变化。
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

static double CurrentLevelNits(io_registry_entry_t service) {
    if (!service) return 0.0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("IOMFBBrightnessLevel"), kCFAllocatorDefault, 0);
    double level = 0.0;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFStringGetTypeID())
            level = [(__bridge id)value doubleValue] / kDisplayFixedPointScale;
        CFRelease(value);
    }
    return level;
}

static BOOL ShieldEnabled(NSDictionary *prefs) {
    // 面板开关：显示亮度锁定（缺省视为开，只有显式关掉才停用）
    id lock = prefs[S("displayNitsLockEnabled")];
    BOOL lockOn = [lock respondsToSelector:@selector(boolValue)] ? [lock boolValue] : YES;
    if (!lockOn) return NO;
    id enabled = prefs[S("enabled")];
    return enabled ? [enabled boolValue] : YES;
}

// 用户填写的最高亮度；缺失或非法时退回 850，并夹紧到安全范围。
static double CeilingNits(NSDictionary *prefs) {
    id value = prefs[S("displayNitsCeiling")];
    double ceiling = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!(ceiling > 0.0)) ceiling = kDisplayDefaultCeilingNits;
    if (ceiling < kDisplayMinimumCeilingNits) ceiling = kDisplayMinimumCeilingNits;
    if (ceiling > kDisplayMaximumCeilingNits) ceiling = kDisplayMaximumCeilingNits;
    return ceiling;
}

static BOOL FullPowerMode(NSDictionary *prefs) {
    id mode = prefs[S("powerMode")] ?: prefs[S("thermalRunMode")];
    if (![mode isKindOfClass:[NSString class]]) return YES;   // 缺省按解除温控处理
    return [mode isEqualToString:S("fullPower")];
}

static void EnforceOnce(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    if (!ShieldEnabled(prefs) || !FullPowerMode(prefs)) return;
    double requested = RequestedNits();
    if (requested <= 0.0) return;
    double ceiling = CeilingNits(prefs);
    double target = requested > ceiling ? ceiling : requested;
    if (target < kDisplayFloorNits) return;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleCLCD2"));
    if (!service) return;
    double current = CurrentLevelNits(service);
    if (current > 0.0 && fabs(current - target) > kDisplayDeadbandNits) {
        long long raw = (long long)(target * kDisplayFixedPointScale + 0.5);
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &raw);
        kern_return_t kr = number ? CPUthermalIORegistryEntrySetCFProperty(service, CFSTR("IOMFBBrightnessLevel"), number) : KERN_RESOURCE_SHORTAGE;
        double readback = CurrentLevelNits(service);
        os_log(DisplayLevelLog(), "displayLevel req=%{public}.1f target=%{public}.1f was=%{public}.1f kr=%{public}d readback=%{public}.1f",
               requested, target, current, (int)kr, readback);
        if (number) CFRelease(number);
    } else {
        // 每分钟一条心跳：安装后无需让屏幕可见变化也能确认守护在跑、目标对不对。
        static CFAbsoluteTime lastHeartbeat = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastHeartbeat >= 60.0) {
            lastHeartbeat = now;
            os_log(DisplayLevelLog(), "displayLevel heartbeat req=%{public}.1f target=%{public}.1f current=%{public}.1f",
                   requested, target, current);
        }
    }
    IOObjectRelease(service);
}

int main(void) {
    @autoreleasepool {
        os_log(DisplayLevelLog(), "displayLevelDaemon started");
        while (1) {
            @autoreleasepool {
                @try { EnforceOnce(); }
                @catch (__unused NSException *e) { }
            }
            usleep(kDisplayTickMicroseconds);
        }
    }
    return 0;
}
