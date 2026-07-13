// Tweak_Cyanide_NiceBar.x
// Ported from Cyanide nicebarlite - Status bar multi-slot text overlay

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import <sys/sysctl.h>
#import <IOKit/IOKitLib.h>
#import <netinet/in.h>
#import <arpa/inet.h>

// Slot positions
#define kNBL_SLOT_TOP_LEFT     0
#define kNBL_SLOT_TOP_RIGHT    1
#define kNBL_SLOT_BOT_LEFT     2
#define kNBL_SLOT_BOT_RIGHT    3
#define kNBL_SLOT_BOT_CENTER   4

// Content kinds
#define kNBL_CONTENT_OFF       0
#define kNBL_CONTENT_CUSTOM    1
#define kNBL_CONTENT_SYSTEM    2
#define kNBL_CONTENT_TIME      3

// System items
#define kNBL_SYS_BATT_TEMP     0
#define kNBL_SYS_FREE_RAM      1
#define kNBL_SYS_BATT_PERCENT  2
#define kNBL_SYS_NET_SPEED     3
#define kNBL_SYS_UPTIME        4
#define kNBL_SYS_DATE          5
#define kNBL_SYS_TODAY_TRAFFIC 6
#define kNBL_SYS_CURRENT_IP    7
#define kNBL_SYS_FREE_DISK     8
#define kNBL_SYS_THERMAL       9

static BOOL g_cld_nicebarEnabled = NO;

typedef struct {
    int contentKind;      // kNBL_CONTENT_*
    int systemItem;       // kNBL_SYS_*
    NSString *customText;
    NSString *timeFormat;
} CLDNiceBarSlotConfig;

static CLDNiceBarSlotConfig g_cld_nicebarSlots[5];
static UIWindow *g_cld_nicebarWindow = nil;
static UILabel *g_cld_nicebarLabels[5];
static NSTimer *g_cld_nicebarTimer = nil;

#pragma mark - System info helpers

static float cld_nicebar_battery_temp(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                       IOServiceMatching("AppleSmartBattery"));
    if (!service) return 0;
    
    io_connect_t connect;
    if (IOServiceOpen(service, mach_task_self(), 0, &connect) != kIOReturnSuccess) {
        IOObjectRelease(service);
        return 0;
    }
    IOObjectRelease(service);
    
    uint64_t temperature = 0;
    uint32_t outputCount = 1;
    IOReturn ret = IOConnectCallMethod(connect, 0, NULL, 0, NULL, 0,
                                       &temperature, &outputCount, NULL, NULL);
    IOServiceClose(connect);
    return (ret == kIOReturnSuccess) ? (float)((double)temperature / 100.0) : 0;
}

static double cld_nicebar_free_ram_gb(void) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vmstat;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vmstat, &count) == KERN_SUCCESS) {
        return (double)(vmstat.free_count * vm_page_size) / (1024.0 * 1024.0 * 1024.0);
    }
    return 0;
}

static int cld_nicebar_battery_percent(void) {
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    return (int)(UIDevice.currentDevice.batteryLevel * 100);
}

typedef struct {
    uint64_t down, up;
    NSTimeInterval time;
} CLDNetSample;

static CLDNetSample cld_nicebar_sample_net(void) {
    CLDNetSample s = {0, 0, [[NSProcessInfo processInfo] systemUptime]};
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs)) return s;
    for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_LINK) continue;
        if ([@(a->ifa_name) isEqualToString:@"lo0"]) continue;
        struct if_data *stats = (struct if_data *)a->ifa_data;
        if (stats) { s.down += stats->ifi_ibytes; s.up += stats->ifi_obytes; }
    }
    freeifaddrs(addrs);
    return s;
}

static NSString *cld_nicebar_uptime(void) {
    struct timeval boottime;
    size_t len = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boottime, &len, NULL, 0)) return @"N/A";
    
    time_t uptime = time(NULL) - boottime.tv_sec;
    int days = (int)(uptime / 86400);
    int hours = (int)((uptime % 86400) / 3600);
    int mins = (int)((uptime % 3600) / 60);
    
    if (days > 0) return [NSString stringWithFormat:@"%dd %dh", days, hours];
    return [NSString stringWithFormat:@"%dh %dm", hours, mins];
}

