#import <UIKit/UIKit.h>
#import "VVSFlipCardView.h"
#import "VVSVideoView.h"
#import "../common/VVSCommon.h"

// Concrete declaration so `self` inside the hook resolves UIViewController
// members and our added methods (Logos only emits a @class forward decl).
@interface CSCoverSheetViewController : UIViewController
- (void)vvs_reload;
@end

// Both wallpaper views live in the *fixed* wallpaper window (level -3) so they
// stay put while the cover sheet slides up on unlock.
static VVSFlipCardView *gFlip;
static VVSVideoView *gVideo;
static __weak UIView *gAnchor;

static BOOL VVSBool(NSString *key) {
    Boolean ok = false;
    Boolean v = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, kVVSPrefsAppID, &ok);
    return ok ? (BOOL)v : NO;
}
static BOOL VVSEnabled(void) {
    CFPreferencesAppSynchronize(kVVSPrefsAppID);
    return VVSBool(kVVSKeyEnabled);
}
static BOOL VVSVideoMode(void) {
    if (!VVSBool(kVVSKeyVideoEnabled)) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:VVSVideoPath()];
}

// The lock-screen wallpaper window — fixed during the unlock gesture.
static UIWindow *VVSWallpaperWindow(UIView *anyView) {
    UIWindowScene *scene = (UIWindowScene *)anyView.window.windowScene;
    if (!scene) return nil;
    UIWindow *fallback = nil;
    for (UIWindow *w in scene.windows) {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn isEqualToString:@"_SBWallpaperSecureWindow"]) return w;
        if ([cn containsString:@"Wallpaper"] && w.windowLevel < 0) fallback = w;
    }
    return fallback;
}

static void VVSAddToWindow(UIView *v, UIWindow *wp) {
    if (v.superview != wp) { [v removeFromSuperview]; [wp addSubview:v]; }
    v.frame = wp.bounds;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [wp bringSubviewToFront:v];
}

static void VVSApply(UIView *anchorView) {
    if (anchorView) gAnchor = anchorView;

    if (!VVSEnabled()) {
        [gFlip stopMotion];  gFlip.hidden = YES;
        [gVideo pause];      gVideo.hidden = YES;
        return;
    }

    UIWindow *wp = VVSWallpaperWindow(anchorView ?: gAnchor);
    if (!wp) return;

    if (VVSVideoMode()) {
        // --- video wallpaper wins ---
        [gFlip stopMotion]; gFlip.hidden = YES;
        if (!gVideo) gVideo = [[VVSVideoView alloc] initWithFrame:wp.bounds];
        else [gVideo reloadFromPreferences];
        if (!gVideo.hasVideo) { gVideo.hidden = YES; return; }
        gVideo.hidden = NO;
        VVSAddToWindow(gVideo, wp);
        [gVideo play];
        return;
    }

    // --- photo flip-card mode ---
    [gVideo pause]; gVideo.hidden = YES;
    if (!gFlip) gFlip = [[VVSFlipCardView alloc] initWithFrame:wp.bounds];
    else [gFlip reloadFromPreferences];
    if (!gFlip.hasContent) { gFlip.hidden = YES; return; }
    gFlip.hidden = NO;
    VVSAddToWindow(gFlip, wp);
    [gFlip startMotion];
}

static void VVSReloadCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ VVSApply(nil); });
}

%hook CSCoverSheetViewController

%new
- (void)vvs_reload { VVSApply(self.view); }

- (void)viewDidLoad {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, VVSReloadCallback, CFSTR(kVVSReloadNotification),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
    });
}

- (void)viewWillAppear:(BOOL)animated { %orig; VVSApply(self.view); }
- (void)viewDidAppear:(BOOL)animated  { %orig; VVSApply(self.view); }

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [gFlip stopMotion];
    [gVideo pause];
}

%end
