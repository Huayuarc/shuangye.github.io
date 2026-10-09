#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CPUthermalPaths.h>

// All policy and weak tracking run on the main thread. Off-main calls pass through.
// Private additions are ABI-checked and event driven; capability getters stay native.
typedef NS_ENUM(NSUInteger, CPUthermalRateAPI) {
    CPUthermalRateRange, CPUthermalRateFPS, CPUthermalRateInterval
};
@interface CPUthermalLinkState : NSObject
@property(nonatomic) CPUthermalRateAPI api;
@property(nonatomic) CAFrameRateRange range;
@property(nonatomic) NSInteger fps;
@property(nonatomic) NSInteger interval;
@property(nonatomic) NSUInteger depth;
@property(nonatomic) BOOL forced;
@end
@implementation CPUthermalLinkState
@end

static NSMapTable<CADisplayLink *, CPUthermalLinkState *> *gLinks;
static BOOL gForce120Hz;
static BOOL gIsSpringBoard, gRateLogging, gScreenReady, gScreenUnlocked;
static BOOL gAppSuspended;
static __weak UIScreen *gCapabilityScreen;
static BOOL gSupports120;
static NSUInteger gCapabilityAttempts;

static BOOL CPUthermalDeviceSupports120Hz(void) {
    UIScreen *screen = UIScreen.mainScreen;
    if (!screen) return NO;
    if (gCapabilityScreen != screen) {
        gCapabilityScreen = screen;
        gSupports120 = NO;
        gCapabilityAttempts = 0;
    }
    // Original public getter is NEVER hooked. A transient negative is retried
    // on at most four real events per foreground/settings epoch, not forever.
    if (!gSupports120 && gCapabilityAttempts < 4) {
        ++gCapabilityAttempts;
        gSupports120 = screen.maximumFramesPerSecond >= 120;
    }
    return gSupports120;
}
static BOOL CPUthermalShouldForce120Hz(void) {
    return NSThread.isMainThread && !gAppSuspended && gScreenReady && gScreenUnlocked
        && gForce120Hz && UIApplication.sharedApplication.applicationState == UIApplicationStateActive
        && CPUthermalDeviceSupports120Hz();
}
static CPUthermalLinkState *CPUthermalTrack(CADisplayLink *link) {
    if (!NSThread.isMainThread || !link) return nil;
    CPUthermalLinkState *state = [gLinks objectForKey:link];
    if (!state && (!gForce120Hz || !gSupports120 || !gScreenReady || !gScreenUnlocked || gAppSuspended)) return nil;
    if (!gLinks) gLinks = [NSMapTable weakToStrongObjectsMapTable];
    if (!state) {
        state = [CPUthermalLinkState new];
        // Before our first write, preserve the SDK default/actual range.
        state.api = CPUthermalRateRange;
        state.range = link.preferredFrameRateRange;
        [gLinks setObject:state forKey:link];
    }
    return state;
}
static void CPUthermalApply(CADisplayLink *link, CPUthermalLinkState *state, BOOL active) {
    if (!state || state.depth) return;
    ++state.depth; // Covers internal cross-API setter calls, including restore.
    if (active) {
        link.preferredFrameRateRange = CAFrameRateRangeMake(120, 120, 120);
        state.forced = YES;
    } else if (state.forced) {
        // Most recent EXPLICIT app setter wins. Never restore via several APIs:
        // their ordering would overwrite the app's chosen API semantics.
        switch (state.api) {
            case CPUthermalRateRange: link.preferredFrameRateRange = state.range; break;
            case CPUthermalRateFPS: link.preferredFramesPerSecond = state.fps; break;
            case CPUthermalRateInterval: link.frameInterval = state.interval; break;
        }
        state.forced = NO;
    }
    --state.depth;
}
static void CPUthermalRefreshTracked(BOOL resetCapability) {
    if (resetCapability) gCapabilityAttempts = 0;
    BOOL active = CPUthermalShouldForce120Hz();
    for (CADisplayLink *link in gLinks.keyEnumerator.allObjects) {
        CPUthermalApply(link, [gLinks objectForKey:link], active);
    }
}

#include "RefreshRatePolicy.inc"
#include "RefreshRateUIHooks.inc"

