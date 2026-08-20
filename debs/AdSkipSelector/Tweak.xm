#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "SharedPrefs.h"

#ifdef ADSKIP_STRIP_LOGS
#define NSLog(...) do {} while (0)
#endif

static BOOL gEnabled = NO;
static BOOL gScanning = NO;
static CFTimeInterval gStartedAt = 0;

static void ASPReload(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    gEnabled = bid.length && [ASPEnabledBundleIDs() containsObject:bid];
    if (gEnabled && gStartedAt == 0) gStartedAt = CACurrentMediaTime();
}

static BOOL ASPRelevantText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString *s = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!s.length || s.length > 24) return NO;
    NSArray *exact = @[@"跳过", @"跳过广告", @"关闭广告", @"关闭", @"skip", @"skip ad", @"close", @"×", @"✕", @"✖"];
    if ([exact containsObject:s]) return YES;
    return ([s containsString:@"跳过"] || [s hasPrefix:@"skip"] || [s isEqualToString:@"广告关闭"]);
}

static NSString *ASPViewText(UIView *v) {
    if ([v isKindOfClass:UIButton.class]) {
        UIButton *b = (UIButton *)v;
        return [b titleForState:UIControlStateNormal] ?: b.accessibilityLabel;
    }
    if ([v isKindOfClass:UILabel.class]) return ((UILabel *)v).text ?: v.accessibilityLabel;
    return v.accessibilityLabel ?: v.accessibilityValue;
}

static BOOL ASPVisible(UIView *v) {
    if (!v.window || v.hidden || v.alpha < 0.05 || !v.userInteractionEnabled) return NO;
    CGRect r = [v convertRect:v.bounds toView:nil];
    return !CGRectIsEmpty(r) && CGRectIntersectsRect(UIScreen.mainScreen.bounds, r);
}

static BOOL ASPActivate(UIView *v) {
    if (!ASPVisible(v)) return NO;
    if ([v isKindOfClass:UIControl.class]) {
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        if (g.enabled) {
            id target = nil;
            @try { target = [g valueForKey:@"_targets"]; } @catch (__unused NSException *e) {}
            for (id wrapper in [target isKindOfClass:NSArray.class] ? target : @[]) {
                id t = nil; SEL a = NULL;
                @try { t = [wrapper valueForKey:@"target"]; a = NSSelectorFromString([wrapper valueForKey:@"action"]); } @catch (__unused NSException *e) {}
                if (t && a && [t respondsToSelector:a]) { ((void(*)(id,SEL,id))objc_msgSend)(t,a,g); return YES; }
            }
        }
    }
    if ([v accessibilityActivate]) return YES;
    return v.superview ? ASPActivate(v.superview) : NO;
}

static UIView *ASPFindCandidate(UIView *root) {
    if (!root || !ASPVisible(root)) return nil;
    if (ASPRelevantText(ASPViewText(root))) return root;
    NSArray<UIView *> *children = [root.subviews sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return CGRectGetMaxX(a.frame) > CGRectGetMaxX(b.frame) ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIView *v in children) { UIView *hit = ASPFindCandidate(v); if (hit) return hit; }
    return nil;
}

static void ASPScan(void) {
    if (!gEnabled || gScanning || CACurrentMediaTime() - gStartedAt > 15.0) return;
    gScanning = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
            UIView *candidate = ASPFindCandidate(w);
            if (candidate && ASPActivate(candidate)) break;
        }
        gScanning = NO;
    });
}

static void ASPScheduleScan(void) {
    if (!gEnabled) return;
    for (NSNumber *delay in @[@0.15, @0.5, @1.0, @2.0, @3.5, @5.0, @7.5, @10.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ASPScan(); });
    }
}

static void ASPPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{ ASPReload(); ASPScheduleScan(); });
}

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (gEnabled && self.window && (ASPRelevantText(ASPViewText(self)) || [NSStringFromClass(self.class).lowercaseString containsString:@"splash"] || [NSStringFromClass(self.class).lowercaseString containsString:@"launchad"])) ASPScan();
}
%end

%hook UILabel
- (void)setText:(NSString *)text { %orig; if (gEnabled && ASPRelevantText(text)) ASPScan(); }
- (void)setAttributedText:(NSAttributedString *)text { %orig; if (gEnabled && ASPRelevantText(text.string)) ASPScan(); }
%end

%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state { %orig; if (gEnabled && ASPRelevantText(title)) ASPScan(); }
%end

%ctor {
    @autoreleasepool {
        ASPReload();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, ASPPrefsChanged, (__bridge CFStringRef)ASPChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        if (gEnabled) {
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ gStartedAt = CACurrentMediaTime(); ASPScheduleScan(); }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ gStartedAt = CACurrentMediaTime(); ASPScheduleScan(); }];
            ASPScheduleScan();
        }
    }
}