static NSString *cld_nicebar_get_ip(void) {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs)) return @"N/A";
    
    NSString *ip = @"N/A";
    for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = @(a->ifa_name);
        if ([name isEqualToString:@"en0"]) {
            char buf[INET_ADDRSTRLEN];
            struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
            inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
            ip = @(buf);
            break;
        }
    }
    freeifaddrs(addrs);
    return ip;
}

static NSString *cld_nicebar_free_disk(void) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    if (!attrs) return @"N/A";
    long long free = [attrs[NSFileSystemFreeSize] longLongValue];
    double gb = (double)free / (1024.0 * 1024.0 * 1024.0);
    return [NSString stringWithFormat:@"%.1fGB", gb];
}

static NSString *cld_nicebar_thermal_state(void) {
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal: return @"●";
        case NSProcessInfoThermalStateFair:    return @"● Fair";
        case NSProcessInfoThermalStateSerious: return @"● Serious";
        case NSProcessInfoThermalStateCritical: return @"● Critical";
        default: return @"Unknown";
    }
}

#pragma mark - Slot text generation

static NSString *cld_nicebar_get_slot_text(CLDNiceBarSlotConfig *slot) {
    switch (slot->contentKind) {
        case kNBL_CONTENT_OFF:
            return nil;
        case kNBL_CONTENT_CUSTOM:
            return slot->customText ?: @"";
        case kNBL_CONTENT_TIME: {
            NSString *fmt = slot->timeFormat ?: @"HH:mm";
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = fmt;
            return [df stringFromDate:[NSDate date]];
        }
        case kNBL_CONTENT_SYSTEM: {
            switch (slot->systemItem) {
                case kNBL_SYS_BATT_TEMP: {
                    float t = cld_nicebar_battery_temp();
                    return [NSString stringWithFormat:@"%.1f°C", t];
                }
                case kNBL_SYS_FREE_RAM: {
                    double ram = cld_nicebar_free_ram_gb();
                    return [NSString stringWithFormat:@"%.2fGB", ram];
                }
                case kNBL_SYS_BATT_PERCENT:
                    return [NSString stringWithFormat:@"%d%%", cld_nicebar_battery_percent()];
                case kNBL_SYS_NET_SPEED: {
                    static CLDNetSample prev = {0, 0, 0};
                    CLDNetSample cur = cld_nicebar_sample_net();
                    if (prev.time > 0) {
                        double dt = cur.time - prev.time;
                        if (dt > 0) {
                            double d = (double)(cur.down - prev.down) / dt / 1024.0;
                            double u = (double)(cur.up - prev.up) / dt / 1024.0;
                            prev = cur;
                            return [NSString stringWithFormat:@"↓%.0f ↑%.0f KB/s", d, u];
                        }
                    }
                    prev = cur;
                    return @"↓0 ↑0 KB/s";
                }
                case kNBL_SYS_UPTIME:
                    return cld_nicebar_uptime();
                case kNBL_SYS_DATE: {
                    NSDateFormatter *df = [[NSDateFormatter alloc] init];
                    df.dateFormat = @"MM/dd";
                    return [df stringFromDate:[NSDate date]];
                }
                case kNBL_SYS_TODAY_TRAFFIC:
                    return @"N/A"; // Would need persistent counter
                case kNBL_SYS_CURRENT_IP:
                    return cld_nicebar_get_ip();
                case kNBL_SYS_FREE_DISK:
                    return cld_nicebar_free_disk();
                case kNBL_SYS_THERMAL:
                    return cld_nicebar_thermal_state();
                default:
                    return @"";
            }
        }
        default:
            return @"";
    }
}

#pragma mark - UI

