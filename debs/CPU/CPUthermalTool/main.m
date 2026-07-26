#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>
#include <getopt.h>

// IOServiceSetProperty 在 iOS SDK 的 IOKit 头文件中可能不可见，
// 但函数存在于 IOKit.framework 中，运行时通过 dlsym 解析
typedef kern_return_t (*IOServiceSetPropertyFunc)(io_service_t, CFStringRef, CFTypeRef);
static IOServiceSetPropertyFunc g_IOServiceSetProperty = NULL;

// ============================================================================
// CPUthermalTool — 独立 IOKit CPU 频率上限工具 + 看门狗守护进程
//
// 用法:
//   CPUthermalTool --low-power <MHz>    设置低功耗频率上限（一次性）
//   CPUthermalTool --restore [MHz]      恢复频率上限（默认 3780）
//   CPUthermalTool --daemon <MHz>       持续守护模式（每 200ms 一直压频）
//   CPUthermalTool --watch-plist <路径> [原生MHz]
//                                       看门狗模式：自动监听从偏好面板切换，
//                                       lowPower→压频1380，off→恢复
//
// 关键设计：
//   看门狗模式（--watch-plist）作为独立进程运行，不受 thermalmonitord
//   沙箱限制，直接向 AppleCLPCv2/AppleCLPC 等 IOKit 服务写入硬性频率上限。
//   P-core 频率每 200ms 重新施加一次，对抗系统温控循环恢复。
// ============================================================================

static volatile BOOL g_running = YES;

// 信号处理
static void handleSignal(int sig) {
    g_running = NO;
}

static void printUsage(const char *name) {
    fprintf(stderr, "用法: %s [选项]\n", name);
    fprintf(stderr, "  --low-power <MHz>   设置低功耗频率上限（一次性）\n");
    fprintf(stderr, "  --restore [MHz]     恢复频率上限（默认 3780）\n");
    fprintf(stderr, "  --daemon <MHz>      持续守护模式（每 200ms 一直压频）\n");
    fprintf(stderr, "  --watch-plist <路径> [原生MHz]\n");
    fprintf(stderr, "                      看门狗模式：自动监听 plist 切换压频/恢复\n");
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

/// 看门狗模式：自动监听偏好 plist，切换压频/恢复
/// plistPath: 偏好 plist 路径
/// nativeMHz: 设备原生最大频率（用于恢复）
/// 逻辑:
///   thermalPowerMode == "lowPower" -> 每 200ms 施加 1380MHz 上限
///   thermalPowerMode == "off"      -> 恢复原生频率，每 500ms 检查 plist
static void watchPlistMode(const char *plistPath, int nativeMHz) {
    if (!plistPath || plistPath[0] == '\0') {
        fprintf(stderr, "[CPUthermalTool] 看门狗模式需要 plist 路径参数\n");
        return;
    }

    signal(SIGTERM, handleSignal);
    signal(SIGINT, handleSignal);

    if (nativeMHz <= 0) nativeMHz = 3780;
    NSString *path = [NSString stringWithUTF8String:plistPath];
    BOOL wasLowPower = NO;

    NSLog(@"[CPUthermalTool] 看门狗启动: plist=%s native=%dMHz", plistPath, nativeMHz);

    while (g_running) {
        @autoreleasepool {
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
            NSString *mode = prefs[@"thermalPowerMode"] ?: @"off";
            BOOL isLowPower = [mode isEqualToString:@"lowPower"];

            if (isLowPower) {
                if (!wasLowPower) {
                    NSLog(@"[CPUthermalTool] 模式变更为低功耗, 开始压频 1380MHz");
                    wasLowPower = YES;
                }
                // 低功耗：每 200ms 重新压频，对抗系统温控恢复
                setLowPowerCap(1380, 800);
                usleep(200000);
            } else {
                if (wasLowPower) {
                    NSLog(@"[CPUthermalTool] 模式变更为 %s, 恢复频率 %dMHz",
                          [mode UTF8String], nativeMHz);
                    wasLowPower = NO;
                    restoreFrequency(nativeMHz);
                }
                // 非低功耗：每 500ms 检查 plist（省电）
                usleep(500000);
            }
        }
    }

    // 退出时恢复频率
    restoreFrequency(nativeMHz);
    NSLog(@"[CPUthermalTool] 看门狗退出");
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
        BOOL watchPlistModeEnabled = NO;
        const char *plistPath = NULL;

        struct option longOpts[] = {
            {"low-power", required_argument, NULL, 'l'},
            {"restore",   optional_argument, NULL, 'r'},
            {"daemon",    required_argument, NULL, 'd'},
            {"watch-plist", required_argument, NULL, 'w'},
            {"help",      no_argument,       NULL, 'h'},
            {0, 0, 0, 0}
        };

        int opt;
        while ((opt = getopt_long(argc, argv, "l:r::d:w:h", longOpts, NULL)) != -1) {
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
                case 'w':
                    watchPlistModeEnabled = YES;
                    plistPath = optarg;
                    // 可选第二个参数为原生 MHz
                    if (optind < argc && argv[optind][0] != '-') {
                        nativeMHz = atoi(argv[optind]);
                        optind++;
                    }
                    break;
                case 'h':
                default:
                    printUsage(argv[0]);
                    return 0;
            }
        }

        if (watchPlistModeEnabled) {
            watchPlistMode(plistPath, nativeMHz);
        } else if (daemonModeEnabled) {
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
