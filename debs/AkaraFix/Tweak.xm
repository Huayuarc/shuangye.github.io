#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static CFTimeInterval AKRLastPresent = 0;
static CFTimeInterval AKRLastDismiss = 0;

static BOOL AKRDebounce(CFTimeInterval *stamp, CFTimeInterval interval) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - *stamp < interval) return NO;
    *stamp = now;
    return YES;
}

static NSArray<UIWindow *> *AKRAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    return windows;
}

static BOOL AKRIsAffordance(UIView *view, UIWindow *window) {
    NSString *name = NSStringFromClass(view.class);
    BOOL knownClass = [name containsString:@"SBBarSwipeAffordanceView"] ||
                      [name containsString:@"Grabber"] ||
                      [name containsString:@"Affordance"];
    if (!knownClass) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
    return CGRectGetMaxY(frame) >= screenH - 100.0 && frame.size.height <= 30.0;
}

static void AKRSetBottomAffordancesVisible(BOOL visible) {
    for (UIWindow *window in AKRAllWindows()) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        while (queue.count) {
            UIView *view = queue.lastObject;
            [queue removeLastObject];
            [queue addObjectsFromArray:view.subviews];
            if (view != window && AKRIsAffordance(view, window)) {
                [view.layer removeAllAnimations];
                view.alpha = visible ? 1.0 : 0.0;
                view.hidden = !visible;
            }
        }
    }
}

static void AKRCleanupAfterDismiss(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        AKRSetBottomAffordancesVisible(NO);
        for (UIWindow *window in AKRAllWindows()) {
            if ([NSStringFromClass(window.class) containsString:@"AkaraSecureWindow"] && window.alpha < 0.02) {
                window.hidden = YES;
            }
        }
    });
}

static BOOL AKRIsOneShot(UIGestureRecognizer *gesture) {
    return gesture.state == UIGestureRecognizerStateRecognized;
}

static void (*OrigHandleTop)(id, SEL, UIGestureRecognizer *);
static void FixHandleTop(id self, SEL cmd, UIGestureRecognizer *gesture) {
    // Pan 手势的 began/changed/ended 必须完整转发，避免破坏系统手势状态机。
    if (AKRIsOneShot(gesture) && !AKRDebounce(&AKRLastPresent, 0.45)) return;
    AKRSetBottomAffordancesVisible(YES);
    OrigHandleTop(self, cmd, gesture);
}

static void (*OrigDismissSwipe)(id, SEL, UIGestureRecognizer *);
static void FixDismissSwipe(id self, SEL cmd, UIGestureRecognizer *gesture) {
    if (AKRIsOneShot(gesture) && !AKRDebounce(&AKRLastDismiss, 0.45)) return;
    OrigDismissSwipe(self, cmd, gesture);
    UIGestureRecognizerState state = gesture.state;
    if (state == UIGestureRecognizerStateRecognized || state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
        AKRCleanupAfterDismiss();
    }
}

static void (*OrigDismissTap)(id, SEL, UIGestureRecognizer *);
static void FixDismissTap(id self, SEL cmd, UIGestureRecognizer *gesture) {
    if (!AKRDebounce(&AKRLastDismiss, 0.45)) return;
    OrigDismissTap(self, cmd, gesture);
    AKRCleanupAfterDismiss();
}

static void AKRHookSelector(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (cls && class_getInstanceMethod(cls, selector)) {
        MSHookMessageEx(cls, selector, replacement, original);
    }
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSArray<NSString *> *classes = @[@"CCUIModularControlCenterOverlayViewController",
                                         @"SBControlCenterController", @"SpringBoard"];
        for (NSString *className in classes) {
            Class cls = objc_getClass(className.UTF8String);
            if (!OrigHandleTop) AKRHookSelector(cls, NSSelectorFromString(@"handleAKRTopGesture:"), (IMP)FixHandleTop, (IMP *)&OrigHandleTop);
            if (!OrigDismissSwipe) AKRHookSelector(cls, NSSelectorFromString(@"handleAKRDismissSwipe:"), (IMP)FixDismissSwipe, (IMP *)&OrigDismissSwipe);
            if (!OrigDismissTap) AKRHookSelector(cls, NSSelectorFromString(@"handleAKRDismissTap:"), (IMP)FixDismissTap, (IMP *)&OrigDismissTap);
        }
    });
}
