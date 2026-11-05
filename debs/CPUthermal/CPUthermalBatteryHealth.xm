// Based on PoomSmart/Battery-Health-Enabler (MIT): scoped, switchable BatteryUsageUI hooks.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import <CPUthermalPaths.h>

static BOOL gCPUthermalSuppressBatteryServiceWarning = NO;
static int gCPUthermalBatterySettingsToken = -1;

static BOOL CPUthermalBatteryWarningSuppressionEnabled(void) {
    return __atomic_load_n(&gCPUthermalSuppressBatteryServiceWarning, __ATOMIC_ACQUIRE);
}

static void CPUthermalReloadBatteryWarningPreference(void) {
    @autoreleasepool {
        id value = CPUthermalReadPrefsSnapshot()[S("suppressBatteryServiceWarnings")];
        BOOL enabled = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
        __atomic_store_n(&gCPUthermalSuppressBatteryServiceWarning, enabled, __ATOMIC_RELEASE);
    }
}

%group CPUthermalBatteryHealthHooks

%hook BatteryUIResourceClass

+ (int)getManagementState {
    if (CPUthermalBatteryWarningSuppressionEnabled()) return 2;
    return %orig;
}

+ (int)genuineBatteryStatus {
    if (CPUthermalBatteryWarningSuppressionEnabled()) return 1;
    return %orig;
}

+ (int)getBatteryHealthServiceState {
    if (CPUthermalBatteryWarningSuppressionEnabled()) return 0;
    return %orig;
}

%end

%hook BatteryUIController

- (id)getBatteryServiceSuggestion:(uintptr_t)suggestion {
    if (CPUthermalBatteryWarningSuppressionEnabled()) return nil;
    return %orig(suggestion);
}

%end

%end

static void CPUthermalInstallBatteryHealthHooksIfAvailable(void) {
    if (!objc_getClass("BatteryUIResourceClass") && !objc_getClass("BatteryUIController")) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ %init(CPUthermalBatteryHealthHooks); });
}

static void CPUthermalBatteryBundleLoaded(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object,
                                          CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    CPUthermalInstallBatteryHealthHooksIfAvailable();
}

%ctor {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        if (![process isEqualToString:S("Preferences")]) return;
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.cputhermal.battery-health.prefs",
                                                       DISPATCH_QUEUE_SERIAL);
        dispatch_async(queue, ^{ CPUthermalReloadBatteryWarningPreference(); });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gCPUthermalBatterySettingsToken,
                                 queue, ^(int token) {
            (void)token;
            CPUthermalReloadBatteryWarningPreference();
        });
        CPUthermalInstallBatteryHealthHooksIfAvailable();
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                        CPUthermalBatteryBundleLoaded,
                                        (__bridge CFStringRef)NSBundleDidLoadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
