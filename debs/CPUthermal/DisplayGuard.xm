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
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <unistd.h>
#include <notify.h>
#import <CPUthermalPaths.h>
#include <pthread.h>
#include <stdarg.h>

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
static const int kDisplayLogMaxLines = 4000;
static int gDisplayLogLines = 0;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *gProcTag = @"?";

static void DLogToFile(NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = @[@"/usr/local/share/CPUthermal", @"/var/jb/usr/local/share/CPUthermal",
                      @"/var/mobile/Library/CPUthermal", @"/var/tmp", @"/tmp"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *dir in dirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSString *path = [dir stringByAppendingPathComponent:@"cputhermal-display.log"];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) continue;
        @try { [handle seekToEndOfFile]; [handle writeData:data]; [handle closeFile]; }
        @catch (__unused NSException *e) { }
        return;
    }
}

static void DLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    pthread_mutex_lock(&gLogLock);
    if (gDisplayLogLines < kDisplayLogMaxLines) {
        gDisplayLogLines++;
        DLogToFile([NSString stringWithFormat:@"[%.3f][%@] %@\n", CFAbsoluteTimeGetCurrent(), gProcTag, message]);
    }
    pthread_mutex_unlock(&gLogLock);
}

// ---------------------------------------------------------------------------
// 上限学习与持久化（16.16 定点）
// ---------------------------------------------------------------------------
static int64_t gCapTargetRaw = 0;
static double  gRequestedNits = 0;   // 最近一次 DisplayBrightness 请求 nits
static pthread_mutex_t gCapLock = PTHREAD_MUTEX_INITIALIZER;

static inline int64_t NitsToRaw(double nits) { return (int64_t)llround(nits * 65536.0); }
static inline double RawToNits(int64_t raw) { return (double)raw / 65536.0; }

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
        [[NSString stringWithFormat:@"%lld", (long long)gCapTargetRaw]
            writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) { }
}

static void CapLoadPersisted(void) {
    if (gCapTargetRaw > 0) return;
    NSString *path = CapStorePath();
    if (!path) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    long long value = text ? [text longLongValue] : 0;
    if (value > 0 && value < 20000LL * 65536LL) {
        gCapTargetRaw = (int64_t)value;
        DLog(@"panel cap restored from disk: %.2f nits", RawToNits(gCapTargetRaw));
    }
}

// 只升不降：避免在已经处于热压状态时把低值学成上限
static void CapLearnRaw(int64_t rawCap) {
    if (rawCap <= 0 || rawCap > 20000LL * 65536LL) return;
    pthread_mutex_lock(&gCapLock);
    BOOL raised = (rawCap > gCapTargetRaw);
    if (raised) gCapTargetRaw = rawCap;
    pthread_mutex_unlock(&gCapLock);
    if (raised) { CapPersist(); DLog(@"panel cap learned: %.2f nits", RawToNits(rawCap)); }
}

static void CapLearnFromNits(double nits) {
    if (!(nits > 0.0) || nits > 20000.0) return;
    CapLearnRaw(NitsToRaw(nits));
}

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
static BOOL BrightnessProtectionEnabled(void) {
    @try {
        NSDictionary *prefs = CPUthermalReadPrefs();
        return [prefs[S("enabled")] boolValue] && [prefs[S("thermalPreventDimmingEnabled")] boolValue];
    } @catch (__unused NSException *e) { return NO; }
}

static void EnforcePanelBrightness(NSString *reason) {
    @try {
        if (!BrightnessProtectionEnabled()) return;
        io_registry_entry_t capNode = CapNode();
        if (capNode == IO_OBJECT_NULL) return;

        int64_t rawCap = NodeReadRaw(capNode, "BLNitsCap");
        if (rawCap > 0) CapLearnRaw(rawCap);

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
        if (!(requested > 0.0)) return;

        double desired = RawToNits(target);
        if (requested < desired) desired = requested;

        int64_t rawApplied = NodeReadRaw(nitsNode, "brightness-nits");
        if (rawApplied > 0 && RawToNits(rawApplied) < desired - 1.0) {
            if (NodeWriteRaw(nitsNode, "brightness-nits", NitsToRaw(desired)))
                DLog(@"brightness-nits raised %.2f -> %.2f nits (%@)", RawToNits(rawApplied), desired, reason);
        }
    } @catch (__unused NSException *e) { }
}

// ---------------------------------------------------------------------------
// 自检定时器
// ---------------------------------------------------------------------------
static void BrightnessGuardTick(void) {
    EnforcePanelBrightness(@"tick");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ BrightnessGuardTick(); });
}

// ---------------------------------------------------------------------------
// Hook：截获 BLNitsCap 写入（谁写都拦下来改高）
// ---------------------------------------------------------------------------
%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    @try {
        static CFStringRef capKey = NULL;
        if (capKey == NULL) capKey = CFStringCreateWithCString(kCFAllocatorDefault, "BLNitsCap", kCFStringEncodingUTF8);
        static CFStringRef nitsKey = NULL;
        if (nitsKey == NULL) nitsKey = CFStringCreateWithCString(kCFAllocatorDefault, "brightness-nits", kCFStringEncodingUTF8);
        static CFStringRef displayKey = NULL;
        if (displayKey == NULL) displayKey = CFStringCreateWithCString(kCFAllocatorDefault, "DisplayBrightness", kCFStringEncodingUTF8);

        BOOL protectionOn = BrightnessProtectionEnabled();
        if (protectionOn && capKey && CFEqual(key, capKey) && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            int64_t raw = 0;
            [(__bridge NSNumber *)value getValue:&raw];
            CapLearnRaw(raw);
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
        } else if (displayKey && CFEqual(key, displayKey) && value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
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
