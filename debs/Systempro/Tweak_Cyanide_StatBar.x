// Tweak_Cyanide_StatBar.x
// Ported from Cyanide statbar - System status overlay (battery temp, CPU, RAM)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import <sys/sysctl.h>
#import <IOKit/IOKitLib.h>

static BOOL g_cld_statbarEnabled = NO;
static BOOL g_cld_statbarCelsius = YES;
static BOOL g_cld_statbarShowNet = NO;
static BOOL g_cld_statbarShowCPU = NO;
static BOOL g_cld_statbarShowLabels = NO;
static UIWindow *g_cld_statbarWindow = nil;
static UILabel *g_cld_statbarLabel = nil;
static NSTimer *g_cld_statbarTimer = nil;

// IOKit battery temperature reading
static float cld_statbar_get_battery_temp(void) {
    float temp = 0;
    io_connect_t connect = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                       IOServiceMatching("AppleSmartBattery"));
    if (!service) return 0;
    
    IOReturn ret = IOServiceOpen(service, mach_task_self(), 0, &connect);
    IOObjectRelease(service);
    if (ret != kIOReturnSuccess) return 0;
    
    size_t count = 1;
    uint64_t temperature = 0;
    uint32_t outputCount = 1;
    
    ret = IOConnectCallMethod(connect, 0, NULL, 0, NULL, 0,
                              &temperature, &outputCount, NULL, &count);
    IOServiceClose(connect);
    
    if (ret == kIOReturnSuccess) {
        temp = (float)((double)temperature / 100.0);
    }
    return temp;
}

// Free RAM
static double cld_statbar_get_free_ram_gb(void) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vmstat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vmstat, &count) == KERN_SUCCESS) {
        uint64_t free_bytes = vmstat.free_count * vm_page_size;
        return (double)free_bytes / (1024.0 * 1024.0 * 1024.0);
    }
    return 0;
}

// CPU usage
static float cld_statbar_get_cpu_usage(void) {
    static uint64_t prev_total = 0;
    static uint64_t prev_idle = 0;
    static int sampleCount = 0;
    
    host_cpu_load_info_data_t cpuInfo;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                        (host_info_t)&cpuInfo, &count) != KERN_SUCCESS) {
        return -1;
    }
    
    uint64_t total = cpuInfo.cpu_ticks[CPU_STATE_USER] +
                     cpuInfo.cpu_ticks[CPU_STATE_SYSTEM] +
                     cpuInfo.cpu_ticks[CPU_STATE_IDLE] +
                     cpuInfo.cpu_ticks[CPU_STATE_NICE];
    uint64_t idle = cpuInfo.cpu_ticks[CPU_STATE_IDLE];
    
    if (sampleCount == 0) {
        prev_total = total;
        prev_idle = idle;
        sampleCount = 1;
        return -1;
    }
    
    uint64_t totalDelta = total - prev_total;
    uint64_t idleDelta = idle - prev_idle;
    
    prev_total = total;
    prev_idle = idle;
    
    if (totalDelta == 0) return 0;
    return (float)((double)(totalDelta - idleDelta) / (double)totalDelta * 100.0);
}

// Network speed
typedef struct {
    uint64_t downBytes;
    uint64_t upBytes;
} CLDNetSample;

static CLDNetSample cld_statbar_sample_net(void) {
    CLDNetSample sample = {0, 0};
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return sample;
    
    for (struct ifaddrs *addr = addrs; addr; addr = addr->ifa_next) {
        if (!addr->ifa_addr || addr->ifa_addr->sa_family != AF_LINK) continue;
        NSString *name = @(addr->ifa_name);
        if ([name isEqualToString:@"lo0"]) continue;
        
        struct if_data *stats = (struct if_data *)addr->ifa_data;
        if (stats) {
            sample.downBytes += stats->ifi_ibytes;
            sample.upBytes += stats->ifi_obytes;
        }
    }
    freeifaddrs(addrs);
    return sample;
}

static NSString *cld_statbar_format_speed(double kbps) {
    if (kbps >= 1024.0) {
        return [NSString stringWithFormat:@"%.1fM", kbps / 1024.0];
    } else if (kbps >= 1.0) {
        return [NSString stringWithFormat:@"%.0fK", kbps];
    }
    return @"0K";
}

