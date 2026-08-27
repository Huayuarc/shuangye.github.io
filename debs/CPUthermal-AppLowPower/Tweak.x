#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <CPUthermalPaths.h>

#ifdef CPUTHERMAL_STRIP_LOGS
#define NSLog(...) do {} while (0)
#endif

@interface CommonProduct : NSObject
- (id)initProduct:(id)product;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (void)setCPULevel:(int)level;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(id)source;
- (void)tryTakeAction;
@end

@interface ApplePPMCPU : NSObject
- (void)setCPULevel:(int)level;
- (void)updateCPU;
@end

@interface MitigationController : NSObject
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams;
- (void)setCPMSMitigationsEnabled:(BOOL)enabled;
- (BOOL)powerSaveActive;
- (void)setPowerSaveActive:(BOOL)active;
- (void)setPowerSaveToken:(int)token;
- (void)setCPULevel:(int)level;
- (void)setDVD1Level:(int)level;
- (void)setCPULowPowerTarget:(int)target;
- (void)setMaxCPUPowerTarget:(int)target useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property;
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerCeiling:(int)ceiling forDVD1Contributor:(int)contributor;
- (void)setCPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source;
- (void)setCPUPowerZoneTarget:(int)target;
- (void)updateCPU;
- (void)updatePackage;
@end

static const int kLowPowerMW = 2500;
static const int kLowPowerPercent = 45;
static const int kLowPowerLevel = 2;
static const int kDecisionSourceCount = 6;
static const int kDVD1ContributorCount = 4;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static BOOL gSelectedAppActive = NO;
static __thread BOOL gApplying = NO;
static NSHashTable *gControllers;
static NSHashTable *gApplePPMInstances;
static CommonProduct *gCommonProduct;
static dispatch_source_t gKeepAliveTimer;

static BOOL selectedAppActive(void) {
    os_unfair_lock_lock(&gLock);
    BOOL active = gSelectedAppActive;
    os_unfair_lock_unlock(&gLock);
    return active;
}

static NSArray *snapshot(NSHashTable *table) {
    os_unfair_lock_lock(&gLock);
    NSArray *objects = table ? [table allObjects] : @[];
    os_unfair_lock_unlock(&gLock);
    return objects;
}

static void trackController(id object) {
    if (!object) return;
    os_unfair_lock_lock(&gLock);
    if (!gControllers) gControllers = [NSHashTable weakObjectsHashTable];
    [gControllers addObject:object];
    os_unfair_lock_unlock(&gLock);
}

static void trackApplePPM(id object) {
    if (!object) return;
    os_unfair_lock_lock(&gLock);
    if (!gApplePPMInstances) gApplePPMInstances = [NSHashTable weakObjectsHashTable];
    [gApplePPMInstances addObject:object];
    os_unfair_lock_unlock(&gLock);
}

static void sendTwoInts(id object, SEL selector, int first, uintptr_t second) {
    if (object && [object respondsToSelector:selector])
        ((void (*)(id, SEL, int, uintptr_t))objc_msgSend)(object, selector, first, second);
}

static uintptr_t maxPowerProperty(id controller) {
    Method method = class_getInstanceMethod([controller class],
                                            @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:));
    if (!method) return (uintptr_t)YES;
    char type[64] = {0};
    method_getArgumentType(method, 4, type, sizeof(type));
    return (strstr(type, "CFString") || type[0] == '@') ? (uintptr_t)S("CPUMaxPower") : (uintptr_t)YES;
}

