// 亮度限制链路采样器：把“用户请求 / 实际面板亮度 / 上限 / 面板温度”放在同一条时间轴上。
// 用于判定户外被压暗到底发生在哪一环：
//   Nits 高、NitsPhysical 低  -> 主机侧把面板亮度级压低了（可用 IOMFBBrightnessLevel 抬回）
//   Nits 本身低               -> 请求阶段就被上限（BLNitsCap/Dimming）削掉
//   两者都高但肉眼变暗        -> 面板温补在 DCP 内部动作，主机侧看不到
// 只读，不写任何属性。
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>

#define kIOMasterPortDefault MACH_PORT_NULL

static Class gClientClass = Nil;
static id gClient = nil;

static double registryNumber(io_registry_entry_t entry, const char *key) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!k) return -1.0;
    double result = -1.0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, k, kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double raw = [(__bridge NSNumber *)value doubleValue];
            result = (fabs(raw) > 65536.0) ? raw / 65536.0 : raw;
        }
        CFRelease(value);
    }
    CFRelease(k);
    return result;
}

static BOOL ensureClient(void) {
    if (gClient) return YES;
    if (!gClientClass) {
        if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) &&
            !dlopen("/System/Library/PrivateFrameworks/corebrightness.framework/corebrightness", RTLD_NOW)) return NO;
        gClientClass = objc_getClass("BrightnessSystemClient");
        if (!gClientClass) return NO;
    }
    @try { gClient = [[gClientClass alloc] init]; } @catch (__unused NSException *e) { gClient = nil; }
    return gClient != nil;
}

static id copyProperty(NSString *key) {
    if (!ensureClient()) return nil;
    id value = nil;
    @try { value = ((id(*)(id,SEL,id))objc_msgSend)(gClient, sel_registerName("copyPropertyForKey:"), key); }
    @catch (__unused NSException *e) { value = nil; }
    return value;
}

static double numberFrom(id value) {
    if ([value respondsToSelector:@selector(doubleValue)]) return [value doubleValue];
    return -1.0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int seconds = argc > 1 ? atoi(argv[1]) : 60;
        int intervalMs = argc > 2 ? atoi(argv[2]) : 1000;
        if (seconds <= 0) seconds = 60;
        if (intervalMs < 100) intervalMs = 100;
        printf("# t  reqNits  physNits  levelNits  BLNitsCap  ambient  dcpTempC  brightness  tempComp\n");
        fflush(stdout);
        for (int i = 0; i < seconds; i++) {
            double req = -1, phys = -1, brightness = -1;
            id display = copyProperty(@"DisplayBrightness");
            if ([display isKindOfClass:[NSDictionary class]]) {
                req = numberFrom(display[@"Nits"]);
                phys = numberFrom(display[@"NitsPhysical"]);
                brightness = numberFrom(display[@"Brightness"]);
            }
            double level = -1, cap = -1, ambient = -1, temp = -1, tempComp = -1;
            io_registry_entry_t fb = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleCLCD2"));
            if (fb) {
                level = registryNumber(fb, "IOMFBBrightnessLevel");
                cap = registryNumber(fb, "BLNitsCap");
                ambient = registryNumber(fb, "AmbientBrightness");
                temp = registryNumber(fb, "APTPDCTemperature");
                tempComp = registryNumber(fb, "IOMFBTemperatureCompensationEnable");
                IOObjectRelease(fb);
            }
            printf("%4d  %8.2f  %8.2f  %9.2f  %9.2f  %7.0f  %8.2f  %10.4f  %8.0f\n",
                   i, req, phys, level, cap, ambient, temp, brightness, tempComp);
            fflush(stdout);
            usleep((useconds_t)intervalMs * 1000);
        }
    }
    return 0;
}
