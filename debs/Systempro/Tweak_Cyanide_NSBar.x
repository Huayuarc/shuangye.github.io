// Tweak_Cyanide_NSBar.x
// Ported from Cyanide nsbar - Real-time network speed overlay in status bar area

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/sysctl.h>

static BOOL g_cld_nsbarEnabled = NO;
static int g_cld_nsbarPosition = 0; // 0=top-right, 1=top-left, 2=bottom-right, 3=bottom-left, 4=bottom-center
static UIWindow *g_cld_nsbarWindow = nil;
static UILabel *g_cld_nsbarLabel = nil;
static NSTimer *g_cld_nsbarTimer = nil;
static NSTimeInterval g_cld_nsbarLastSample = 0;
static uint64_t g_cld_nsbarLastDown = 0;
static uint64_t g_cld_nsbarLastUp = 0;

static void cld_nsbar_get_traffic(uint64_t *downBytes, uint64_t *upBytes) {
    *downBytes = 0;
    *upBytes = 0;
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return;
    
    for (struct ifaddrs *addr = addrs; addr; addr = addr->ifa_next) {
        if (!addr->ifa_addr || addr->ifa_addr->sa_family != AF_LINK) continue;
        NSString *name = @(addr->ifa_name);
        if ([name isEqualToString:@"lo0"]) continue;
        
        struct if_data *stats = (struct if_data *)addr->ifa_data;
        if (stats) {
            *downBytes += stats->ifi_ibytes;
            *upBytes += stats->ifi_obytes;
        }
    }
    freeifaddrs(addrs);
}

static NSString *cld_nsbar_format_speed(double kbps) {
    if (kbps >= 1024.0) {
        return [NSString stringWithFormat:@"%.1fM", kbps / 1024.0];
    } else if (kbps >= 1.0) {
        return [NSString stringWithFormat:@"%.0fK", kbps];
    } else {
        return @"0K";
    }
}

static void cld_nsbar_update(void) {
    if (!g_cld_nsbarEnabled || !g_cld_nsbarLabel) {
        [g_cld_nsbarTimer invalidate];
        g_cld_nsbarTimer = nil;
        return;
    }
    
    uint64_t downBytes = 0, upBytes = 0;
    cld_nsbar_get_traffic(&downBytes, &upBytes);
    
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (g_cld_nsbarLastSample > 0) {
        double elapsed = now - g_cld_nsbarLastSample;
        if (elapsed > 0) {
            double downKBps = (double)(downBytes - g_cld_nsbarLastDown) / elapsed / 1024.0;
            double upKBps = (double)(upBytes - g_cld_nsbarLastUp) / elapsed / 1024.0;
            
            NSString *text = [NSString stringWithFormat:@"↓%@ ↑%@",
                              cld_nsbar_format_speed(downKBps),
                              cld_nsbar_format_speed(upKBps)];
            g_cld_nsbarLabel.text = text;
        }
    }
    
    g_cld_nsbarLastSample = now;
    g_cld_nsbarLastDown = downBytes;
    g_cld_nsbarLastUp = upBytes;
}

// Timer helper class
@interface _CLDNSBarHelper : NSObject
+ (void)cld_nsbar_timerTick:(NSTimer *)timer;
@end
@implementation _CLDNSBarHelper
+ (void)cld_nsbar_timerTick:(NSTimer *)timer {
    cld_nsbar_update();
}
@end

static void cld_nsbar_create_window(void) {
    if (g_cld_nsbarWindow) return;
    
    g_cld_nsbarWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    g_cld_nsbarWindow.windowLevel = 999.0;
    g_cld_nsbarWindow.userInteractionEnabled = NO;
    g_cld_nsbarWindow.hidden = NO;
    
    CGFloat labelWidth = 160;
    CGFloat labelHeight = 20;
    CGFloat labelX, labelY;
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat safeAreaTop = 54;
    CGFloat safeAreaBottom = 34;
    
    switch (g_cld_nsbarPosition) {
        case 0:
            labelX = screenBounds.size.width - labelWidth - 8;
            labelY = safeAreaTop + 2;
            break;
        case 1:
            labelX = 8;
            labelY = safeAreaTop + 2;
            break;
        case 2:
            labelX = screenBounds.size.width - labelWidth - 8;
            labelY = screenBounds.size.height - safeAreaBottom - labelHeight - 4;
            break;
        case 3:
            labelX = 8;
            labelY = screenBounds.size.height - safeAreaBottom - labelHeight - 4;
            break;
        default:
            labelX = (screenBounds.size.width - labelWidth) / 2;
            labelY = screenBounds.size.height - safeAreaBottom - labelHeight - 4;
            break;
    }
    
    g_cld_nsbarLabel = [[UILabel alloc] initWithFrame:CGRectMake(labelX, labelY, labelWidth, labelHeight)];
    g_cld_nsbarLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    g_cld_nsbarLabel.textColor = [UIColor whiteColor];
    g_cld_nsbarLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    g_cld_nsbarLabel.textAlignment = NSTextAlignmentCenter;
    g_cld_nsbarLabel.layer.cornerRadius = 4;
    g_cld_nsbarLabel.layer.masksToBounds = YES;
    g_cld_nsbarLabel.adjustsFontSizeToFitWidth = YES;
    g_cld_nsbarLabel.minimumScaleFactor = 0.7;
    g_cld_nsbarLabel.text = @"↓0K ↑0K";
    
    [g_cld_nsbarWindow addSubview:g_cld_nsbarLabel];
    
    g_cld_nsbarLastSample = 0;
    g_cld_nsbarLastDown = 0;
    g_cld_nsbarLastUp = 0;
    
    g_cld_nsbarTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:[_CLDNSBarHelper class]
                                                      selector:@selector(cld_nsbar_timerTick:)
                                                      userInfo:nil
                                                       repeats:YES];
}

static void cld_nsbar_destroy(void) {
    [g_cld_nsbarTimer invalidate];
    g_cld_nsbarTimer = nil;
    [g_cld_nsbarLabel removeFromSuperview];
    g_cld_nsbarLabel = nil;
    g_cld_nsbarWindow.hidden = YES;
    g_cld_nsbarWindow = nil;
}

%group NSBarHooks
%end // NSBarHooks

static void cld_loadNSBarPrefs() {
    BOOL wasEnabled = g_cld_nsbarEnabled;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_nsbarEnabled = [prefs[@"cld_nsbarEnabled"] boolValue];
    g_cld_nsbarPosition = (int)[prefs[@"cld_nsbarPosition"] integerValue];
    
    if (g_cld_nsbarEnabled && !wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cld_nsbar_create_window();
        });
    } else if (!g_cld_nsbarEnabled && wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cld_nsbar_destroy();
        });
    }
}

static void cld_NSBar_init(void) {
    cld_loadNSBarPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadNSBarPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

__attribute__((constructor)) static void cld_nsbar_ctor(void) {
    cld_NSBar_init();
}