static void applyToController(id controller) {
    if (!controller || !selectedAppActive()) return;
    trackController(controller);
    gApplying = YES;
    @try {
        if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setCPMSMitigationsEnabled:), YES);
        if ([controller respondsToSelector:@selector(setPowerSaveActive:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), YES);
        if ([controller respondsToSelector:@selector(setCPULowPowerTarget:)])
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULowPowerTarget:), kLowPowerMW);
        if ([controller respondsToSelector:@selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:)])
            ((void (*)(id, SEL, int, BOOL, uintptr_t))objc_msgSend)(controller, @selector(setMaxCPUPowerTarget:useLegacyPath:setProperty:), kLowPowerMW, NO, maxPowerProperty(controller));
        if ([controller respondsToSelector:@selector(setCPUPowerZoneTarget:)])
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPUPowerZoneTarget:), kLowPowerPercent);
        for (int source = 0; source < kDecisionSourceCount; source++) {
            sendTwoInts(controller, @selector(setCPUPowerCeiling:fromDecisionSource:), kLowPowerPercent, source);
            sendTwoInts(controller, @selector(setCPUPowerFloor:fromDecisionSource:), 0, source);
        }
        for (int contributor = 0; contributor < kDVD1ContributorCount; contributor++)
            sendTwoInts(controller, @selector(setCPUPowerCeiling:forDVD1Contributor:), kLowPowerPercent, contributor);
        if ([controller respondsToSelector:@selector(setCPULevel:)])
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setCPULevel:), kLowPowerLevel);
        if ([controller respondsToSelector:@selector(setDVD1Level:)])
            ((void (*)(id, SEL, int))objc_msgSend)(controller, @selector(setDVD1Level:), kLowPowerLevel);
    } @finally { gApplying = NO; }
}

static void applyToCommonProduct(void) {
    if (!selectedAppActive()) return;
    os_unfair_lock_lock(&gLock);
    CommonProduct *product = gCommonProduct;
    os_unfair_lock_unlock(&gLock);
    if (!product) return;
    gApplying = YES;
    @try {
        if ([product respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) [product setCPMSMitigationsEnabled:YES];
        if ([product respondsToSelector:@selector(setCPULevel:)]) [product setCPULevel:kLowPowerLevel];
        if ([product respondsToSelector:@selector(setCPUPowerCeiling:fromDecisionSource:)])
            [product setCPUPowerCeiling:kLowPowerPercent fromDecisionSource:S("CPUthermalAppLowPower")];
        if ([product respondsToSelector:@selector(setCPUPowerFloor:fromDecisionSource:)])
            [product setCPUPowerFloor:0 fromDecisionSource:S("CPUthermalAppLowPower")];
        if ([product respondsToSelector:@selector(tryTakeAction)]) [product tryTakeAction];
    } @finally { gApplying = NO; }
}

static void applyLowPower(void) {
    if (!selectedAppActive()) return;
    applyToCommonProduct();
    for (id controller in snapshot(gControllers)) applyToController(controller);
    for (id ppm in snapshot(gApplePPMInstances)) {
        gApplying = YES;
        if ([ppm respondsToSelector:@selector(setCPULevel:)]) [ppm setCPULevel:kLowPowerLevel];
        gApplying = NO;
    }
}

static void restoreNativePolicy(void) {
    gApplying = YES;
    @try {
        for (id controller in snapshot(gControllers)) {
            // 退出指定应用后只触发系统重新计算，不强写满血或低功耗状态。
            if ([controller respondsToSelector:@selector(setCPMSMitigationsEnabled:)]) [controller setCPMSMitigationsEnabled:YES];
            if ([controller respondsToSelector:@selector(updateCPU)]) [controller updateCPU];
            if ([controller respondsToSelector:@selector(updatePackage)]) [controller updatePackage];
        }
        for (id ppm in snapshot(gApplePPMInstances)) if ([ppm respondsToSelector:@selector(updateCPU)]) [ppm updateCPU];
        os_unfair_lock_lock(&gLock);
        CommonProduct *product = gCommonProduct;
        os_unfair_lock_unlock(&gLock);
        if ([product respondsToSelector:@selector(tryTakeAction)]) [product tryTakeAction];
    } @finally { gApplying = NO; }
}

static BOOL prefsSelectCurrentApp(void) {
    NSDictionary *prefs = CPUthermalReadPrefs();
    NSArray *selected = [prefs[S("lowPowerApps")] isKindOfClass:[NSArray class]] ? prefs[S("lowPowerApps")] : nil;
    uint64_t foreground = CPUthermalReadForegroundBundleHash();
    if (!foreground || !selected.count) return NO;
    for (id bundleID in selected)
        if ([bundleID isKindOfClass:[NSString class]] && CPUthermalBundleIDHash(bundleID) == foreground) return YES;
    return NO;
}

static void refreshActiveState(void) {
    BOOL next = prefsSelectCurrentApp();
    os_unfair_lock_lock(&gLock);
    BOOL previous = gSelectedAppActive;
    gSelectedAppActive = next;
    os_unfair_lock_unlock(&gLock);
    if (next) applyLowPower();
    else if (previous) restoreNativePolicy();
}

static void notificationCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ refreshActiveState(); });
}

