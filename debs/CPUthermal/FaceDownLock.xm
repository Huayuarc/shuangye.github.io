#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <CPUthermalPaths.h>

@interface SpringBoard : UIApplication
+ (instancetype)sharedApplication;
- (void)_simulateLockButtonPress;
@end

static BOOL gFaceDownLockEnabled = NO;
static CFAbsoluteTime gLastFaceDownLockTime = 0;
static int gFaceDownSettingsToken = 0;

static void ReloadFaceDownPreference(void) {
    gFaceDownLockEnabled = [CPUthermalReadPrefs()[S("lockWhenFaceDown")] boolValue];
}

%hook SBIdleTimerGlobalStateMonitor
- (void)pocketStateMonitor:(id)monitor pocketStateDidChangeFrom:(long long)oldState to:(long long)newState {
    %orig;
    if (!gFaceDownLockEnabled || newState != 3) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastFaceDownLockTime < 1.5) return;
    gLastFaceDownLockTime = now;
    id springBoard = [%c(SpringBoard) sharedApplication];
    if ([springBoard respondsToSelector:@selector(_simulateLockButtonPress)])
        [springBoard _simulateLockButtonPress];
}
%end

%ctor {
    @autoreleasepool {
        ReloadFaceDownPreference();
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gFaceDownSettingsToken,
                                 dispatch_get_main_queue(), ^(int token) {
            (void)token;
            ReloadFaceDownPreference();
        });
    }
}
