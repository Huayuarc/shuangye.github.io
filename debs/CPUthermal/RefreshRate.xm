#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#import <CPUthermalPaths.h>

static BOOL gForce120Hz = NO;
static BOOL gRefreshThermalProtection = YES;

static BOOL CPUthermalBatteryAtLeast43C(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return NO;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("Temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!value) return NO;
    double c = [(__bridge id)value doubleValue];
    CFRelease(value);
    if (c > 1000.0) c /= 100.0; else if (c > 100.0) c /= 10.0;
    return c >= 43.0;
}

static BOOL CPUthermalRefreshRateBlocked(void) {
    if (!gRefreshThermalProtection) return NO;
    NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
    return state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical || CPUthermalBatteryAtLeast43C();
}

static void CPUthermalSetFloat(id object, SEL selector, float value) {
    if (object && [object respondsToSelector:selector]) ((void (*)(id, SEL, float))objc_msgSend)(object, selector, value);
}
static void CPUthermalSetBool(id object, SEL selector, BOOL value) {
    if (object && [object respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

@interface CPUthermalRefreshDriver : NSObject
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) CALayer *driverLayer;
@property(nonatomic,strong) NSTimer *thermalTimer;
+ (instancetype)sharedInstance;
- (void)reloadAndApply;
@end

@implementation CPUthermalRefreshDriver
+ (instancetype)sharedInstance { static id instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance = [self new]; }); return instance; }
- (instancetype)init {
    if ((self = [super init])) {
        _driverLayer = [CALayer layer];
        _driverLayer.frame = CGRectMake(0, 0, 2, 2);
        _driverLayer.opacity = 0.01f;
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        _displayLink.paused = YES;
        _thermalTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(thermalTick:) userInfo:nil repeats:YES];
    }
    return self;
}
- (void)tick:(CADisplayLink *)link { (void)link; }
- (void)thermalTick:(NSTimer *)timer { (void)timer; if (gForce120Hz) [self reloadAndApply]; }
- (void)attachDriverLayer {
    if (self.driverLayer.superlayer) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) for (UIWindow *candidate in [UIApplication sharedApplication].windows) if (!candidate.hidden) { window = candidate; break; }
    if (window.layer) [window.layer addSublayer:self.driverLayer];
}
- (void)reloadAndApply {
    BOOL active = gForce120Hz && !CPUthermalRefreshRateBlocked();
    float hz = active ? 120.0f : 60.0f;
    self.displayLink.paused = !gForce120Hz;
    if (@available(iOS 15.0, *)) self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(hz, hz, hz);
    if (active) {
        [self attachDriverLayer];
        if (@available(iOS 15.0, *)) self.driverLayer.preferredFrameRateRange = CAFrameRateRangeMake(120, 120, 120);
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:S("opacity")];
        animation.fromValue = @0.01; animation.toValue = @0.011; animation.duration = 1.0;
        animation.repeatCount = INFINITY; animation.removedOnCompletion = NO;
        [self.driverLayer addAnimation:animation forKey:S("CPUthermal120HzDriver")];
    } else {
        [self.driverLayer removeAnimationForKey:S("CPUthermal120HzDriver")];
        [self.driverLayer removeFromSuperlayer];
    }
    Class serverClass = NSClassFromString(S("CAWindowServer"));
    SEL serverSelector = NSSelectorFromString(S("server"));
    id server = [serverClass respondsToSelector:serverSelector] ? ((id (*)(id, SEL))objc_msgSend)(serverClass, serverSelector) : nil;
    SEL displaysSelector = NSSelectorFromString(S("displays"));
    NSArray *displays = [server respondsToSelector:displaysSelector] ? ((id (*)(id, SEL))objc_msgSend)(server, displaysSelector) : nil;
    for (id display in [displays isKindOfClass:[NSArray class]] ? displays : @[]) {
        CPUthermalSetBool(display, NSSelectorFromString(S("setAllowsVirtualModes:")), YES);
        if (active) {
            CPUthermalSetFloat(display, NSSelectorFromString(S("setMinimumRefreshRate:")), 120.0f);
            CPUthermalSetFloat(display, NSSelectorFromString(S("setMaximumRefreshRate:")), 120.0f);
            CPUthermalSetFloat(display, NSSelectorFromString(S("setIdealRefreshRate:")), 120.0f);
        } else if (!gForce120Hz) {
            CPUthermalSetFloat(display, NSSelectorFromString(S("setMinimumRefreshRate:")), 0.0f);
            CPUthermalSetFloat(display, NSSelectorFromString(S("setMaximumRefreshRate:")), 120.0f);
            CPUthermalSetFloat(display, NSSelectorFromString(S("setIdealRefreshRate:")), 0.0f);
        }
    }
}
@end

static void CPUthermalReloadRefreshPrefs(void) {
    NSDictionary *prefs = CPUthermalReadPrefs() ?: @{};
    gForce120Hz = [prefs[S("force120HzEnable")] boolValue];
    id protection = prefs[S("refreshThermalProtectionEnabled")];
    gRefreshThermalProtection = protection ? [protection boolValue] : YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [[CPUthermalRefreshDriver sharedInstance] reloadAndApply]; });
}

static void CPUthermalRefreshPrefsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    CPUthermalReloadRefreshPrefs();
}

%ctor {
    @autoreleasepool {
        CPUthermalReloadRefreshPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CPUthermalRefreshPrefsChanged,
            (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
