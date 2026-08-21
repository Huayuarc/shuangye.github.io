#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PGGrabberHUDView.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"

static const void *PGOverlayAssociationKey = &PGOverlayAssociationKey;
static const void *PGHUDAssociationKey = &PGHUDAssociationKey;
static __weak id PGActiveOverlayGrabber;
static __weak id PGActiveHUDGrabber;

static id PGObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (ivar) return object_getIvar(object, ivar);

    @try {
        return [object valueForKey:[NSString stringWithUTF8String:name]];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIView *PGFirstView(id grabber, NSArray<NSString *> *ivarNames) {
    for (NSString *name in ivarNames) {
        id candidate = PGObjectIvar(grabber, name.UTF8String);
        if ([candidate isKindOfClass:UIView.class]) return candidate;
    }
    return nil;
}

static UIView *PGTongueView(id grabber) {
    UIView *view = PGFirstView(grabber, @[@"_tongueContainer", @"_tongueBackdropView", @"_containingView"]);
    return view ?: ([grabber isKindOfClass:UIView.class] ? grabber : nil);
}

static void PGHideChevron(id grabber) {
    UIView *chevron = PGFirstView(grabber, @[@"_tongueChevron"]);
    if (chevron) chevron.hidden = YES;
}

static BOOL PGIsSwipeUpGrabber(id grabber) {
    // Edge fields are scalar enums on some iOS builds. Use KVC so scalars are boxed
    // instead of reading them through object_getIvar as if they were Objective-C objects.
    for (NSString *key in @[@"edge", @"grabberEdge", @"screenEdge", @"edgeLocation", @"displayEdge"]) {
        id value = nil;
        @try {
            value = [grabber valueForKey:key];
        } @catch (__unused NSException *exception) {
            value = nil;
        }
        if (![value respondsToSelector:@selector(integerValue)]) continue;
        NSInteger edge = [value integerValue];
        if (edge == UIRectEdgeBottom) return YES;
        if (edge == UIRectEdgeTop) return NO;
    }

    NSArray<NSString *> *names = @[@"_tongueBackdropView", @"_tongueChevron", @"_tongueContainer",
                                   @"_containingView"];
    for (NSString *name in names) {
        UIView *marker = PGFirstView(grabber, @[name]);
        UIWindow *window = marker.window;
        if (!marker || !window) continue;
        CGRect markerFrame = [marker convertRect:marker.bounds toView:window];
        CGFloat topDistance = CGRectGetMinY(markerFrame);
        CGFloat bottomDistance = CGRectGetHeight(window.bounds) - CGRectGetMaxY(markerFrame);
        if (bottomDistance + 20.0 < topDistance) return YES;
        if (topDistance + 20.0 < bottomDistance) return NO;
    }

    if ([grabber isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)grabber;
        UIWindow *window = view.window;
        if (window) {
            CGRect frame = [view convertRect:view.bounds toView:window];
            CGFloat topDistance = CGRectGetMinY(frame);
            CGFloat bottomDistance = CGRectGetHeight(window.bounds) - CGRectGetMaxY(frame);
            if (bottomDistance + 20.0 < topDistance) return YES;
        }
    }
    return NO;
}

static void PGLayoutOverlay(id grabber, PGGrabberOverlayView *overlay) {
    UIView *host = overlay.superview;
    if (!host) return;
    overlay.frame = host.bounds;
    overlay.layer.cornerRadius = MIN(12.0, CGRectGetHeight(host.bounds) / 2.0);
}

static PGGrabberOverlayView *PGOverlayForGrabber(id grabber, BOOL create) {
    PGGrabberOverlayView *overlay = objc_getAssociatedObject(grabber, PGOverlayAssociationKey);
    if (!overlay && create) {
        UIView *host = PGTongueView(grabber);
        if (!host) return nil;
        overlay = [[PGGrabberOverlayView alloc] initWithFrame:CGRectZero];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:overlay];
        PGHideChevron(grabber);
        PGLayoutOverlay(grabber, overlay);
        objc_setAssociatedObject(grabber, PGOverlayAssociationKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return overlay;
}

static void PGHideOverlay(id grabber);
static void PGHideHUD(id grabber);

static void PGShowOverlay(id grabber) {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (!preferences.isEnabled) return;
    if (!preferences.showOnSwipeUp && PGIsSwipeUpGrabber(grabber)) return;

    if (PGActiveHUDGrabber && PGActiveHUDGrabber != grabber) PGHideHUD(PGActiveHUDGrabber);
    PGActiveOverlayGrabber = grabber;

    PGGrabberOverlayView *overlay = PGOverlayForGrabber(grabber, YES);
    if (!overlay) return;
    PGHideChevron(grabber);
    PGLayoutOverlay(grabber, overlay);
    dispatch_async(dispatch_get_main_queue(), ^{
        PGLayoutOverlay(grabber, overlay);
    });
    overlay.hidden = NO;
    overlay.alpha = 1.0;
    [overlay startUpdating];
    if (preferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
}

static void PGHideOverlay(id grabber) {
    PGGrabberOverlayView *overlay = PGOverlayForGrabber(grabber, NO);
    [overlay stopUpdating];
    [overlay removeFromSuperview];
    objc_setAssociatedObject(grabber, PGOverlayAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (PGActiveOverlayGrabber == grabber) PGActiveOverlayGrabber = nil;
}

static void PGHideHUD(id grabber) {
    PGGrabberHUDView *hud = objc_getAssociatedObject(grabber, PGHUDAssociationKey);
    if (!hud) return;
    [hud stopUpdating];
    [hud removeFromSuperview];
    objc_setAssociatedObject(grabber, PGHUDAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (PGActiveHUDGrabber == grabber) PGActiveHUDGrabber = nil;
}

static void PGShowHUD(id grabber) {
    PGGrabberHUDView *hud = objc_getAssociatedObject(grabber, PGHUDAssociationKey);
    UIView *tongue = PGTongueView(grabber);
    UIWindow *window = tongue.window;
    if (!window) return;
    if (PGActiveOverlayGrabber && PGActiveOverlayGrabber != grabber) PGHideOverlay(PGActiveOverlayGrabber);
    PGActiveHUDGrabber = grabber;
    if (!hud) {
        hud = [[PGGrabberHUDView alloc] initWithFrame:window.bounds];
        hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        hud.userInteractionEnabled = YES;
        [window addSubview:hud];
        objc_setAssociatedObject(grabber, PGHUDAssociationKey, hud, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    hud.frame = window.bounds;
    [window bringSubviewToFront:hud];
    [hud startUpdating];
    // Keep the interactive media HUD visible long enough to select a track.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(grabber, PGHUDAssociationKey) == hud) {
            PGHideHUD(grabber);
        }
    });
}

%group PerfectGrabberHooks

%hook SBGrabberTongue

- (void)_willPresent {
    %orig;
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    [preferences reload];
    if (!preferences.isEnabled) return;
    BOOL swipeUp = PGIsSwipeUpGrabber(self);
    if (swipeUp) {
        PGHideOverlay(self);
        if (preferences.showOnSwipeUp) PGShowHUD(self);
        return;
    }
    PGHideHUD(self);
    PGShowOverlay(self);
}

- (void)_willDismiss {
    BOOL handled = PGOverlayForGrabber(self, NO) != nil;
    if (handled) {
        PGHideChevron(self);
        PGHideOverlay(self);
    }
    %orig;
    PGHideHUD(self);
    if (handled) {
        PGHideChevron(self);
        dispatch_async(dispatch_get_main_queue(), ^{
            PGHideChevron(self);
        });
    }
}

%end

%end

static void PGPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PerfectGrabberPreferences.sharedPreferences reload];
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
        [PerfectGrabberPreferences.sharedPreferences reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PGPreferencesChanged,
                                        (__bridge CFStringRef)PGPreferencesChangedNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        Class grabberClass = NSClassFromString(@"SBGrabberTongue");
        if (grabberClass && class_getInstanceMethod(grabberClass, @selector(_willPresent)) &&
            class_getInstanceMethod(grabberClass, @selector(_willDismiss))) {
            %init(PerfectGrabberHooks, SBGrabberTongue = grabberClass);
        }
    }
}
