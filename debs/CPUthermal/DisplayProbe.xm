// ============================================================================
// CPUthermalDisplay — 屏幕亮度链路探针（注入 backboardd / SpringBoard）
//
// 目的：定位“屏幕亮度被压低（如 337 nits）”的真实写入通道。
// 本版本只记录、不改写，便于按 selector / 键名做出精确定向屏蔽。
// 日志：/usr/local/share/CPUthermal/cputhermal-display.log
//       （rootless 为 /var/jb/usr/local/share/CPUthermal/，另有
//        /var/mobile/Library/CPUthermal、/var/tmp、/tmp 兜底）
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <pthread.h>
#include <stdarg.h>

static pthread_mutex_t gDisplayLogLock = PTHREAD_MUTEX_INITIALIZER;
static int gDisplayLogLines = 0;
static CFAbsoluteTime gDisplayLogWindow = 0;
static int gDisplayLogWindowCount = 0;
static const int kDisplayLogMaxLines = 6000;

static void DLog(NSString *format, ...) {
    if (gDisplayLogLines >= kDisplayLogMaxLines) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message.length == 0) return;
    pthread_mutex_lock(&gDisplayLogLock);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gDisplayLogWindow > 1.0) { gDisplayLogWindow = now; gDisplayLogWindowCount = 0; }
    if (gDisplayLogWindowCount >= 60) { pthread_mutex_unlock(&gDisplayLogLock); return; }
    gDisplayLogWindowCount++;
    gDisplayLogLines++;
    NSString *line = [NSString stringWithFormat:@"[%.3f] %@\n", now, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = @[@"/usr/local/share/CPUthermal", @"/var/jb/usr/local/share/CPUthermal",
                      @"/var/mobile/Library/CPUthermal", @"/var/tmp", @"/tmp"];
    for (NSString *dir in dirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSString *path = [dir stringByAppendingPathComponent:@"cputhermal-display.log"];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) continue;
        @try { [handle seekToEndOfFile]; [handle writeData:data]; [handle closeFile]; }
        @catch (__unused NSException *e) { }
        break;
    }
    pthread_mutex_unlock(&gDisplayLogLock);
}