@interface _CLDNiceBarHelper : NSObject
+ (void)cld_nicebar_update:(NSTimer *)timer;
@end
@implementation _CLDNiceBarHelper
+ (void)cld_nicebar_update:(NSTimer *)timer {
    if (!g_cld_nicebarEnabled) return;
    for (int i = 0; i < 5; i++) {
        if (g_cld_nicebarLabels[i]) {
            NSString *text = cld_nicebar_get_slot_text(&g_cld_nicebarSlots[i]);
            g_cld_nicebarLabels[i].text = text ?: @"";
            g_cld_nicebarLabels[i].hidden = (text == nil);
        }
    }
}
@end

static void cld_nicebar_create_window(void) {
    if (g_cld_nicebarWindow) return;
    
    g_cld_nicebarWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    g_cld_nicebarWindow.windowLevel = 999.0;
    g_cld_nicebarWindow.userInteractionEnabled = NO;
    g_cld_nicebarWindow.hidden = NO;
    
    CGFloat safeTop = 54;
    CGFloat safeBottom = 34;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat slotH = 18;
    CGFloat fontSize = 10;
    
    struct { CGFloat x, y, w; } slots5[5] = {
        {8, safeTop + 2, 120},           // top-left
        {screenW - 128, safeTop + 2, 120}, // top-right
        {8, 0, 140},                      // bottom-left (y set below)
        {screenW - 148, 0, 140},          // bottom-right (y set below)
        {(screenW - 160)/2, 0, 160},      // bottom-center (y set below)
    };
    
    CGFloat bottomY = [UIScreen mainScreen].bounds.size.height - safeBottom - slotH - 4;
    slots5[2].y = bottomY;
    slots5[3].y = bottomY;
    slots5[4].y = bottomY;
    
    for (int i = 0; i < 5; i++) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(slots5[i].x, slots5[i].y, slots5[i].w, slotH)];
        label.font = [UIFont monospacedDigitSystemFontOfSize:fontSize weight:UIFontWeightMedium];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        label.textAlignment = NSTextAlignmentCenter;
        label.layer.cornerRadius = 4;
        label.layer.masksToBounds = YES;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.6;
        label.hidden = YES;
        
        [g_cld_nicebarWindow addSubview:label];
        g_cld_nicebarLabels[i] = label;
    }
    
    g_cld_nicebarTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                          target:[_CLDNiceBarHelper class]
                                                        selector:@selector(cld_nicebar_update:)
                                                        userInfo:nil
                                                         repeats:YES];
}

static void cld_nicebar_destroy(void) {
    [g_cld_nicebarTimer invalidate];
    g_cld_nicebarTimer = nil;
    for (int i = 0; i < 5; i++) {
        [g_cld_nicebarLabels[i] removeFromSuperview];
        g_cld_nicebarLabels[i] = nil;
    }
    g_cld_nicebarWindow.hidden = YES;
    g_cld_nicebarWindow = nil;
}

static void cld_loadNiceBarPrefs() {
    BOOL wasEnabled = g_cld_nicebarEnabled;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_nicebarEnabled = [prefs[@"cld_nicebarEnabled"] boolValue];
    
    if (g_cld_nicebarEnabled) {
        for (int i = 0; i < 5; i++) {
            NSString *key = [NSString stringWithFormat:@"cld_nicebar_slot%d_kind", i];
            NSString *customKey = [NSString stringWithFormat:@"cld_nicebar_slot%d_custom", i];
            NSString *sysKey = [NSString stringWithFormat:@"cld_nicebar_slot%d_system", i];
            NSString *timeKey = [NSString stringWithFormat:@"cld_nicebar_slot%d_time", i];
            
            g_cld_nicebarSlots[i].contentKind = (int)[prefs[key] integerValue];
            g_cld_nicebarSlots[i].customText = prefs[customKey];
            g_cld_nicebarSlots[i].systemItem = (int)[prefs[sysKey] integerValue];
            g_cld_nicebarSlots[i].timeFormat = prefs[timeKey];
        }
    }
    
    if (g_cld_nicebarEnabled && !wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cld_nicebar_create_window();
        });
    } else if (!g_cld_nicebarEnabled && wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cld_nicebar_destroy();
        });
    }
}

__attribute__((constructor)) static void cld_NiceBar_init(void) {
    cld_loadNiceBarPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadNiceBarPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
