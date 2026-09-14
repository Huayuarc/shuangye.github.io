// ============================================================================
// CPUthermalPowerGuard — CPU 降频守护 + 探针（注入 powerd / thermalmonitord）
//
// 背景：CPU/GPU 频率上限不是 thermalmonitord 一个人说了算。
//   - thermalmonitord 负责“热压”决策；
//   - powerd 通过 ApplePPM / IOKit 向内核申请 CPU 性能等级与功率上限。
// 之前只注入 thermalmonitord，powerd 这条通道完全没人管 —— 这就是“开着插件
// 依然降频”的盲区。本模块补齐 powerd 侧：
//   1) 丢弃 powerd 发出的 CPU/GPU/热压类约束属性（只拦上限，不拦 floor/minimum）；
//   2) 阻断 ApplePPMCPU 的降频等级请求，保持内核原生 DVFS；
//   3) 记录 IOConnect / IOKit 写入与实时频率，便于确认剩余压制来自哪一层。
// 日志：cputhermal-throttle.log（/usr/local/share/CPUthermal、/var/jb/...、
//       /var/mobile/Library/CPUthermal、/var/tmp、/tmp）
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>
#include <notify.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <stdarg.h>
#import <substrate.h>
#import <CPUthermalPaths.h>

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
static NSString *gTag = @"?";
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static int gLogCount = 0;
static const int kLogMaxLines = 12000;
static CFAbsoluteTime gWinStart = 0;
static int gWinCount = 0;

static void TLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message.length == 0) return;
    pthread_mutex_lock(&gLogLock);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gWinStart > 1.0) { gWinStart = now; gWinCount = 0; }
    if (gWinCount >= 80 || gLogCount >= kLogMaxLines) { pthread_mutex_unlock(&gLogLock); return; }
    gWinCount++; gLogCount++;
    NSString *line = [NSString stringWithFormat:@"[%.3f][%@] %@\n", now, gTag, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[@"/usr/local/share/CPUthermal", @"/var/jb/usr/local/share/CPUthermal",
                            @"/var/mobile/Library/CPUthermal", @"/var/tmp", @"/tmp"]) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSString *path = [dir stringByAppendingPathComponent:@"cputhermal-throttle.log"];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions:@0644}];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) continue;
        @try { [handle seekToEndOfFile]; [handle writeData:data]; [handle closeFile]; }
        @catch (__unused NSException *e) { }
        break;
    }
    pthread_mutex_unlock(&gLogLock);
}

// ---------------------------------------------------------------------------
// 开关（与主模块一致：面板总开关开启即生效）
// ---------------------------------------------------------------------------
static BOOL gDropEnabled = NO;   // 仅 powerd 侧执行丢弃，避免与主模块重复拦截

static BOOL GuardEnabled(void) {
    @try {
        NSDictionary *prefs = CPUthermalReadPrefs();
        return [prefs[S("enabled")] boolValue];
    } @catch (__unused NSException *e) { return NO; }
}

// ---------------------------------------------------------------------------
// 频率 / 热压采样
// ---------------------------------------------------------------------------
static uint64_t SysctlU64(const char *name) {
    uint64_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname(name, &value, &size, NULL, 0) != 0) return 0;
    return value;
}

static int ThermalPressureLevel(void) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) {
        if (notify_register_check("kOSThermalNotificationPressureLevel", &token) != NOTIFY_STATUS_OK) {
            registered = YES; // 注册失败也不要反复重试
            return -1;
        }
        registered = YES;
    }
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return -1;
    return (int)state;
}

static int ThermalStateValue(void) {
    @try {
        return (int)[[NSProcessInfo processInfo] thermalState];
    } @catch (__unused NSException *e) { return -1; }
}

static void SampleFrame(const char *reason) {
    uint64_t cur = SysctlU64("hw.cpufrequency");
    uint64_t max = SysctlU64("hw.cpufrequency_max");
    uint64_t min = SysctlU64("hw.cpufrequency_min");
    TLog(@"SAMPLE[%s] cur=%.0fMHz max=%.0fMHz min=%.0fMHz pressure=%d thermalState=%d",
         reason, cur / 1e6, max / 1e6, min / 1e6, ThermalPressureLevel(), ThermalStateValue());
}

static void FrameTimer(void) {
    SampleFrame("tick");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ FrameTimer(); });
}