%hook CommonProduct
- (id)initProduct:(id)product {
    id result = %orig(product);
    os_unfair_lock_lock(&gLock); gCommonProduct = result; os_unfair_lock_unlock(&gLock);
    applyLowPower();
    return result;
}
- (void)setCPULevel:(int)level { %orig((selectedAppActive() && !gApplying) ? kLowPowerLevel : level); }
- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(id)source { %orig((selectedAppActive() && !gApplying) ? kLowPowerPercent : ceiling, source); }
%end

%hook ApplePPMCPU
- (id)init { id result = %orig; trackApplePPM(result); return result; }
- (void)setCPULevel:(int)level { trackApplePPM(self); %orig((selectedAppActive() && !gApplying) ? kLowPowerLevel : level); }
- (void)updateCPU { %orig; if (selectedAppActive() && !gApplying) applyLowPower(); }
%end

%hook MitigationController
- (id)initForFastLoop:(BOOL)fastLoop noDisplay:(BOOL)noDisplay powerSaveParams:(id)saveParams powerZoneParams:(id)zoneParams {
    id result = %orig(fastLoop, noDisplay, saveParams, zoneParams); trackController(result); applyToController(result); return result;
}
- (BOOL)powerSaveActive { return (selectedAppActive() && !gApplying) ? YES : %orig; }
- (void)setPowerSaveActive:(BOOL)value { trackController(self); %orig((selectedAppActive() && !gApplying) ? YES : value); }
- (void)setCPULevel:(int)value { trackController(self); %orig((selectedAppActive() && !gApplying) ? kLowPowerLevel : value); }
- (void)setDVD1Level:(int)value { %orig((selectedAppActive() && !gApplying) ? kLowPowerLevel : value); }
- (void)setCPULowPowerTarget:(int)value { %orig((selectedAppActive() && !gApplying) ? kLowPowerMW : value); }
- (void)setMaxCPUPowerTarget:(int)value useLegacyPath:(BOOL)legacy setProperty:(uintptr_t)property { %orig((selectedAppActive() && !gApplying) ? kLowPowerMW : value, legacy, property); }
- (void)setCPUPowerCeiling:(int)value fromDecisionSource:(uintptr_t)source { %orig((selectedAppActive() && !gApplying) ? kLowPowerPercent : value, source); }
- (void)setCPUPowerCeiling:(int)value forDVD1Contributor:(int)contributor { %orig((selectedAppActive() && !gApplying) ? kLowPowerPercent : value, contributor); }
- (void)setCPUPowerFloor:(int)value fromDecisionSource:(uintptr_t)source { %orig((selectedAppActive() && !gApplying) ? 0 : value, source); }
- (void)setCPUPowerZoneTarget:(int)value { %orig((selectedAppActive() && !gApplying) ? kLowPowerPercent : value); }
- (void)updateCPU { trackController(self); %orig; if (selectedAppActive() && !gApplying) applyToController(self); }
%end

%ctor {
    @autoreleasepool {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, notificationCallback,
            (__bridge CFStringRef)S(kCPUthermalForegroundAppNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, notificationCallback,
            (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        refreshActiveState();
        gKeepAliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gKeepAliveTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(gKeepAliveTimer, ^{ if (selectedAppActive()) applyLowPower(); });
        dispatch_resume(gKeepAliveTimer);
    }
}
