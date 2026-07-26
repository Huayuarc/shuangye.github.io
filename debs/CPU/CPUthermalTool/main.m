#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>
#include <getopt.h>

// IOServiceSetProperty 在 iOS SDK 的 IOKit 头文件中可能不可见，
// 但函数存在于 IOKit.framework 中，运行时通过 dlsym 解析
typedef kern_return_t (*IOServiceSetPropertyFunc)(io_service_t, CFStringRef, CFTypeRef);
static IOServiceSetPropertyFunc g_IOServiceSetProperty = NULL;

// ============================================================================
// CPUthermalTool — 独立 IOKit CPU 频率上限工具
//
// 用法:
//   CPUthermalTool --low-power 1380   设置低功耗频率上限
//   CPUthermalTool --restore [native]  恢复频率上限（不清除则设回默认）
//   CPUthermalTool --daemon 1380       持续守护模式（每 200ms 重新应用）
//
// 以 root 身份运行（通过 posix_spawn_with_persona），绕过 thermalmonitord
// 的沙箱限制，直接向 AppleCLPCv2 等 IOKit 服务写入硬性频率上限。
// ============================================================================

static volatile BOOL g_running = YES;

// 信号处理
static void handleSignal(int sig) {
    g_running = NO;
}

static void printUsage(const char *name) {
    fprintf(stderr, "用法: %s [选项]\n", name);
    fprintf(stderr, "  --low-power <MHz>   设置低功耗频率上限\n");
    fprintf(stderr, "  --restore [MHz]     恢复频率上限（默认 3780）\n");
    fprintf(stderr, "  --daemon <MHz>      持续守护模式\n");
    fprintf(stderr, "  --help              显示此帮助\n");
}

/// 向所有已知 CPU 电源管理服务设置频率上限
static BOOL applyCapToAllServices(int64_t maxHz, int64_t minHz) {
    BOOL anySuccess = NO;

    CFNumberRef maxFreq = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &maxHz);
    CFNumberRef minFreq = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &minHz);
    if (!maxFreq || !minFreq) {
        if (maxFreq) CFRelease(maxFreq);
        if (minFreq) CFRelease(minFreq);
        return NO;
    }

    // 尝试所有已知 CPU 电源管理服务
    const char *serviceNames[] = {"AppleCLPCv2", "AppleCLPC", "AppleARMIODevice", NULL};
    for (int i = 0; serviceNames[i]; i++) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                            IOServiceMatching(serviceNames[i]));
        if (service == IO_OBJECT_NULL) continue;

        g_IOServiceSetProperty(service, CFSTR("clpc-cpu-max-frequency"), maxFreq);
        g_IOServiceSetProperty(service, CFSTR("clpc-cpu-min-frequency"), minFreq);
        g_IOServiceSetProperty(service, CFSTR("max-cpu-frequency"), maxFreq);

        // 另外尝试设置 perf 相关属性
        g_IOServiceSetProperty(service, CFSTR("cpu-frequency-cap"), maxFreq);
        g_IOServiceSetProperty(service, CFSTR("cpu-max-frequency"), maxFreq);

        IOObjectRelease(service);
        anySuccess = YES;
    }

    // 备用：直接写入 pmgr（Power Manager）
    io_service_t pmgr = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                    IOServiceNameMatching("pmgr"));
    if (pmgr != IO_OBJECT_NULL) {
        g_IOServiceSetProperty(pmgr, CFSTR("clpc-cpu-max-frequency"), maxFreq);
        g_IOServiceSetProperty(pmgr, CFSTR("max-cpu-frequency"), maxFreq);
        g_IOServiceSetProperty(pmgr, CFSTR("cpu-frequency-cap"), maxFreq);
        IOObjectRelease(pmgr);
        anySuccess = YES;
    }

    CFRelease(maxFreq);
    if (minFreq) CFRelease(minFreq);

    return anySuccess;
}

/// 恢复频率上限（设为默认高值）
static void restoreFrequency(int nativeMHz) {
    if (nativeMHz <= 0) nativeMHz = 3780;
    int64_t maxHz = (int64_t)nativeMHz * 1000000LL;
    int64_t minHz = 0;  // 不限制下限
    applyCapToAllServices(maxHz, minHz);
    NSLog(@"[CPUthermalTool] 已恢复频率上限: %d MHz", nativeMHz);
}

/// 设置低功耗频率上限
static void setLowPowerCap(int targetMHz, int minMHz) {
    if (targetMHz <= 0) targetMHz = 1380;
    if (minMHz <= 0) minMHz = 800;
    int64_t maxHz = (int64_t)targetMHz * 1000000LL;
    int64_t minHz = (int64_t)minMHz * 1000000LL;

    BOOL ok = applyCapToAllServices(maxHz, minHz);
    if (ok) {
        NSLog(@"[CPUthermalTool] 低功耗频率上限已设置: max=%d MHz, min=%d MHz (成功)", targetMHz, minMHz);
    } else {
        NSLog(@"[CPUthermalTool] 低功耗频率上限设置失败（无法访问任何 IOKit 服务）");
    }
}

/// 守护模式：持续重新应用频率上限
static void daemonMode(int targetMHz) {
    signal(SIGTERM, handleSignal);
    signal(SIGINT, handleSignal);

    NSLog(@"[CPUthermalTool] 守护模式启动: 目标=%d MHz, 间隔=200ms", targetMHz);

    while (g_running) {
        @autoreleasepool {
            setLowPowerCap(targetMHz, 800);
            usleep(200000);  // 200ms
        }
    }

    NSLog(@"[CPUthermalTool] 守护模式退出");
}

static BOOL initIOServiceSetProperty(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) return NO;
    g_IOServiceSetProperty = (IOServiceSetPropertyFunc)dlsym(handle, "IOServiceSetProperty");
    return (g_IOServiceSetProperty != NULL);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (!initIOServiceSetProperty()) {
            fprintf(stderr, "[CPUthermalTool] 无法加载 IOServiceSetProperty\n");
            return 1;
        }

        int targetMHz = 1380;
        int nativeMHz = 3780;
        BOOL lowPowerMode = NO;
        BOOL restoreMode = NO;
        BOOL daemonModeEnabled = NO;

        struct option longOpts[] = {
            {"low-power", required_argument, NULL, 'l'},
            {"restore",   optional_argument, NULL, 'r'},
            {"daemon",    required_argument, NULL, 'd'},
            {"help",      no_argument,       NULL, 'h'},
            {0, 0, 0, 0}
        };

        int opt;
        while ((opt = getopt_long(argc, argv, "l:r::d:h", longOpts, NULL)) != -1) {
            switch (opt) {
                case 'l':
                    lowPowerMode = YES;
                    targetMHz = atoi(optarg);
                    break;
                case 'r':
                    restoreMode = YES;
                    if (optarg) nativeMHz = atoi(optarg);
                    break;
                case 'd':
                    daemonModeEnabled = YES;
                    targetMHz = atoi(optarg);
                    break;
                case 'h':
                default:
                    printUsage(argv[0]);
                    return 0;
            }
        }

        if (daemonModeEnabled) {
            daemonMode(targetMHz);
        } else if (lowPowerMode) {
            setLowPowerCap(targetMHz, 800);
        } else if (restoreMode) {
            restoreFrequency(nativeMHz);
        } else {
            printUsage(argv[0]);
            return 1;
        }

        return 0;
    }
}