// ---------------------------------------------------------------------------
// 热压上限键判定（只拦“上限/节流”，放行 floor/minimum 与显示类键）
// ---------------------------------------------------------------------------
static BOOL IsThermalLimitKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *lower = [key lowercaseString];
    if ([lower containsString:@"bright"] || [lower containsString:@"nits"] ||
        [lower containsString:@"display"] || [lower containsString:@"backlight"]) return NO;
    if ([lower containsString:@"floor"] || [lower containsString:@"minimum"]) return NO;

    if ([lower containsString:@"throttle"] || [lower containsString:@"mitigat"]) return YES;
    BOOL component = [lower containsString:@"cpu"] || [lower containsString:@"core"] ||
                     [lower containsString:@"ppm"] || [lower containsString:@"processor"] ||
                     [lower containsString:@"gpu"] || [lower containsString:@"package"] ||
                     [lower containsString:@"thermal"] || [lower containsString:@"soc"];
    if (!component) return NO;
    BOOL limitish = [lower containsString:@"limit"] || [lower containsString:@"cap"] ||
                    [lower containsString:@"ceiling"] || [lower containsString:@"target"] ||
                    [lower containsString:@"freq"] || [lower containsString:@"speed"] ||
                    [lower containsString:@"power"] || [lower containsString:@"level"] ||
                    [lower containsString:@"state"] || [lower containsString:@"pressure"];
    return limitish;
}

static BOOL IsInterestingService(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    for (NSString *token in @[@"ppm", @"armpe", @"pmgr", @"pmu", @"smc", @"clpc", @"thermal", @"cpu", @"power", @"voltage"]) {
        if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// IOKit 拦截：丢弃 powerd 发出的 CPU/热压上限
// ---------------------------------------------------------------------------
%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    @try {
        if (gDropEnabled && GuardEnabled() && key) {
            NSString *keyString = (__bridge NSString *)key;
            if (IsThermalLimitKey(keyString)) {
                TLog(@"DROP IORegistryEntrySetCFProperty %@ = %@", keyString, value ? (__bridge id)value : @"(null)");
                return KERN_SUCCESS;
            }
        }
    } @catch (__unused NSException *e) { }
    return %orig;
}

%hookf(kern_return_t, IORegistryEntrySetCFProperties, io_registry_entry_t entry, CFTypeRef properties) {
    @try {
        if (gDropEnabled && GuardEnabled() && properties && CFGetTypeID(properties) == CFDictionaryGetTypeID()) {
            NSDictionary *dict = (__bridge NSDictionary *)properties;
            NSMutableDictionary *keep = [NSMutableDictionary dictionary];
            NSMutableArray *dropped = [NSMutableArray array];
            for (id key in dict) {
                if ([key isKindOfClass:[NSString class]] && IsThermalLimitKey(key)) [dropped addObject:key];
                else keep[key] = dict[key];
            }
            if (dropped.count) {
                TLog(@"DROP IORegistryEntrySetCFProperties keys=%@", [dropped componentsJoinedByString:@","]);
                if (keep.count == 0) return KERN_SUCCESS;
                return %orig(entry, (__bridge CFTypeRef)keep);
            }
        }
    } @catch (__unused NSException *e) { }
    return %orig;
}

static kern_return_t (*orig_PowerGuardServiceSetProperty)(io_service_t, CFStringRef, CFTypeRef) = NULL;

static kern_return_t PowerGuardServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {
    if (!orig_PowerGuardServiceSetProperty) return KERN_FAILURE;
    @try {
        if (gDropEnabled && GuardEnabled() && key) {
            NSString *keyString = (__bridge NSString *)key;
            if (IsThermalLimitKey(keyString)) {
                TLog(@"DROP IOServiceSetProperty %@ = %@", keyString, value ? (__bridge id)value : @"(null)");
                return KERN_SUCCESS;
            }
        }
    } @catch (__unused NSException *e) { }
    return orig_PowerGuardServiceSetProperty(service, key, value);
}

// ---------------------------------------------------------------------------
// 连接追踪 + IOConnect 记录（只记录，不改写）
// ---------------------------------------------------------------------------
static NSMutableDictionary *gConns = nil;

%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_t task, uint32_t type, io_connect_t *connect) {
    kern_return_t ret = %orig;
    @try {
        if (ret == KERN_SUCCESS && connect && *connect != MACH_PORT_NULL) {
            io_name_t name = {0};
            IORegistryEntryGetName(service, name);
            CFTypeRef cls = IORegistryEntryCreateCFProperty(service, CFSTR("IOObjectClass"), kCFAllocatorDefault, 0);
            NSString *className = cls ? [NSString stringWithFormat:@"%@", (__bridge id)cls] : @"?";
            if (cls) CFRelease(cls);
            NSString *serviceName = [NSString stringWithUTF8String:name] ?: @"?";
            if (IsInterestingService(serviceName) || IsInterestingService(className)) {
                if (!gConns) gConns = [NSMutableDictionary dictionary];
                gConns[@(*connect)] = [NSString stringWithFormat:@"%@/%@", serviceName, className];
                TLog(@"IOServiceOpen %@ (%@) -> conn %u", serviceName, className, (unsigned)*connect);
            }
        }
    } @catch (__unused NSException *e) { }
    return ret;
}

