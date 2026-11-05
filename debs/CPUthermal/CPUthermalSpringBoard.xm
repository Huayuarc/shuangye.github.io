// isolation.20: merge FaceDownLock and ThermalWarn into one SpringBoard image.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <CPUthermalPaths.h>

@interface SpringBoard : UIApplication
+ (instancetype)sharedApplication;
- (void)_simulateLockButtonPress;
@end

static BOOL gFaceDownLockEnabled = NO;
static BOOL gBlockThermalPopup = NO;
static CFAbsoluteTime gLastFaceDownLockTime = 0;
static int gSpringBoardSettingsToken = -1;

static BOOL CPUthermalWarnEnabled(void) {
    return __atomic_load_n(&gBlockThermalPopup, __ATOMIC_ACQUIRE);
}

static void CPUthermalReloadSpringBoardPreferences(void) {
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id faceValue = prefs[S("lockWhenFaceDown")];
        id warnValue = prefs[S("blockThermalPopup")];
        BOOL faceEnabled = [faceValue respondsToSelector:@selector(boolValue)] ? [faceValue boolValue] : NO;
        BOOL warnEnabled = [warnValue respondsToSelector:@selector(boolValue)] ? [warnValue boolValue] : NO;
        __atomic_store_n(&gFaceDownLockEnabled, faceEnabled, __ATOMIC_RELEASE);
        __atomic_store_n(&gBlockThermalPopup, warnEnabled, __ATOMIC_RELEASE);
    }
}

typedef int (*CPUthermalOSThermalLevelFn)(void);
static CPUthermalOSThermalLevelFn gOrigOSThermalLevel = NULL;
static int CPUthermalHookedOSThermalLevel(void) {
    if (CPUthermalWarnEnabled()) return 0;
    return gOrigOSThermalLevel ? gOrigOSThermalLevel() : 0;
}

static void CPUthermalInstallThermalStateSpoof(void) {
    void *level = dlsym(RTLD_DEFAULT, "_OSThermalNotificationCurrentLevel");
    if (level) MSHookFunction(level, (void *)CPUthermalHookedOSThermalLevel,
                              (void **)&gOrigOSThermalLevel);
}

%hook NSProcessInfo
- (NSInteger)thermalState {
    if (CPUthermalWarnEnabled()) return 0;
    return %orig;
}
%end

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
        if ([springBoard respondsToSelector:@selector(_simulateLockButtonPress)]) {
            [springBoard _simulateLockButtonPress];
        }
    });
}
%end

%ctor {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.cputhermal.springboard.prefs",
                                                       DISPATCH_QUEUE_SERIAL);
        CPUthermalInstallThermalStateSpoof();
        dispatch_async(queue, ^{ CPUthermalReloadSpringBoardPreferences(); });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gSpringBoardSettingsToken,
                                 queue, ^(int token) {
            (void)token;
            CPUthermalReloadSpringBoardPreferences();
        });
    }
}
