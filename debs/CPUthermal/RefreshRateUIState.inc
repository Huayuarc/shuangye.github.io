// Shared state, no second dylib. Main-thread, event-only policy.
static CAFrameRateRange gAppSourceNativeRange;
static BOOL gUIEnabled, gUIBusy;
static BOOL gAppOwnedRangeWritten;
static unsigned int gUIOriginalDepth; // main-thread only; no unsupported iOS TLS
static CFTimeInterval gUIPathTime[64], gUISourceTime, gUIOwnedWriteTime, gUIInspectTime;
static CFTimeInterval gBannerDeadline, gFloatingDeadline;
static NSUInteger gBannerGeneration, gFloatingGeneration;
static __weak id gBannerPresentable;
static __weak UIWindow *gBannerWindow;
static BOOL CPUthermalInteractionHold(void);
static void CPUthermalUpdateAppSource(void);
static void CPUthermalUILifecycle(void);
static void CPUthermalInstallUIHooks(void);

// Reason ABI is NOT inferred from pointer size. ^I/r^I confirms uint32_t;
// signedness and width of count are independently checked at the runtime.
template<typename Count> static BOOL CPUthermalWriteReasonCount(id source, Method method, const char *countType) {
    NSString *count = [NSString stringWithUTF8String:countType];
    if (!CPUthermalExactMethod(method, "v", @[@"@", @":", @"^I", count]) &&
        !CPUthermalExactMethod(method, "v", @[@"@", @":", @"r^I", count])) return NO;
    uint32_t reason = 1;
    ((void (*)(id, SEL, const uint32_t *, Count))method_getImplementation(method))
        (source, NSSelectorFromString(@"setHighFrameRateReasons:count:"), &reason, (Count)1);
    return YES;
}
static void CPUthermalOwnedSourceReason(id source) {
    if (!source) return;
    Class cls = object_getClass(source);
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"setHighFrameRateReasons:count:"));
    if (CPUthermalWriteReasonCount<unsigned int>(source, method, "I") ||
        CPUthermalWriteReasonCount<int>(source, method, "i") ||
        CPUthermalWriteReasonCount<unsigned long long>(source, method, "Q") ||
        CPUthermalWriteReasonCount<long long>(source, method, "q")) return;
    SEL setter = NSSelectorFromString(@"setHighFrameRateReason:");
    method = class_getInstanceMethod(cls, setter);
    if (CPUthermalExactMethod(method, "v", @[@"@", @":", @"I"]))
        ((void (*)(id, SEL, unsigned int))method_getImplementation(method))(source, setter, 1U);
    else if (CPUthermalExactMethod(method, "v", @[@"@", @":", @"i"]))
        ((void (*)(id, SEL, int))method_getImplementation(method))(source, setter, 1);
    // No hook on native sources' reason setter; ambiguous encodings skip.
}
static BOOL CPUthermalInteractionHold(void) {
    if (!NSThread.isMainThread || !gUIEnabled) return NO;
    CFTimeInterval now = CACurrentMediaTime();
    return (gIsSpringBoard && now < gBannerDeadline) || now < gFloatingDeadline;
}
static void CPUthermalUpdateAppSource(void) {
    if (gIsSpringBoard) return;
    SEL setter = NSSelectorFromString(@"setPreferredFrameRateRange:");
    if (!gUIEnabled) {
        if (gAppRateSource) {
            Method method = class_getInstanceMethod(object_getClass(gAppRateSource), setter);
            if (CPUthermalExactMethod(method, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) {
                gSBSourceWrite = YES;
                @try { ((void (*)(id, SEL, CAFrameRateRange))method_getImplementation(method))(gAppRateSource, setter, gAppSourceNativeRange); }
                @finally { gSBSourceWrite = NO; }
            }
            [gPrivateRanges removeObjectForKey:gAppRateSource];
            gAppRateSource = nil;
            gAppOwnedRangeWritten = NO;
        }
        return;
    }
    if (!gAppRateSource) {
        Class cls = NSClassFromString(@"CADynamicFrameRateSource");
        Class displayClass = NSClassFromString(@"CADisplay");
        SEL mainSelector = NSSelectorFromString(@"mainDisplay"), initializer = NSSelectorFromString(@"initWithDisplay:");
        SEL getter = NSSelectorFromString(@"preferredFrameRateRange");
        Method mainMethod = class_getClassMethod(displayClass, mainSelector);
        Method initMethod = class_getInstanceMethod(cls, initializer);
        Method getMethod = class_getInstanceMethod(cls, getter);
        Method setMethod = class_getInstanceMethod(cls, setter);
        if (!CPUthermalExactMethod(mainMethod, "@", @[@"@", @":"]) ||
            !CPUthermalExactMethod(initMethod, "@", @[@"@", @":", @"@"]) ||
            !CPUthermalExactMethod(getMethod, @encode(CAFrameRateRange), @[@"@", @":"]) ||
            !CPUthermalExactMethod(setMethod, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) return;
        id display = ((id (*)(id, SEL))method_getImplementation(mainMethod))(displayClass, mainSelector);
        if (!display) return;
        gSBSourceWrite = YES;
        @try { gAppRateSource = [(CPUthermalDynamicRateSource *)[cls alloc] initWithDisplay:display]; }
        @catch (__unused NSException *error) { gAppRateSource = nil; }
        @finally { gSBSourceWrite = NO; }
        if (!gAppRateSource) return;
        getMethod = class_getInstanceMethod(object_getClass(gAppRateSource), getter);
        setMethod = class_getInstanceMethod(object_getClass(gAppRateSource), setter);
        if (!CPUthermalExactMethod(getMethod, @encode(CAFrameRateRange), @[@"@", @":"]) ||
            !CPUthermalExactMethod(setMethod, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) { gAppRateSource = nil; return; }
        gAppSourceNativeRange = ((CAFrameRateRange (*)(id, SEL))method_getImplementation(getMethod))(gAppRateSource, getter);
    }
    Method method = class_getInstanceMethod(object_getClass(gAppRateSource), setter);
    if (CPUthermalExactMethod(method, "v", @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]]) && !gAppOwnedRangeWritten) {
        gSBSourceWrite = YES;
        @try {
            CPUthermalOwnedSourceReason(gAppRateSource);
            ((void (*)(id, SEL, CAFrameRateRange))method_getImplementation(method))(gAppRateSource, setter, CAFrameRateRangeMake(120, 120, 120));
            gAppOwnedRangeWritten = YES;
        } @finally { gSBSourceWrite = NO; }
    }
}
static void CPUthermalReassertUISource(CFTimeInterval now) {
    if (now - gUISourceTime < 0.2) return;
    gUISourceTime = now;
    if (now - gUIOwnedWriteTime < 1.0) return;
    gUIOwnedWriteTime = now;
    // 有界页面事件重申：同 source 可被系统仲裁重置，不把首次写入当永久成功。
    if (gIsSpringBoard) { gSBOwnedRangeWritten = NO; CPUthermalUpdateSBSource(); }
    else { gAppOwnedRangeWritten = NO; CPUthermalUpdateAppSource(); }
}
static BOOL CPUthermalFloatingName(NSString *name) {
    for (NSString *part in @[@"floatingView.", @"FVWindow", @"FVViewController", @"FVFrontConsole"])
        if ([name containsString:part]) return YES;
    return NO;
}
static UIWindow *CPUthermalEventWindow(id object) {
    // Bounded local traversal only; NEVER enumerate UIApplication.windows.
    if ([object isKindOfClass:UIWindow.class]) return object;
    if ([object isKindOfClass:UIView.class]) return [(UIView *)object window];
    if ([object isKindOfClass:UIViewController.class]) {
        UIViewController *controller = object;
        return controller.isViewLoaded ? controller.view.window : nil;
    }
    if ([object isKindOfClass:CALayer.class]) {
        CALayer *layer = object;
        for (NSUInteger i = 0; layer && i < 6; ++i, layer = layer.superlayer) {
            id delegate = layer.delegate;
            if ([delegate isKindOfClass:UIView.class]) return [(UIView *)delegate window];
        }
    }
    return nil;
}
static BOOL CPUthermalFloatingWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;
    // Per-window 0.25s classification cache, retained values do not retain window.
    static char cacheKey;
    NSArray *cache = objc_getAssociatedObject(window, &cacheKey);
    CFTimeInterval now = CACurrentMediaTime();
    if (cache && now - [cache[0] doubleValue] < 0.25) return [cache[1] boolValue];
    BOOL match = CPUthermalFloatingName(NSStringFromClass(window.class)) ||
        CPUthermalFloatingName(NSStringFromClass(window.rootViewController.class));
    objc_setAssociatedObject(window, &cacheKey, @[@(now), @(match)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return match;
}
static void CPUthermalBeginFloating(CFTimeInterval now) {
    if (now < gFloatingDeadline) return; // Do not renew beyond one 4s epoch.
    gFloatingDeadline = now + 4.0;
    NSUInteger generation = ++gFloatingGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != gFloatingGeneration) return;
        gFloatingDeadline = 0;
        CPUthermalRefreshPrivateRequests();
    });
}
static void CPUthermalBeginBanner(id presentable, UIWindow *window, CFTimeInterval now) {
    if (!gIsSpringBoard) return;
    if (now < gBannerDeadline && (!presentable || gBannerPresentable == presentable)) {
        if (window) gBannerWindow = window;
        return; // duplicate will/did callbacks cannot extend hard deadline
    }
    gBannerPresentable = presentable;
    gBannerWindow = window;
    gBannerDeadline = now + 4.0;
    NSUInteger generation = ++gBannerGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != gBannerGeneration) return;
        gBannerDeadline = 0; gBannerPresentable = nil; gBannerWindow = nil;
        CPUthermalRefreshPrivateRequests();
    });
}
static void CPUthermalEndBanner(id presentable) {
    if (gBannerPresentable != presentable) return; // old banner end cannot clear new
    NSUInteger generation = gBannerGeneration;
    // Tail <=0.2s, and it NEVER extends the hard four-second deadline.
    gBannerDeadline = MIN(gBannerDeadline, CACurrentMediaTime() + 0.2);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != gBannerGeneration) return;
        gBannerDeadline = 0; gBannerPresentable = nil; gBannerWindow = nil;
        CPUthermalRefreshPrivateRequests();
    });
}
static void CPUthermalUIEvent(id object, NSUInteger path, NSUInteger event, id presentable) {
    // Hot path: no plist, disk IO, capability probing, logs or class discovery.
    if (!NSThread.isMainThread || !gUIEnabled || gUIBusy || gUIOriginalDepth) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (!event && now - gUIPathTime[path] < 0.2) return;
    gUIPathTime[path] = now;
    gUIBusy = YES;
    @try {
        if (event == 1) CPUthermalBeginBanner(presentable, nil, now);
        else if (event == 2 || event == 3) CPUthermalEndBanner(presentable);
        if (now - gUIInspectTime >= 0.25) {
            gUIInspectTime = now;
            UIWindow *window = CPUthermalEventWindow(object);
            if (gIsSpringBoard && [NSStringFromClass(window.class) isEqualToString:@"SBBannerWindow"])
                CPUthermalBeginBanner(nil, window, now);
            else if (CPUthermalFloatingWindow(window)) CPUthermalBeginFloating(now);
        }
        CPUthermalReassertUISource(now);
    } @finally { gUIBusy = NO; }
}
static void CPUthermalUILifecycle(void) {
    gUIEnabled = CPUthermalSourceRateActive();
    if (!gUIEnabled) {
        ++gBannerGeneration; ++gFloatingGeneration;
        gBannerDeadline = 0; gFloatingDeadline = 0;
        gBannerPresentable = nil; gBannerWindow = nil;
        gUISourceTime = 0; gUIOwnedWriteTime = 0; gUIInspectTime = 0;
        memset(gUIPathTime, 0, sizeof(gUIPathTime));
    }
    CPUthermalUpdateAppSource();
    CPUthermalInstallUIHooks();
}