static NSString *ConnName(io_connect_t connection) {
    if (!gConns) return nil;
    return gConns[@(connection)];
}

%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
    NSString *name = ConnName(connection);
    if (name) {
        NSMutableString *scalars = [NSMutableString string];
        if (input && inputCnt) for (uint32_t i = 0; i < inputCnt && i < 8; i++) [scalars appendFormat:@"%llu ", (unsigned long long)input[i]];
        uint32_t head = 0;
        if (inputStruct && inputStructCnt >= sizeof(uint32_t)) memcpy(&head, inputStruct, sizeof(uint32_t));
        TLog(@"IOConnectCallMethod %@ sel=%u in[%u]={%@} struct=%zu head=%u", name, selector, inputCnt, scalars, inputStructCnt, head);
    }
    return %orig;
}

%hookf(kern_return_t, IOConnectCallScalarMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, uint64_t *output, uint32_t *outputCnt) {
    NSString *name = ConnName(connection);
    if (name) {
        NSMutableString *scalars = [NSMutableString string];
        if (input && inputCnt) for (uint32_t i = 0; i < inputCnt && i < 8; i++) [scalars appendFormat:@"%llu ", (unsigned long long)input[i]];
        TLog(@"IOConnectCallScalarMethod %@ sel=%u in[%u]={%@}", name, selector, inputCnt, scalars);
    }
    return %orig;
}

%hookf(kern_return_t, IOConnectCallStructMethod, mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
    NSString *name = ConnName(connection);
    if (name) {
        uint32_t head = 0;
        if (inputStruct && inputStructCnt >= sizeof(uint32_t)) memcpy(&head, inputStruct, sizeof(uint32_t));
        TLog(@"IOConnectCallStructMethod %@ sel=%u struct=%zu head=%u", name, selector, inputStructCnt, head);
    }
    return %orig;
}

// ---------------------------------------------------------------------------
// ApplePPMCPU：阻断降频等级请求（内核 DVFS 保持自主）
// ---------------------------------------------------------------------------
%hook ApplePPMCPU

- (void)setCPULevel:(int)level {
    if (GuardEnabled()) {
        TLog(@"ApplePPMCPU setCPULevel(%d) -> blocked", level);
        return;
    }
    %orig(level);
}

- (void)updateCPU {
    if (GuardEnabled()) return;
    %orig;
}

%end

%hook ApplePPM

- (void)setCPULevel:(int)level {
    if (GuardEnabled()) {
        TLog(@"ApplePPM setCPULevel(%d) -> blocked", level);
        return;
    }
    %orig(level);
}

%end

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
%ctor {
    @autoreleasepool {
        NSString *name = [[NSProcessInfo processInfo] processName];
        if (name.length == 0) name = @"?";
        gTag = name;
        TLog(@"power guard loaded (pid %d, enabled=%d)", (int)getpid(), GuardEnabled());
        // 只对 powerd 做属性丢弃，避免与主模块在 thermalmonitord 内重复拦截；
        // 采样与 IOConnect 记录在两边都跑，便于对照。
        BOOL isPowerd = [name isEqualToString:@"powerd"];
        gDropEnabled = isPowerd;
        // powerd 通过 IOServiceSetProperty 写功率/频率上限，必须一并接管
        MSHookFunction((void *)IOServiceSetProperty, (void *)PowerGuardServiceSetProperty,
                       (void **)&orig_PowerGuardServiceSetProperty);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SampleFrame(isPowerd ? "powerd-load" : "load");
            FrameTimer();
        });
    }
}
