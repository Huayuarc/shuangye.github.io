// Included in RefreshRate.xm. Every hook calls original FIRST.
static BOOL CPUthermalUIClaim(Class target, SEL selector, NSArray<NSString *> *args) {
    if (CPUthermalRateAlreadyChecked(target, selector)) return NO;
    Method method = class_getInstanceMethod(target, selector);
    if (!CPUthermalExactMethod(method, "v", args)) { CPUthermalHookSkip(target, selector, method); return NO; }
    // Hook target, not ancestor: inherited private selectors must not mutate
    // generic NSObject/UIView parents. MSHookMessageEx preserves original chain.
    return CPUthermalClaimHook(target, selector);
}
static void CPUthermalUIInstallVoid(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":"])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL))original)(object, selector); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallBool(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(BOOL)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, BOOL animated) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, BOOL))original)(object, selector, animated); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallRect(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(CGRect)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CGRect rect) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, CGRect))original)(object, selector, rect); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallPoint(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(CGPoint)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CGPoint point) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, CGPoint))original)(object, selector, point); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallDouble(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(double)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, double value) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, double))original)(object, selector, value); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallTransform(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(CATransform3D)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CATransform3D transform) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, CATransform3D))original)(object, selector, transform); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallObject(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(id)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, id value) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, id))original)(object, selector, value); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, value);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallObjectBool(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(id)], [NSString stringWithUTF8String:@encode(BOOL)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, id value, BOOL animated) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, id, BOOL))original)(object, selector, value, animated); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallPointBool(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(CGPoint)], [NSString stringWithUTF8String:@encode(BOOL)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CGPoint point, BOOL animated) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, CGPoint, BOOL))original)(object, selector, point, animated); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallObjectObject(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(id)], [NSString stringWithUTF8String:@encode(id)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, id value, id key) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, id, id))original)(object, selector, value, key); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallRectObjectBool(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(CGRect)], [NSString stringWithUTF8String:@encode(id)], [NSString stringWithUTF8String:@encode(BOOL)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CGRect rect, id view, BOOL animated) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, CGRect, id, BOOL))original)(object, selector, rect, view, animated); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalUIInstallPresent(NSString *className, NSString *name, NSUInteger path, NSUInteger event) {
    Class target = NSClassFromString(className); if (!target) return;
    SEL selector = NSSelectorFromString(name);
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(id)], [NSString stringWithUTF8String:@encode(BOOL)], @"@?"])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, id controller, BOOL animated, void (^completion)(void)) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, id, BOOL, void (^)(void)))original)(object, selector, controller, animated, completion); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
template<typename Reason> static BOOL CPUthermalUIInstallBannerReason(Class target, SEL selector, const char *type, NSUInteger path, NSUInteger event) {
    if (!CPUthermalUIClaim(target, selector, @[@"@", @":", @"@", [NSString stringWithUTF8String:type]])) return NO;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, id presentable, Reason reason) {
        BOOL main = NSThread.isMainThread;
        if (main) ++gUIOriginalDepth;
        @try { ((void (*)(id, SEL, id, Reason))original)(object, selector, presentable, reason); }
        @finally { if (main) --gUIOriginalDepth; }
        CPUthermalUIEvent(object, path, event, presentable);
    });
    MSHookMessageEx(target, selector, replacement, &original);
    return YES;
}
static NSMapTable<id, CPUthermalPrivateRateState *> *gAnimationRanges;
static void CPUthermalApplyAnimation(id object, CPUthermalPrivateRateState *state, BOOL active) {
    if (!state.hasRange || state.depth || !state.original || (!active && !state.forced)) return;
    ++state.depth;
    ((void (*)(id, SEL, CAFrameRateRange))state.original)(object, state.selector,
        active ? CAFrameRateRangeMake(120, 120, 120) : state.range);
    state.forced = active;
    --state.depth;
}
static void CPUthermalRefreshAnimations(void) {
    for (id object in gAnimationRanges.keyEnumerator.allObjects)
        CPUthermalApplyAnimation(object, [gAnimationRanges objectForKey:object], gUIEnabled);
}
static void CPUthermalInstallAnimationHook(void) {
    Class target = NSClassFromString(@"CAAnimation");
    SEL selector = NSSelectorFromString(@"setPreferredFrameRateRange:");
    if (!target || !CPUthermalUIClaim(target, selector, @[@"@", @":", [NSString stringWithUTF8String:@encode(CAFrameRateRange)]])) return;
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id object, CAFrameRateRange range) {
        if (!NSThread.isMainThread) { ((void (*)(id, SEL, CAFrameRateRange))original)(object, selector, range); return; }
        CPUthermalPrivateRateState *state = [gAnimationRanges objectForKey:object];
        if (state.depth) { ((void (*)(id, SEL, CAFrameRateRange))original)(object, selector, range); return; }
        if (!state && gUIEnabled) state = CPUthermalPrivateState(&gAnimationRanges, object);
        if (state) {
            state.range = range; state.hasRange = YES; state.original = original; state.selector = selector;
            ++state.depth;
        }
        ((void (*)(id, SEL, CAFrameRateRange))original)(object, selector, range);
        if (state) --state.depth;
        if (state) CPUthermalApplyAnimation(object, state, gUIEnabled);
        CPUthermalUIEvent(object, 60, 0, nil);
    });
    MSHookMessageEx(target, selector, replacement, &original);
}
static void CPUthermalInstallUIHooks(void) {
    if (!NSThread.isMainThread) return;
    CPUthermalInstallAnimationHook();
    CPUthermalUIInstallBool(@"UIViewController", @"viewWillAppear:", 0, 0);
    CPUthermalUIInstallBool(@"UIViewController", @"viewDidAppear:", 1, 0);
    CPUthermalUIInstallPresent(@"UIViewController", @"presentViewController:animated:completion:", 2, 0);
    CPUthermalUIInstallObjectBool(@"UINavigationController", @"pushViewController:animated:", 3, 0);
    CPUthermalUIInstallRect(@"UIWindow", @"setFrame:", 4, 0);
    CPUthermalUIInstallRect(@"UIWindow", @"setBounds:", 5, 0);
    CPUthermalUIInstallVoid(@"UIWindow", @"makeKeyAndVisible", 6, 0);
    CPUthermalUIInstallDouble(@"UIWindow", @"setWindowLevel:", 7, 0);
    CPUthermalUIInstallRect(@"UIView", @"setFrame:", 8, 0);
    CPUthermalUIInstallRect(@"UIView", @"setBounds:", 9, 0);
    CPUthermalUIInstallPoint(@"UIScrollView", @"setContentOffset:", 10, 0);
    CPUthermalUIInstallPointBool(@"UIScrollView", @"setContentOffset:animated:", 11, 0);
    CPUthermalUIInstallVoid(@"UIScrollView", @"layoutSubviews", 12, 0);
    CPUthermalUIInstallVoid(@"UIViewPropertyAnimator", @"startAnimation", 13, 0);
    CPUthermalUIInstallDouble(@"UIViewPropertyAnimator", @"startAnimationAfterDelay:", 14, 0);
    CPUthermalUIInstallObjectObject(@"CALayer", @"addAnimation:forKey:", 15, 0);
    CPUthermalUIInstallRect(@"CALayer", @"setBounds:", 16, 0);
    CPUthermalUIInstallPoint(@"CALayer", @"setPosition:", 17, 0);
    CPUthermalUIInstallTransform(@"CALayer", @"setTransform:", 18, 0);
    CPUthermalUIInstallBool(@"UIAlertController", @"viewDidAppear:", 19, 0);
    CPUthermalUIInstallRectObjectBool(@"UIMenuController", @"showFromRect:inView:animated:", 20, 0);
    CPUthermalUIInstallObjectBool(@"UIMenuController", @"showFromBarButtonItem:animated:", 21, 0);
    CPUthermalUIInstallBool(@"UIPopoverPresentationController", @"viewDidAppear:", 22, 0);
    CPUthermalUIInstallPoint(@"UIContextMenuInteraction", @"_presentMenuAtLocation:", 23, 0);
    CPUthermalUIInstallPoint(@"UIEditMenuInteraction", @"_presentMenuAtLocation:", 24, 0);
    if (!gIsSpringBoard) return;
    NSUInteger path = 30;
    for (NSString *cls in @[@"SBNotificationBannerDestination", @"NCNotificationPresentableViewController"]) {
        CPUthermalUIInstallObject(cls, @"presentableWillAppearAsBanner:", path++, 1);
        CPUthermalUIInstallObject(cls, @"presentableDidAppearAsBanner:", path++, 1);
        Class target = NSClassFromString(cls); if (!target) continue;
        for (NSString *name in @[@"presentableWillDisappearAsBanner:withReason:", @"presentableDidDisappearAsBanner:withReason:", @"presentableWillNotAppearAsBanner:withReason:"]) {
            SEL selector = NSSelectorFromString(name);
            NSUInteger event = [name containsString:@"WillDisappear"] ? 2 : 3;
            BOOL installed = CPUthermalUIInstallBannerReason<int>(target, selector, "i", path, event) ||
                CPUthermalUIInstallBannerReason<unsigned int>(target, selector, "I", path, event) ||
                CPUthermalUIInstallBannerReason<long long>(target, selector, "q", path, event) ||
                CPUthermalUIInstallBannerReason<unsigned long long>(target, selector, "Q", path, event);
            (void)installed;
            ++path;
        }
    }
    CPUthermalUIInstallVoid(@"NCNotificationShortLookView", @"didMoveToWindow", 45, 0);
}
