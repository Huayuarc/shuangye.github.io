// isolation.16: SpringBoard stability: never interpose process-wide libnotify.
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dlfcn.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <CPUthermalPaths.h>

static BOOL gBlockThermalPopup = NO;
static int gThermalWarnSettingsToken = -1;
static BOOL CPUthermalWarnEnabled(void) {
    return __atomic_load_n(&gBlockThermalPopup, __ATOMIC_ACQUIRE);
}
static void ReloadThermalWarnPreference(void) {
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id v = prefs[S("blockThermalPopup")];
        BOOL enabled = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
        __atomic_store_n(&gBlockThermalPopup, enabled, __ATOMIC_RELEASE);
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
    if (level) MSHookFunction(level, (void *)CPUthermalHookedOSThermalLevel, (void **)&gOrigOSThermalLevel);
}

%hook NSProcessInfo
- (NSInteger)thermalState {
    if (CPUthermalWarnEnabled()) return 0;
    return %orig;
}
%end

%ctor {
    @autoreleasepool {
        // Disk I/O stays off SpringBoard's main thread. Disabled until loaded.
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.cputhermal.warn.prefs", DISPATCH_QUEUE_SERIAL);
        CPUthermalInstallThermalStateSpoof();
        dispatch_async(queue, ^{ ReloadThermalWarnPreference(); });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gThermalWarnSettingsToken,
                                 queue, ^(int token) {
            (void)token;
            ReloadThermalWarnPreference();
        });
    }
}
