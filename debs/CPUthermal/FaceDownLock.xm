#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

@interface SpringBoard : UIApplication
+ (instancetype)sharedApplication;
- (void)_simulateLockButtonPress;
@end

static BOOL gFaceDownLockEnabled = NO;
static CFAbsoluteTime gLastFaceDownLockTime = 0;
static int gFaceDownSettingsToken = 0;

static void ReloadFaceDownPreference(void) {
    BOOL enabled = [CPUthermalReadPrefsSnapshot()[S("lockWhenFaceDown")] boolValue];
    __atomic_store_n(&gFaceDownLockEnabled, enabled, __ATOMIC_RELEASE);
}

%hook SBIdleTimerGlobalStateMonitor
- (void)pocketStateMonitor:(id)monitor pocketStateDidChangeFrom:(long long)oldState to:(long long)newState {
    %orig;
    if (!__atomic_load_n(&gFaceDownLockEnabled, __ATOMIC_ACQUIRE) || newState != 3) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!__atomic_load_n(&gFaceDownLockEnabled, __ATOMIC_ACQUIRE)) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - gLastFaceDownLockTime < 1.5) return;
        gLastFaceDownLockTime = now;
        id springBoard = [%c(SpringBoard) sharedApplication];
        if ([springBoard respondsToSelector:@selector(_simulateLockButtonPress)])
            [springBoard _simulateLockButtonPress];
    });
}
%end

%ctor {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.cputhermal.facedown.prefs", DISPATCH_QUEUE_SERIAL);
        dispatch_async(queue, ^{ @autoreleasepool { ReloadFaceDownPreference(); } });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gFaceDownSettingsToken,
                                 queue, ^(int token) {
            (void)token;
            @autoreleasepool { ReloadFaceDownPreference(); }
        });

    }
}
