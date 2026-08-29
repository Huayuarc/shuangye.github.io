#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#import <CPUthermalPaths.h>

#define CPUTHERMAL_TARGET_FPS 120.0

static BOOL gForce120Hz = NO;
static BOOL gRefreshThermalProtection = YES;

@interface CADisplay : NSObject
+ (id)mainDisplay;
- (NSArray *)availableModes;
- (void)setPreferences:(id)preferences;
@end
@interface CADisplayPreferences : NSObject
- (void)setPreferredRefreshRate:(double)rate;
@end
@interface CAMutableDisplayPreferences : CADisplayPreferences @end
@interface CADynamicFrameRateSource : NSObject
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (CAFrameRateRange)preferredFrameRateRange;
@end
@interface CAFrameRateRangeGroup : NSObject
- (CAFrameRateRange)arbitratedRange;
@end

static BOOL CPUthermalBatteryAtLeast43C(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return NO;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("Temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!value) return NO;
    double c = [(__bridge id)value doubleValue]; CFRelease(value);
    if (c > 1000.0) c /= 100.0; else if (c > 100.0) c /= 10.0;
    return c >= 43.0;
}

static BOOL CPUthermalRefreshThermallyBlocked(void) {
    if (!gRefreshThermalProtection) return NO;
    NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
    return state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical || CPUthermalBatteryAtLeast43C();
}

static BOOL CPUthermalDeviceSupports120Hz(void) {
    static int cached = -1;
    if (cached >= 0) return cached == 1;
    cached = 0;
    @try {
        Class displayClass = NSClassFromString(S("CADisplay"));
        SEL mainSelector = NSSelectorFromString(S("mainDisplay"));
        id display = [displayClass respondsToSelector:mainSelector] ? ((id (*)(id, SEL))objc_msgSend)(displayClass, mainSelector) : nil;
        SEL modesSelector = NSSelectorFromString(S("availableModes"));
        NSArray *modes = [display respondsToSelector:modesSelector] ? ((id (*)(id, SEL))objc_msgSend)(display, modesSelector) : nil;
        for (id mode in modes) {
            id value = [mode valueForKey:S("refreshRate")];
            if ([value doubleValue] >= 119.0) { cached = 1; break; }
        }
        if (!cached && [UIScreen mainScreen].maximumFramesPerSecond >= 120) cached = 1;
    } @catch (__unused NSException *exception) {}
    return cached == 1;
}

static BOOL CPUthermalShouldForce120Hz(void) {
    return gForce120Hz && CPUthermalDeviceSupports120Hz() && !CPUthermalRefreshThermallyBlocked();
}

static CAFrameRateRange CPUthermalForcedRange(CAFrameRateRange original, BOOL fixedMinimum) {
    CAFrameRateRange range = original;
    range.minimum = fixedMinimum ? 120.0f : ((original.minimum > 0 && original.minimum <= 120.0f) ? original.minimum : 10.0f);
    range.maximum = 120.0f;
    range.preferred = 120.0f;
    return range;
}

static void CPUthermalApplyDisplayLink(CADisplayLink *link) {
    if (!link || !CPUthermalShouldForce120Hz()) return;
    link.preferredFrameRateRange = CAFrameRateRangeMake(10, 120, 120);
}

@interface CPUthermalRefreshDriver : NSObject
@property(nonatomic,strong) CADisplayLink *persistentLink;
@property(nonatomic,strong) NSTimer *thermalTimer;
+ (instancetype)sharedInstance;
- (void)reloadAndApply;
@end
@implementation CPUthermalRefreshDriver
+ (instancetype)sharedInstance { static id value; static dispatch_once_t once; dispatch_once(&once, ^{ value=[self new]; }); return value; }
- (instancetype)init { if((self=[super init])) _thermalTimer=[NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(thermalTick:) userInfo:nil repeats:YES]; return self; }
- (void)persistentTick:(CADisplayLink *)link { (void)link; }
- (void)thermalTick:(NSTimer *)timer { (void)timer; [self reloadAndApply]; }
- (void)reloadAndApply {
    BOOL active=CPUthermalShouldForce120Hz();
    if(gForce120Hz && !self.persistentLink){ self.persistentLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(persistentTick:)]; [self.persistentLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes]; }
    self.persistentLink.paused=!active;
    if(active) CPUthermalApplyDisplayLink(self.persistentLink);
}
@end

