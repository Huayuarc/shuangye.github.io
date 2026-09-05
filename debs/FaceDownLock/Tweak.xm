#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <FaceDownLockPaths.h>

#ifdef FACEDOWNLOCK_STRIP_LOGS
#define NSLog(...) do {} while (0)
#endif

@interface SpringBoard : UIApplication
+ (instancetype)sharedApplication;
- (void)_simulateLockButtonPress;
@end

static BOOL gEnabled = NO;
static CFAbsoluteTime gLastLockTime = 0;
static int gSettingsToken = 0;

static void FDLReloadPreference(void) {
    NSDictionary *prefs = FDLReadPrefs();
    id value = [prefs[FDL_S("enabled")] respondsToSelector:@selector(boolValue)] ? prefs[FDL_S("enabled")] : nil;
    gEnabled = value ? [value boolValue] : NO;
}

static void FDLLockScreenIfNeeded(void) {
    if (!gEnabled) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastLockTime < 1.5) return;
    gLastLockTime = now;

    id springBoard = [%c(SpringBoard) sharedApplication];
    SEL lockSelector = @selector(_simulateLockButtonPress);
    if ([springBoard respondsToSelector:lockSelector]) {
        [springBoard _simulateLockButtonPress];
        NSLog(@"[FaceDownLock] 设备朝下，已模拟锁屏键");
    }
}

%hook SBIdleTimerGlobalStateMonitor
- (void)pocketStateMonitor:(id)monitor pocketStateDidChangeFrom:(long long)oldState to:(long long)newState {
    %orig;
    // 源功能中 3 表示设备屏幕朝下/进入口袋态。
    if (newState == 3 && oldState != 3) FDLLockScreenIfNeeded();
}
%end

%ctor {
    @autoreleasepool {
        FDLReloadPreference();
        notify_register_dispatch(kFDLSettingsChangedNotifC, &gSettingsToken,
                                 dispatch_get_main_queue(), ^(int token) {
            (void)token;
            FDLReloadPreference();
        });
    }
}
