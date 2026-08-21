#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <IOKit/hid/IOHIDEvent.h>
#import "SharedPrefs.h"

#ifdef ADSKIP_STRIP_LOGS
#define NSLog(...) do {} while (0)
#endif

static BOOL gEnabled = NO, gScanning = NO, gOCRBusy = NO;
static CFTimeInterval gStartedAt = 0, gLastOCR = 0;
static NSUInteger gScanGeneration = 0;
static const NSTimeInterval kScanDuration = 25.0;

static void ASPReload(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    gEnabled = bid.length && [ASPEnabledBundleIDs() containsObject:bid];
}

static NSString *ASPNormalize(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *s = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
}

static NSInteger ASPTextScore(NSString *text) {
    NSString *s = ASPNormalize(text);
    if (!s.length || s.length > 40) return 0;
    if ([s containsString:@"跳过广告"] || [s containsString:@"跳过"] || [s containsString:@"略过"]) return 120;
    if ([s hasPrefix:@"skip"] || [s containsString:@"skipad"]) return 120;
    if ([s isEqualToString:@"关闭广告"] || [s isEqualToString:@"关闭"] || [s isEqualToString:@"close"]) return 85;
    if ([s isEqualToString:@"×"] || [s isEqualToString:@"✕"] || [s isEqualToString:@"✖"] || [s isEqualToString:@"x"]) return 70;
    return 0;
}

static NSString *ASPViewText(UIView *v) {
    NSMutableArray *parts = [NSMutableArray array];
    if ([v isKindOfClass:UIButton.class]) {
        UIButton *b = (UIButton *)v;
        for (id x in @[[b titleForState:UIControlStateNormal] ?: @"", b.currentTitle ?: @""]) if ([x length]) [parts addObject:x];
    }
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length) [parts addObject:l.text];
        if (l.attributedText.string.length) [parts addObject:l.attributedText.string];
    }
    if ([v respondsToSelector:@selector(text)]) {
        @try { NSString *t = [v valueForKey:@"text"]; if ([t isKindOfClass:NSString.class] && t.length) [parts addObject:t]; } @catch (__unused NSException *e) {}
    }
    for (NSString *t in @[v.accessibilityLabel ?: @"", v.accessibilityValue ?: @"", v.accessibilityHint ?: @""]) if (t.length) [parts addObject:t];
    return [parts componentsJoinedByString:@" "];
}

static BOOL ASPActuallyVisible(UIView *v) {
    if (!v || !v.window || v.hidden || v.alpha < 0.05) return NO;
    CGRect r = [v convertRect:v.bounds toView:v.window];
    return !CGRectIsEmpty(r) && !CGRectIsNull(r) && CGRectIntersectsRect(v.window.bounds, r);
}

static BOOL ASPInvokeGestures(UIView *v) {
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        if (!g.enabled) continue;
        NSArray *targets = nil;
        @try { targets = [g valueForKey:@"_targets"]; } @catch (__unused NSException *e) {}
        for (id wrapper in [targets isKindOfClass:NSArray.class] ? targets : @[]) {
            id target = nil; NSString *action = nil;
            @try { target = [wrapper valueForKey:@"target"]; action = [wrapper valueForKey:@"action"]; } @catch (__unused NSException *e) {}
            SEL sel = [action isKindOfClass:NSString.class] ? NSSelectorFromString(action) : NULL;
            if (target && sel && [target respondsToSelector:sel]) {
                ((void(*)(id,SEL,id))objc_msgSend)(target, sel, g);
                return YES;
            }
        }
    }
    return NO;
}

static BOOL ASPActivate(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if (!ASPActuallyVisible(v)) continue;
        if ([v isKindOfClass:UIControl.class] && ((UIControl *)v).enabled) {
            [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if (ASPInvokeGestures(v)) return YES;
        if (v.isAccessibilityElement && [v accessibilityActivate]) return YES;
    }
    return view && [view accessibilityActivate];
}

static NSInteger ASPCandidateScore(UIView *v) {
    NSInteger score = ASPTextScore(ASPViewText(v));
    if (!score) return 0;
    CGRect r = [v convertRect:v.bounds toView:v.window];
    CGSize s = v.window.bounds.size;
    if (CGRectGetMidX(r) > s.width * 0.55) score += 20;
    if (CGRectGetMidY(r) < s.height * 0.35) score += 20;
    if ([v isKindOfClass:UIControl.class]) score += 20;
    NSString *c = NSStringFromClass(v.class).lowercaseString;
    if ([c containsString:@"skip"] || [c containsString:@"close"] || [c containsString:@"splash"] || [c containsString:@"advert"]) score += 30;
    if (v.userInteractionEnabled || v.gestureRecognizers.count) score += 10;
    return score;
}

static void ASPCollectBest(UIView *root, UIView **best, NSInteger *bestScore) {
    if (!ASPActuallyVisible(root)) return;
    NSInteger score = ASPCandidateScore(root);
    if (score > *bestScore) { *best = root; *bestScore = score; }
    for (UIView *child in root.subviews) ASPCollectBest(child, best, bestScore);
}

typedef IOHIDEventRef (*ASPCreateDigitizerEventFn)(CFAllocatorRef, AbsoluteTime, IOHIDDigitizerTransducerType, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, IOOptionBits);
typedef IOHIDEventRef (*ASPCreateFingerEventFn)(CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, IOOptionBits);
typedef void (*ASPAppendEventFn)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);

