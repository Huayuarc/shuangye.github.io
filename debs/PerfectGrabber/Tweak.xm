#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PGGrabberHUDView.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"

static const void *PGOverlayAssociationKey = &PGOverlayAssociationKey;
static __weak id PGActiveOverlayGrabber;
static PGGrabberHUDView *PGGlobalHUD;
static __weak UIWindow *PGGlobalHUDWindow;
static NSUInteger PGGlobalHUDGeneration;
static NSTimeInterval PGGlobalHUDDeadline;

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

static void PGHideNativeTongueChrome(id grabber) {
    // The original top tongue remains alive after _willPresent and otherwise leaves
    // the pale rectangle visible behind our detached media card.
    for (NSString *name in @[@"_tongueChevron", @"_tongueBackdropView", @"_backdropView",
                             @"_backgroundView", @"_materialView"] ) {
        UIView *view = PGFirstView(grabber, @[name]);
        if (!view) continue;
        view.hidden = YES;
        view.alpha = 0.0;
    }
}

static void PGHideChevron(id grabber) {
    PGHideNativeTongueChrome(grabber);
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
static void PGHideHUD(void);

static void PGHideOverlay(id grabber) {
    PGGrabberOverlayView *overlay = PGOverlayForGrabber(grabber, NO);
    [overlay stopUpdating];
    [overlay removeFromSuperview];
    objc_setAssociatedObject(grabber, PGOverlayAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (PGActiveOverlayGrabber == grabber) PGActiveOverlayGrabber = nil;
}

static void PGHideHUD(void) {
    PGGlobalHUDGeneration++;
    PGGlobalHUDDeadline = 0;
    [PGGlobalHUD stopUpdating];
    [PGGlobalHUD removeFromSuperview];
    PGGlobalHUD.interactionHandler = nil;
    PGGlobalHUD = nil;
    PGGlobalHUDWindow = nil;
}

static void PGCheckHUDHideDeadline(NSUInteger generation) {
    if (generation != PGGlobalHUDGeneration || !PGGlobalHUD) return;
    NSTimeInterval remaining = PGGlobalHUDDeadline - NSProcessInfo.processInfo.systemUptime;
    if (remaining > 0.01) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PGCheckHUDHideDeadline(generation); });
        return;
    }
    PGHideHUD();
}

static void PGScheduleHUDHide(void) {
    [PerfectGrabberPreferences.sharedPreferences reload];
    NSTimeInterval delay = PerfectGrabberPreferences.sharedPreferences.autoCloseDelay;
    if (delay < 1.0 || delay > 6.0) delay = 6.0;
    NSUInteger generation = ++PGGlobalHUDGeneration;
    PGGlobalHUDDeadline = NSProcessInfo.processInfo.systemUptime + delay;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ PGCheckHUDHideDeadline(generation); });
}

static void PGShowHUD(id grabber) {
    [PerfectGrabberPreferences.sharedPreferences reload];
    UIView *tongue = PGTongueView(grabber);
    UIWindow *window = tongue.window;
    if (!window) return;
    if (PGActiveOverlayGrabber && PGActiveOverlayGrabber != grabber) PGHideOverlay(PGActiveOverlayGrabber);
    PGHideChevron(grabber);

    if (PGGlobalHUD && PGGlobalHUDWindow != window) PGHideHUD();
    if (!PGGlobalHUD) {
        PGGlobalHUD = [[PGGrabberHUDView alloc] initWithFrame:window.bounds];
        PGGlobalHUD.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        PGGlobalHUD.userInteractionEnabled = YES;
        [window addSubview:PGGlobalHUD];
        PGGlobalHUDWindow = window;
    }
    PGGlobalHUD.frame = window.bounds;
    [window bringSubviewToFront:PGGlobalHUD];
    PGGlobalHUD.interactionHandler = ^{ PGScheduleHUDHide(); };
    [PGGlobalHUD startUpdating];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) {
        AudioServicesPlaySystemSound(1519);
    }
    PGScheduleHUDHide();
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
        // Bottom-edge swipe-up never owns the top media card. Do not let a reused
        // or misclassified grabber instance shorten the global HUD deadline.
        PGHideOverlay(self);
        return;
    }
    PGHideOverlay(self);
    if (preferences.showOnSwipeUp) PGShowHUD(self);
}

- (void)_willDismiss {
    BOOL handled = PGOverlayForGrabber(self, NO) != nil;
    if (handled) {
        PGHideChevron(self);
        PGHideOverlay(self);
    }
    %orig;
    if (PGGlobalHUD) {
        PGHideNativeTongueChrome(self);
        dispatch_async(dispatch_get_main_queue(), ^{ PGHideNativeTongueChrome(self); });
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