%hook UIScreen
- (NSInteger)maximumFramesPerSecond { return CPUthermalShouldForce120Hz() ? 120 : %orig; }
%end

%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link=%orig; CPUthermalApplyDisplayLink(link); return link;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if(CPUthermalShouldForce120Hz()) %orig(CPUthermalForcedRange(range, NO)); else %orig(range);
}
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if(CPUthermalShouldForce120Hz()) %orig(0); else %orig(fps);
}
- (void)setFrameInterval:(NSInteger)interval {
    if(CPUthermalShouldForce120Hz()) %orig(1); else %orig(interval);
}
%end

%hook CAMutableDisplayPreferences
- (void)setPreferredRefreshRate:(double)rate { %orig(CPUthermalShouldForce120Hz()?120.0:rate); }
%end
%hook CADisplayPreferences
- (void)setPreferredRefreshRate:(double)rate { %orig(CPUthermalShouldForce120Hz()?120.0:rate); }
%end
%hook CADisplay
- (void)setPreferences:(id)preferences {
    if(CPUthermalShouldForce120Hz() && preferences) @try { [preferences setValue:@120.0 forKey:S("preferredRefreshRate")]; } @catch(__unused NSException *e) {}
    %orig(preferences);
}
%end

%hook CAContext
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if(CPUthermalShouldForce120Hz()) %orig(CPUthermalForcedRange(range, NO)); else %orig(range);
}
- (void)setPreferredFrameRate:(float)rate { %orig(CPUthermalShouldForce120Hz()&&rate>=60.0f?120.0f:rate); }
%end

%hook CADynamicFrameRateSource
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if(CPUthermalShouldForce120Hz()) %orig(CPUthermalForcedRange(range, YES)); else %orig(range);
}
- (CAFrameRateRange)preferredFrameRateRange {
    CAFrameRateRange range=%orig; return CPUthermalShouldForce120Hz()?CPUthermalForcedRange(range,YES):range;
}
%end

%hook CAFrameRateRangeGroup
- (CAFrameRateRange)arbitratedRange {
    CAFrameRateRange range=%orig; return CPUthermalShouldForce120Hz()?CPUthermalForcedRange(range,YES):range;
}
%end

static void CPUthermalReloadRefreshPrefs(void) {
    BOOL force120=NO, protection=YES;
    if (!CPUthermalReadRefreshRateState(&force120, &protection)) {
        NSDictionary *prefs=CPUthermalReadPrefs()?:@{};
        force120=[prefs[S("force120HzEnable")] boolValue];
        id raw=prefs[S("refreshThermalProtectionEnabled")];
        protection=raw?[raw boolValue]:YES;
        CPUthermalPostRefreshRateState(force120, protection);
    }
    gForce120Hz=force120; gRefreshThermalProtection=protection;
    dispatch_async(dispatch_get_main_queue(), ^{ [[CPUthermalRefreshDriver sharedInstance] reloadAndApply]; });
}
static void CPUthermalRefreshPrefsChanged(CFNotificationCenterRef c,void *o,CFNotificationName n,const void *x,CFDictionaryRef u){ CPUthermalReloadRefreshPrefs(); }

%ctor {
    @autoreleasepool {
        CPUthermalReloadRefreshPrefs();
        CFNotificationCenterRef center=CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center,NULL,CPUthermalRefreshPrefsChanged,(__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,NULL,CPUthermalRefreshPrefsChanged,(__bridge CFStringRef)S(kCPUthermalRefreshRateNotifC),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