static BOOL ASPHIDTap(UIWindow *window, CGPoint point) {
    static ASPCreateDigitizerEventFn createDigitizer = NULL;
    static ASPCreateFingerEventFn createFinger = NULL;
    static ASPAppendEventFn appendEvent = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (h) {
            createDigitizer = (ASPCreateDigitizerEventFn)dlsym(h, "IOHIDEventCreateDigitizerEvent");
            createFinger = (ASPCreateFingerEventFn)dlsym(h, "IOHIDEventCreateDigitizerFingerEventWithQuality");
            appendEvent = (ASPAppendEventFn)dlsym(h, "IOHIDEventAppendEvent");
        }
    });
    if (!window || !createDigitizer || !createFinger || !appendEvent) return NO;
    UIApplication *app = UIApplication.sharedApplication;
    SEL handle = NSSelectorFromString(@"_handleHIDEvent:");
    if (![app respondsToSelector:handle]) return NO;
    CGSize size = window.bounds.size;
    double nx = size.width > 0 ? point.x / size.width : 0;
    double ny = size.height > 0 ? point.y / size.height : 0;
    AbsoluteTime ts = {0};
    uint64_t raw = mach_absolute_time();
    memcpy(&ts, &raw, MIN(sizeof(ts), sizeof(raw)));
    const uint32_t eventMask = 3; // range + touch
    @try {
        IOHIDEventRef down = createDigitizer(kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 0, eventMask, 0, nx, ny, 0, 0, 0, true, true, 0);
        IOHIDEventRef fingerDown = createFinger(kCFAllocatorDefault, ts, 1, 2, eventMask, nx, ny, 0, 1, 0, 5, 5, 1, 1, true, true, 0);
        if (!down || !fingerDown) { if (down) CFRelease(down); if (fingerDown) CFRelease(fingerDown); return NO; }
        appendEvent(down, fingerDown, 0);
        ((void(*)(id,SEL,IOHIDEventRef))objc_msgSend)(app, handle, down);
        CFRelease(fingerDown); CFRelease(down);
        raw += 30000000;
        memcpy(&ts, &raw, MIN(sizeof(ts), sizeof(raw)));
        IOHIDEventRef up = createDigitizer(kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 0, 0, 0, nx, ny, 0, 0, 0, false, false, 0);
        IOHIDEventRef fingerUp = createFinger(kCFAllocatorDefault, ts, 1, 2, 0, nx, ny, 0, 0, 0, 5, 5, 1, 1, false, false, 0);
        if (up && fingerUp) { appendEvent(up, fingerUp, 0); ((void(*)(id,SEL,IOHIDEventRef))objc_msgSend)(app, handle, up); }
        if (fingerUp) CFRelease(fingerUp); if (up) CFRelease(up);
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}