%group CPUthermalDisplayLinkHooks
%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link;
    link = %orig;
    // Do not replace target/selector or observe every callback.
    if (NSThread.isMainThread) {
        CPUthermalApply(link, CPUthermalTrack(link), CPUthermalShouldForce120Hz());
    }
    return link;
}
- (void)addToRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode {
    %orig(runLoop, mode);
    if (NSThread.isMainThread) {
        CPUthermalApply(self, CPUthermalTrack(self), CPUthermalShouldForce120Hz());
    }
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    CPUthermalLinkState *state = CPUthermalTrack(self);
    if (!state || state.depth) {
        %orig(range);
        return;
    }
    state.api = CPUthermalRateRange;
    state.range = range;
    ++state.depth;
    %orig(range);
    --state.depth;
    CPUthermalApply(self, state, CPUthermalShouldForce120Hz());
}
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    CPUthermalLinkState *state = CPUthermalTrack(self);
    if (!state || state.depth) {
        %orig(fps);
        return;
    }
    state.api = CPUthermalRateFPS;
    state.fps = fps;
    ++state.depth;
    %orig(fps);
    --state.depth;
    CPUthermalApply(self, state, CPUthermalShouldForce120Hz());
}
- (void)setFrameInterval:(NSInteger)interval {
    CPUthermalLinkState *state = CPUthermalTrack(self);
    if (!state || state.depth) {
        %orig(interval);
        return;
    }
    state.api = CPUthermalRateInterval;
    state.interval = interval;
    ++state.depth;
    %orig(interval);
    --state.depth;
    CPUthermalApply(self, state, CPUthermalShouldForce120Hz());
}
- (void)invalidate {
    if (NSThread.isMainThread) [gLinks removeObjectForKey:self];
    %orig;
}
%end
%end

static BOOL CPUthermalDisplayLinkABIValid(void) {
    Class cls = NSClassFromString(@"CADisplayLink");
    if (!cls) return NO;
    NSString *integer = [NSString stringWithUTF8String:@encode(NSInteger)];
    return CPUthermalExactMethod(class_getClassMethod(cls, @selector(displayLinkWithTarget:selector:)), "@", @[@"@", @":", @"@", @":"]) &&
        CPUthermalExactMethod(class_getInstanceMethod(cls, @selector(addToRunLoop:forMode:)), "v", @[@"@", @":", @"@", @"@"]) &&
        CPUthermalExactMethod(class_getInstanceMethod(cls, @selector(setPreferredFrameRateRange:)), "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]]) &&
        CPUthermalExactMethod(class_getInstanceMethod(cls, @selector(setPreferredFramesPerSecond:)), "v", @[@"@", @":", integer]) &&
        CPUthermalExactMethod(class_getInstanceMethod(cls, @selector(setFrameInterval:)), "v", @[@"@", @":", integer]) &&
        CPUthermalExactMethod(class_getInstanceMethod(cls, @selector(invalidate)), "v", @[@"@", @":"]);
}
static void CPUthermalReloadRefreshPrefs(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *prefs = CPUthermalReadPrefs();
        gForce120Hz = [prefs[S("force120HzEnable")] boolValue];
        gRateLogging = [prefs[S("loggingEnabled")] boolValue];
        CPUthermalInstallPrivateRateHooks();
        CPUthermalRateLifecycle();
    });
}
static void CPUthermalRefreshPrefsChanged(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *x, CFDictionaryRef u) {
    CPUthermalReloadRefreshPrefs();
}
%ctor {
    @autoreleasepool {
        if (CPUthermalDisplayLinkABIValid()) {
            %init(CPUthermalDisplayLinkHooks);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ CPUthermalSetupRateLifecycle(); CPUthermalRateLifecycle(); });
        CPUthermalReloadRefreshPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            CPUthermalRefreshPrefsChanged, (__bridge CFStringRef)S(kCPUthermalSettingsChangedNotifC),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        // Process-lifetime notification tokens; one keepalive only in SpringBoard.
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidFinishLaunchingNotification,
                UIApplicationDidEnterBackgroundNotification, UIApplicationWillResignActiveNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    // SpringBoard's UIApplication state is not the device display state.
                    if (!gIsSpringBoard) {
                        if ([notification.name isEqualToString:UIApplicationWillResignActiveNotification] ||
                            [notification.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) gAppSuspended = YES;
                        else gAppSuspended = NO;
                    }
                    CPUthermalInstallPrivateRateHooks();
                    CPUthermalRateLifecycle();
                }];
        }
    }
}
