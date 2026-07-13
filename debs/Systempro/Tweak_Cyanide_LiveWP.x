// Tweak_Cyanide_LiveWP.x
// Ported from Cyanide livewp - Video live wallpaper for lock screen and home screen

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

static BOOL g_cld_livewpEnabled = NO;
static NSString *g_cld_livewpPath = nil;
static AVPlayer *g_cld_livewpPlayer = nil;
static AVPlayerLayer *g_cld_livewpLockLayer = nil;
static AVPlayerLayer *g_cld_livewpHomeLayer = nil;

@interface SBIconController : NSObject
- (void)_cld_setupLiveWallpaper;
+ (id)sharedInstance;
@end

%group LiveWPHooks

%hook SBIconController

- (void)_cld_setupLiveWallpaper {
    if (!g_cld_livewpEnabled || !g_cld_livewpPath) return;
    
    // Clean up existing
    [g_cld_livewpPlayer pause];
    g_cld_livewpPlayer = nil;
    [g_cld_livewpLockLayer removeFromSuperlayer];
    g_cld_livewpLockLayer = nil;
    [g_cld_livewpHomeLayer removeFromSuperlayer];
    g_cld_livewpHomeLayer = nil;
    
    // Create player
    NSURL *url = [NSURL fileURLWithPath:g_cld_livewpPath];
    if (!url) return;
    
    AVPlayer *player = [AVPlayer playerWithURL:url];
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    player.muted = YES;
    
    // Add observer for loop
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:player.currentItem
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        [player seekToTime:kCMTimeZero];
    }];
    
    g_cld_livewpPlayer = player;
    
    // Home screen layer
    UIWindow *homeWindow = [(id)self window];
    if (homeWindow) {
        AVPlayerLayer *homeLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        homeLayer.frame = homeWindow.bounds;
        homeLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        homeLayer.zPosition = -1000; // Behind everything
        [homeWindow.layer insertSublayer:homeLayer atIndex:0];
        g_cld_livewpHomeLayer = homeLayer;
    }
    
    // Lock screen window
    UIWindow *lockWindow = nil;
    // Find cover sheet window
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if ([NSStringFromClass([win class]) containsString:@"CoverSheet"]) {
            lockWindow = win;
            break;
        }
    }
    if (!lockWindow) lockWindow = homeWindow;
    
    AVPlayerLayer *lockLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    lockLayer.frame = lockWindow.bounds;
    lockLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    lockLayer.zPosition = -1000;
    [lockWindow.layer insertSublayer:lockLayer atIndex:0];
    g_cld_livewpLockLayer = lockLayer;
    
    [player play];
}

%end

%end // LiveWPHooks

static void cld_loadLiveWPPrefs() {
    BOOL wasEnabled = g_cld_livewpEnabled;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist"];
    g_cld_livewpEnabled = [prefs[@"cld_livewpEnabled"] boolValue];
    NSString *path = prefs[@"cld_livewpPath"];
    
    if (g_cld_livewpEnabled && path.length > 0) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
            g_cld_livewpPath = path;
        } else {
            g_cld_livewpEnabled = NO;
            return;
        }
    } else {
        g_cld_livewpEnabled = NO;
    }
    
    if (g_cld_livewpEnabled) {
        %init(LiveWPHooks);
    }
    
    if (g_cld_livewpEnabled != wasEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id ctrl = [objc_getClass("SBIconController") sharedInstance];
            [ctrl _cld_setupLiveWallpaper];
        });
    }
}

static void cld_LiveWP_init(void) {
    cld_loadLiveWPPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)cld_loadLiveWPPrefs,
                                    CFSTR("com.huayuarc.systempro.prefschanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

__attribute__((constructor)) static void cld_livewp_ctor(void) {
    cld_LiveWP_init();
}