static BOOL ASPSyntheticTouch(UIWindow *window, UIView *hit, CGPoint p) {
    Class touchClass = NSClassFromString(@"UITouch");
    Class eventClass = NSClassFromString(@"UIEvent");
    if (!touchClass || !eventClass || !hit) return NO;
    @try {
        id touch = [[touchClass alloc] init];
        NSInteger touchID = (NSInteger)((mach_absolute_time() % 31) + 1);
        [touch setValue:@(touchID) forKey:@"_touchIdentifier"];
        [touch setValue:[NSValue valueWithCGPoint:p] forKey:@"_locationInWindow"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"_phase"];
        ((void(*)(id,SEL,id))objc_msgSend)(touch, NSSelectorFromString(@"setWindow:"), window);
        ((void(*)(id,SEL,id))objc_msgSend)(touch, NSSelectorFromString(@"setView:"), hit);
        id event = [[eventClass alloc] init];
        NSSet *touches = [NSSet setWithObject:touch];
        [event setValue:touches forKey:@"_allTouches"];
        [hit touchesBegan:touches withEvent:event];
        [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
        [hit touchesEnded:touches withEvent:event];
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}

static BOOL ASPClickPoint(UIWindow *window, CGPoint p) {
    if (!window || !CGRectContainsPoint(window.bounds, p)) return NO;
    UIView *hit = [window hitTest:p withEvent:nil];
    if (hit && ASPActivate(hit)) return YES;
    if (ASPHIDTap(window, p)) return YES;
    return hit ? ASPSyntheticTouch(window, hit, p) : NO;
}

static void ASPScanWebViews(UIView *root) {
    if (!root || !ASPActuallyVisible(root)) return;
    NSString *name = NSStringFromClass(root.class);
    SEL eval = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if ([name containsString:@"WKWebView"] && [root respondsToSelector:eval]) {
        NSString *js = @"(()=>{const re=/(跳过|略过|skip|关闭广告|close)/i;let es=[...document.querySelectorAll('button,a,[role=button],[onclick],div,span')];let e=es.find(x=>{let r=x.getBoundingClientRect(),t=(x.innerText||x.textContent||x.getAttribute('aria-label')||'').trim();return re.test(t)&&r.width>0&&r.height>0});if(e){e.click();return true}return false})()";
        ((void(*)(id,SEL,id,id))objc_msgSend)(root, eval, js, nil);
    }
    for (UIView *child in root.subviews) ASPScanWebViews(child);
}

static void ASPOCRWindow(UIWindow *window) {
    if (!window || gOCRBusy || CACurrentMediaTime() - gLastOCR < 0.8) return;
    gOCRBusy = YES; gLastOCR = CACurrentMediaTime();
    CGSize size = window.bounds.size;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    CGImageRef cg = image.CGImage;
    if (!cg) { gOCRBusy = NO; return; }
    CGImageRetain(cg);
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, __unused NSError *error) {
        VNRecognizedTextObservation *best = nil; NSInteger bestScore = 0;
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [obs topCandidates:1].firstObject;
            NSInteger score = ASPTextScore(top.string);
            if (!score) continue;
            CGRect b = obs.boundingBox;
            if (CGRectGetMidX(b) > 0.55) score += 20;
            if (CGRectGetMidY(b) > 0.65) score += 20;
            if (score > bestScore) { best = obs; bestScore = score; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (best && gEnabled && CACurrentMediaTime() - gStartedAt <= kScanDuration) {
                CGRect b = best.boundingBox;
                CGPoint p = CGPointMake(CGRectGetMidX(b) * size.width, (1.0 - CGRectGetMidY(b)) * size.height);
                ASPClickPoint(window, p);
            }
            gOCRBusy = NO;
        });
    }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;
    req.minimumTextHeight = 0.005;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        [handler performRequests:@[req] error:nil];
        CGImageRelease(cg);
    });
}

static NSArray<UIWindow *> *ASPWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    return [windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static void ASPScan(void) {
    if (!gEnabled || gScanning || CACurrentMediaTime() - gStartedAt > kScanDuration) return;
    gScanning = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ASPWindows()) {
            UIView *best = nil; NSInteger score = 0;
            ASPCollectBest(window, &best, &score);
            if (best && score >= 80 && ASPActivate(best)) break;
            ASPScanWebViews(window);
            ASPOCRWindow(window);
        }
        gScanning = NO;
    });
}

static void ASPScheduleLoop(void) {
    if (!gEnabled) return;
    gStartedAt = CACurrentMediaTime();
    NSUInteger generation = ++gScanGeneration;
    __block void (^tick)(void);
    tick = ^{
        if (!gEnabled || generation != gScanGeneration || CACurrentMediaTime() - gStartedAt > kScanDuration) { tick = nil; return; }
        ASPScan();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), tick);
    };
    dispatch_async(dispatch_get_main_queue(), tick);
}

static void ASPPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{ ASPReload(); ++gScanGeneration; if (gEnabled) ASPScheduleLoop(); });
}

%hook UIView
- (void)didMoveToWindow { %orig; if (gEnabled && self.window) ASPScan(); }
%end
%hook UILabel
- (void)setText:(NSString *)text { %orig; if (gEnabled && ASPTextScore(text)) ASPScan(); }
- (void)setAttributedText:(NSAttributedString *)text { %orig; if (gEnabled && ASPTextScore(text.string)) ASPScan(); }
%end
%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state { %orig; if (gEnabled && ASPTextScore(title)) ASPScan(); }
%end

%ctor {
    @autoreleasepool {
        ASPReload();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, ASPPrefsChanged, (__bridge CFStringRef)ASPChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ if (gEnabled) ASPScheduleLoop(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ if (gEnabled) ASPScheduleLoop(); }];
        if (gEnabled) ASPScheduleLoop();
    }
}
