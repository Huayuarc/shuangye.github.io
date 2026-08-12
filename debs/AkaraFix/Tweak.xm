#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static BOOL AKRTransitioning = NO;
static CFTimeInterval AKRLastAction = 0;
static const void *AKROriginalEnabledKey = &AKROriginalEnabledKey;

static BOOL AKRAcquireTransition(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (AKRTransitioning || now - AKRLastAction < 0.28) return NO;
    AKRTransitioning = YES;
    AKRLastAction = now;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 650 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        AKRTransitioning = NO;
    });
    return YES;
}

static BOOL AKRIsAkaraWindow(UIWindow *window) {
    if (!window) return NO;
    NSString *name = NSStringFromClass(window.class);
    return [name containsString:@"AkaraSecureWindow"];
}

static BOOL AKRIsResidualGrabber(UIView *view, UIWindow *window) {
    if (!view || !window || !AKRIsAkaraWindow(window)) return NO;
    NSString *name = NSStringFromClass(view.class);
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
    BOOL nearBottom = CGRectGetMaxY(frame) >= screenH - 90.0;
    BOOL lineShape = frame.size.height <= 20.0 && frame.size.width >= 28.0;
    BOOL grabberClass = [name containsString:@"Grabber"] || [name containsString:@"Affordance"] || [name containsString:@"Pill"];
    return nearBottom && (lineShape || grabberClass);
}

static void AKRRestoreGesturesAndRemoveLines(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!AKRIsAkaraWindow(window)) continue;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        while (queue.count) {
            UIView *view = queue.lastObject;
            [queue removeLastObject];
            [queue addObjectsFromArray:view.subviews];
            for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
                NSNumber *saved = objc_getAssociatedObject(gesture, AKROriginalEnabledKey);
                if (saved) {
                    gesture.enabled = saved.boolValue;
                    objc_setAssociatedObject(gesture, AKROriginalEnabledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            if (view != window && AKRIsResidualGrabber(view, window)) {
                [view.layer removeAllAnimations];
                [view removeFromSuperview];
            }
        }
        if (window.hidden || window.alpha < 0.02) {
            window.rootViewController = nil;
            window.hidden = YES;
        }
    }
    AKRTransitioning = NO;
}

static void AKRTemporarilyDisableCompetingGestures(UIGestureRecognizer *active) {
    UIView *root = active.view.window;
    if (!root) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *view = queue.lastObject;
        [queue removeLastObject];
        [queue addObjectsFromArray:view.subviews];
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture == active || !gesture.enabled) continue;
            NSString *target = NSStringFromClass(gesture.class);
            if ([target containsString:@"Swipe"] || [target containsString:@"Pan"] || [target containsString:@"ScreenEdge"]) {
                objc_setAssociatedObject(gesture, AKROriginalEnabledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                gesture.enabled = NO;
            }
        }
    }
}

static void (*OrigHandleTop)(id, SEL, UIGestureRecognizer *);
static void FixHandleTop(id self, SEL cmd, UIGestureRecognizer *gesture) {
    UIGestureRecognizerState state = gesture.state;
    if ((state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateRecognized) && !AKRAcquireTransition()) return;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateRecognized) AKRTemporarilyDisableCompetingGestures(gesture);
    OrigHandleTop(self, cmd, gesture);
    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed || state == UIGestureRecognizerStateRecognized) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ AKRRestoreGesturesAndRemoveLines(); });
    }
}

static void (*OrigDismissSwipe)(id, SEL, UIGestureRecognizer *);
static void FixDismissSwipe(id self, SEL cmd, UIGestureRecognizer *gesture) {
    UIGestureRecognizerState state = gesture.state;
    if (state == UIGestureRecognizerStateBegan && !AKRAcquireTransition()) return;
    OrigDismissSwipe(self, cmd, gesture);
    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed || state == UIGestureRecognizerStateRecognized) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ AKRRestoreGesturesAndRemoveLines(); });
    }
}

static void (*OrigDismissTap)(id, SEL, UIGestureRecognizer *);
static void FixDismissTap(id self, SEL cmd, UIGestureRecognizer *gesture) {
    if (!AKRAcquireTransition()) return;
    OrigDismissTap(self, cmd, gesture);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ AKRRestoreGesturesAndRemoveLines(); });
}

static void AKRHookSelector(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls && class_getInstanceMethod(cls, selector)) MSHookMessageEx(cls, selector, replacement, original);
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSArray<NSString *> *classes = @[@"CCUIModularControlCenterOverlayViewController", @"SBControlCenterController", @"SpringBoard"];
        for (NSString *className in classes) {
            Class cls = objc_getClass(className.UTF8String);
            if (!OrigHandleTop) AKRHookSelector(cls, NSSelectorFromString(@"handleAKRTopGesture:"), (IMP)FixHandleTop, (IMP *)&OrigHandleTop);
            if (!OrigDismissSwipe) AKRHookSelector(cls, NSSelectorFromString(@"handleAKRDismissSwipe:"), (IMP)FixDismissSwipe, (IMP *)&OrigDismissSwipe);
            if (!OrigDismissTap) AKRHookSelector(cls, NSSelectorFromString(@"handleAKRDismissTap:"), (IMP)FixDismissTap, (IMP *)&OrigDismissTap);
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { AKRRestoreGesturesAndRemoveLines(); }];
    });
}