@interface _CLDStatBarHelper : NSObject
+ (void)cld_statbar_timerTick:(NSTimer *)timer;
@end
@implementation _CLDStatBarHelper
+ (void)cld_statbar_timerTick:(NSTimer *)timer {
    if (!g_cld_statbarEnabled || !g_cld_statbarLabel) return;
    
    NSMutableString *text = [NSMutableString string];
    
    // Battery temperature
    float temp = cld_statbar_get_battery_temp();
    if (temp > 0) {
        if (g_cld_statbarShowLabels) [text appendString:@"Temp:"];
        if (g_cld_statbarCelsius) {
            [text appendFormat:@"%.1f°C ", temp];
        } else {
            [text appendFormat:@"%.1f°F ", temp * 9.0/5.0 + 32.0];
        }
    }
    
    // CPU
    if (g_cld_statbarShowCPU) {
        float cpu = cld_statbar_get_cpu_usage();
        if (cpu >= 0) {
            if (g_cld_statbarShowLabels) [text appendString:@"CPU:"];
            [text appendFormat:@"%.0f%% ", cpu];
        }
    }
    
    // RAM
    double freeRAM = cld_statbar_get_free_ram_gb();
    if (g_cld_statbarShowLabels) [text appendString:@"RAM:"];
    [text appendFormat:@"%.2fGB ", freeRAM];
    
    // Network speed
    if (g_cld_statbarShowNet) {
        static CLDNetSample prevSample = {0, 0};
        static BOOL hasPrev = NO;
        
        CLDNetSample current = cld_statbar_sample_net();
        if (hasPrev) {
            double downKBps = (double)(current.downBytes - prevSample.downBytes) / 1024.0;
            double upKBps = (double)(current.upBytes - prevSample.upBytes) / 1024.0;
            [text appendFormat:@"↓%@ ↑%@",
             cld_statbar_format_speed(downKBps),
             cld_statbar_format_speed(upKBps)];
        }
        prevSample = current;
        hasPrev = YES;
    }
    
    g_cld_statbarLabel.text = text;
}
@end

static void cld_statbar_create_window(void) {
    if (g_cld_statbarWindow) return;
    
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = 999.0;
    window.userInteractionEnabled = NO;
    window.hidden = NO;
    
    CGFloat labelWidth = 280;
    CGFloat labelHeight = 20;
    CGFloat labelX = (window.bounds.size.width - labelWidth) / 2;
    CGFloat labelY = 56; // Below status bar
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelX, labelY, labelWidth, labelHeight)];
    label.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 4;
    label.layer.masksToBounds = YES;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.6;
    label.text = @"Starting...";
    
    [window addSubview:label];
    
    g_cld_statbarWindow = window;
    g_cld_statbarLabel = label;
    
    g_cld_statbarTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                          target:[_CLDStatBarHelper class]
                                                        selector:@selector(cld_statbar_timerTick:)
                                                        userInfo:nil
                                                         repeats:YES];
}

static void cld_statbar_destroy(void) {
    [g_cld_statbarTimer invalidate];
    g_cld_statbarTimer = nil;
    [g_cld_statbarLabel removeFromSuperview];
    g_cld_statbarLabel = nil;
    g_cld_statbarWindow.hidden = YES;
    g_cld_statbarWindow = nil;
}

static void cld_loadStatBarPrefs() {
    BOOL wasEnabled = g_cld_statbarEnabled;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_statbarEnabled = [prefs[@"cld_statbarEnabled"] boolValue];
    g_cld_statbarCelsius = ![prefs[@"cld_statbarFahrenheit"] boolValue];
    g_cld_statbarShowNet = [prefs[@"cld_statbarShowNet"] boolValue];
    g_cld_statbarShowCPU = [prefs[@"cld_statbarShowCPU"] boolValue];
    g_cld_statbarShowLabels = [prefs[@"cld_statbarShowLabels"] boolValue];
    
    if (g_cld_statbarEnabled && !wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cld_statbar_create_window();
        });
    } else if (!g_cld_statbarEnabled && wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cld_statbar_destroy();
        });
    }
}

__attribute__((constructor)) static void cld_StatBar_init(void) {
    cld_loadStatBarPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadStatBarPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