static BOOL IsBrightnessKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    for (NSString *token in @[@"bright", @"nits", @"dim", @"limit", @"backlight", @"luminance", @"mitigat"]) {
        if ([key rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL IsDisplayToken(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    for (NSString *token in @[@"dcp", @"iomfb", @"framebuffer", @"backlight", @"display", @"brightness"]) {
        if ([text rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *EntryName(io_registry_entry_t entry) {
    io_name_t name = {0};
    if (entry && IORegistryEntryGetName(entry, name) == KERN_SUCCESS)
        return [NSString stringWithUTF8String:name] ?: @"?";
    return @"?";
}

static NSString *EntryClass(io_registry_entry_t entry) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("IOObjectClass"), kCFAllocatorDefault, 0);
    if (value) {
        NSString *text = [NSString stringWithFormat:@"%@", value];
        CFRelease(value);
        return text;
    }
    return @"?";
}

// 已识别的显示相关连接：conn -> 服务名
static NSMutableDictionary *gDisplayConnections = nil;

static BOOL IsDisplayConnection(io_connect_t connection) {
    if (!gDisplayConnections) return NO;
    return gDisplayConnections[@(connection)] != nil;
}

%hookf(kern_return_t, IOServiceOpen, io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connection) {
    kern_return_t kr = %orig;
    if (kr == KERN_SUCCESS && connection && *connection) {
        NSString *name = EntryName(service);
        NSString *cls = EntryClass(service);
        if (IsDisplayToken(name) || IsDisplayToken(cls)) {
            if (!gDisplayConnections) gDisplayConnections = [NSMutableDictionary dictionary];
            gDisplayConnections[@(*connection)] = [NSString stringWithFormat:@"%@/%@", name, cls];
            DLog(@"IOServiceOpen %@ (%@) -> conn %u", name, cls, (unsigned)*connection);
        }
    }
    return kr;
}

%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
    BOOL display = IsDisplayConnection(connection);
    if (display) {
        NSMutableString *scalars = [NSMutableString string];
        if (input && inputCnt) for (uint32_t i = 0; i < inputCnt && i < 6; i++) [scalars appendFormat:@"%llu ", (unsigned long long)input[i]];
        uint32_t structHead = 0;
        if (inputStruct && inputStructCnt >= sizeof(uint32_t)) memcpy(&structHead, inputStruct, sizeof(uint32_t));
        DLog(@"IOConnectCallMethod conn=%u svc=%@ sel=%u in[%u]={%@} struct=%zu head=%u",
             (unsigned)connection, gDisplayConnections[@(connection)] ?: @"?", selector, inputCnt, scalars, inputStructCnt, structHead);
    }
    kern_return_t kr = %orig;
    if (display && output && outputCnt && *outputCnt) {
        NSMutableString *outs = [NSMutableString string];
        for (uint32_t i = 0; i < *outputCnt && i < 6; i++) [outs appendFormat:@"%llu ", (unsigned long long)output[i]];
        DLog(@"  -> kr=%d out={%@}", kr, outs);
    }
    return kr;
}

%hookf(kern_return_t, IOConnectCallScalarMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, uint64_t *output, uint32_t *outputCnt) {
    BOOL display = IsDisplayConnection(connection);
    if (display) {
        NSMutableString *scalars = [NSMutableString string];
        if (input && inputCnt) for (uint32_t i = 0; i < inputCnt && i < 6; i++) [scalars appendFormat:@"%llu ", (unsigned long long)input[i]];
        DLog(@"IOConnectCallScalarMethod conn=%u svc=%@ sel=%u in[%u]={%@}",
             (unsigned)connection, gDisplayConnections[@(connection)] ?: @"?", selector, inputCnt, scalars);
    }
    return %orig;
}

%hookf(kern_return_t, IOConnectCallStructMethod, mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt) {
    if (IsDisplayConnection(connection)) {
        uint32_t head = 0;
        if (inputStruct && inputStructCnt >= sizeof(uint32_t)) memcpy(&head, inputStruct, sizeof(uint32_t));
        DLog(@"IOConnectCallStructMethod conn=%u svc=%@ sel=%u struct=%zu head=%u",
             (unsigned)connection, gDisplayConnections[@(connection)] ?: @"?", selector, inputStructCnt, head);
    }
    return %orig;
}

%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {
    NSString *keyText = (__bridge NSString *)key;
    if (IsBrightnessKey(keyText)) {
        DLog(@"SetCFProperty [%@ / %@] %@ = %@", EntryName(entry), EntryClass(entry), keyText,
             value ? [NSString stringWithFormat:@"%@", (__bridge id)value] : @"(null)");
    }
    return %orig;
}

// CoreBrightness 客户端 —— 亮度真正被“算”出来的地方
%hook BrightnessSystemClient

- (void)setProperty:(id)value forKey:(id)key {
DLog(@"[CB] setProperty %@ = %@", key, value);
%orig;
}

- (id)copyPropertyForKey:(id)key {
id value = %orig;
if (IsBrightnessKey((NSString *)key)) DLog(@"[CB] copy %@ = %@", key, value);
return value;
}

%end

// 周期性快照：CoreBrightness 亮度字典 + IORegistry 里的亮度相关键
static void DumpCoreBrightness(void) {
    const char *paths[]={"/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                         "/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness",NULL};
    for (int i=0;paths[i];i++) if (dlopen(paths[i], RTLD_NOW|RTLD_LOCAL)) break;
    Class cls = objc_getClass("BrightnessSystemClient");
    if (!cls) { DLog(@"[CB] BrightnessSystemClient 不存在"); return; }
    id client = nil;
    @try { client = [[cls alloc] init]; } @catch (__unused NSException *e) { return; }
    if (!client) return;
    SEL copySel = NSSelectorFromString(@"copyPropertyForKey:");
    if (![client respondsToSelector:copySel]) { DLog(@"[CB] 无 copyPropertyForKey:"); return; }
    for (NSString *key in @[@"DisplayBrightness", @"DisplayBrightnessLimit", @"BrightnessLimit", @"Brightness"]) {
        id value = nil;
        @try { value = ((id(*)(id,SEL,id))objc_msgSend)(client, copySel, key); }
        @catch (__unused NSException *e) { value = nil; }
        if (value) DLog(@"[CB-SNAP] %@ = %@", key, value);
    }
}

static void DumpIORegistryBrightness(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryCreateIterator(kIOMasterPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS || iterator == IO_OBJECT_NULL) return;
    const char *keys[] = {"IOMFB_brightness","IOMFB_brightness_limit","IOMFB_max_brightness","IOMFB_brightness_max",
        "brightness","brightness-limit","brightness_limit","brightness-cap","max-brightness","maxbrightness",
        "BacklightBrightness","BacklightPower","backlight","DisplayBrightness","dimming","IOMFB_dimming",NULL};
    io_registry_entry_t entry;
    int hits = 0;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL && hits < 60) {
        NSString *cls = EntryClass(entry);
        for (int i = 0; keys[i]; i++) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, keys[i], kCFStringEncodingUTF8);
            if (!key) continue;
            CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
            if (value) {
                DLog(@"[IOREG %@ / %@] %s = %@", EntryName(entry), cls, keys[i], [NSString stringWithFormat:@"%@", (__bridge id)value]);
                hits++;
                CFRelease(value);
            }
            CFRelease(key);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
}

static void ScheduleDisplaySnapshot(void);

static void DisplaySnapshotTick(void) {
    DLog(@"[SNAP] ---- begin ----");
    DumpCoreBrightness();
    DumpIORegistryBrightness();
    DLog(@"[SNAP] ---- end ----");
    ScheduleDisplaySnapshot();
}

static void ScheduleDisplaySnapshot(void) {
    static int rounds = 0;
    if (rounds++ >= 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ DisplaySnapshotTick(); });
}

%ctor {
    @autoreleasepool {
        NSString *process = [[NSProcessInfo processInfo] processName] ?: @"?";
        DLog(@"==== CPUthermalDisplay probe loaded in %@ ====", process);
        ScheduleDisplaySnapshot();
    }
}
