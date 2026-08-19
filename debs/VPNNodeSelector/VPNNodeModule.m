#import "VPNNodeModule.h"
#import "VPNBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *VPNCoordinatorKey = &VPNCoordinatorKey;
static const void *VPNOriginalHiddenKey = &VPNOriginalHiddenKey;
static const void *VPNOriginalBackgroundKey = &VPNOriginalBackgroundKey;
static NSString *const VPNStatusNotificationName = @"SBVPNConnectionChangedNotification";
static __weak VPNNodeModule *VPNActiveModule;

static VPNNodeViewController *VPNCoordinator(id host) {
    return objc_getAssociatedObject(host, VPNCoordinatorKey);
}

static void VPNStatusCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VPNNodeModule *module = VPNActiveModule;
    if (!module) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [module vpnStatusDidChange]; });
}

static void VPNSendSuperVoid(id object, SEL selector) {
    Class parent = class_getSuperclass(object_getClass(object));
    if (!class_getInstanceMethod(parent, selector)) return;
    struct objc_super info = { object, parent };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&info, selector);
}
static void VPNSendSuperBoolArg(id object, SEL selector, BOOL value) {
    Class parent = class_getSuperclass(object_getClass(object));
    if (!class_getInstanceMethod(parent, selector)) return;
    struct objc_super info = { object, parent };
    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&info, selector, value);
}

static void VPNSetNativeContentHidden(UIViewController *host, VPNNodeViewController *coordinator, BOOL hidden) {
    for (UIView *view in host.view.subviews.copy) {
        if (view == coordinator.view) continue;
        if (hidden) {
            if (!objc_getAssociatedObject(view, VPNOriginalHiddenKey)) {
                objc_setAssociatedObject(view, VPNOriginalHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            view.hidden = YES;
        } else {
            NSNumber *original = objc_getAssociatedObject(view, VPNOriginalHiddenKey);
            if (original) {
                view.hidden = original.boolValue;
                objc_setAssociatedObject(view, VPNOriginalHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static void VPNApplyHostMode(UIViewController *host) {
    VPNNodeViewController *coordinator = VPNCoordinator(host);
    if (!coordinator || !host.isViewLoaded) return;
    CGRect bounds = host.view.bounds;
    BOOL roomy = CGRectGetWidth(bounds) >= 220.0 && CGRectGetHeight(bounds) >= 180.0;
    [coordinator hostDidLayoutWithBounds:bounds];
    BOOL showPanel = roomy && coordinator.isExpanded;
    coordinator.view.frame = bounds;
    coordinator.view.hidden = !showPanel;
    coordinator.view.userInteractionEnabled = showPanel;
    VPNSetNativeContentHidden(host, coordinator, showPanel);
    if (showPanel) {
        if (!objc_getAssociatedObject(host.view, VPNOriginalBackgroundKey)) {
            id original = host.view.backgroundColor ?: NSNull.null;
            objc_setAssociatedObject(host.view, VPNOriginalBackgroundKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        host.view.backgroundColor = UIColor.clearColor;
        [host.view bringSubviewToFront:coordinator.view];
    } else {
        id original = objc_getAssociatedObject(host.view, VPNOriginalBackgroundKey);
        if (original) {
            host.view.backgroundColor = original == NSNull.null ? nil : original;
            objc_setAssociatedObject(host.view, VPNOriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void VPNRuntimeViewDidLoad(id self, SEL _cmd) {
    VPNSendSuperVoid(self, _cmd);
    VPNNodeViewController *coordinator = VPNCoordinator(self);
    UIViewController *host = self;
    [host addChildViewController:coordinator];
    coordinator.view.frame = host.view.bounds;
    coordinator.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    coordinator.view.hidden = YES;
    coordinator.view.userInteractionEnabled = NO;
    [host.view addSubview:coordinator.view];
    [coordinator didMoveToParentViewController:host];
}
static void VPNRuntimeViewWillAppear(id self, SEL _cmd, BOOL animated) {
    VPNSendSuperBoolArg(self, _cmd, animated);
    [VPNCoordinator(self) hostWillAppear];
    VPNApplyHostMode(self);
}
static void VPNRuntimeViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    VPNSendSuperBoolArg(self, _cmd, animated);
    [VPNCoordinator(self) hostDidDisappear];
}
static void VPNRuntimeViewDidLayout(id self, SEL _cmd) {
    VPNSendSuperVoid(self, _cmd);
    VPNApplyHostMode(self);
}
static BOOL VPNRuntimeBegin(id self, SEL _cmd) { return YES; }
static BOOL VPNRuntimeFinish(id self, SEL _cmd) { return YES; }
static void VPNRuntimeExpand(id self, SEL _cmd, BOOL animated) {
    VPNSendSuperBoolArg(self, _cmd, animated);
    VPNNodeViewController *coordinator = VPNCoordinator(self);
    [coordinator willTransitionToExpandedContentMode:animated];
    VPNApplyHostMode(self);
}
static void VPNRuntimeReturn(id self, SEL _cmd) {
    VPNSendSuperVoid(self, _cmd);
    VPNNodeViewController *coordinator = VPNCoordinator(self);
    [coordinator willReturnToExpandedContentModule];
    VPNApplyHostMode(self);
}
static CGFloat VPNRuntimeHeight(id self, SEL _cmd) { return 360.0; }
static CGFloat VPNRuntimeWidth(id self, SEL _cmd) {
    return MAX(MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 32.0, 390.0), 300.0);
}
static BOOL VPNRuntimeOwnPlatter(id self, SEL _cmd) { return NO; }

static Class VPNRuntimeControllerClass(void) {
    static Class runtimeClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class base = NSClassFromString(@"CCUIToggleViewController");
        if (!base) base = UIViewController.class;
        runtimeClass = objc_allocateClassPair(base, "VPNNodeRuntimeControllerV104", 0);
        if (!runtimeClass) { runtimeClass = NSClassFromString(@"VPNNodeRuntimeControllerV104"); return; }
        class_addMethod(runtimeClass, @selector(viewDidLoad), (IMP)VPNRuntimeViewDidLoad, "v@:");
        class_addMethod(runtimeClass, @selector(viewWillAppear:), (IMP)VPNRuntimeViewWillAppear, "v@:B");
        class_addMethod(runtimeClass, @selector(viewDidDisappear:), (IMP)VPNRuntimeViewDidDisappear, "v@:B");
        class_addMethod(runtimeClass, @selector(viewDidLayoutSubviews), (IMP)VPNRuntimeViewDidLayout, "v@:");
        class_addMethod(runtimeClass, @selector(shouldBeginTransitionToExpandedContentModule), (IMP)VPNRuntimeBegin, "B@:");
        class_addMethod(runtimeClass, @selector(shouldFinishTransitionToExpandedContentModule), (IMP)VPNRuntimeFinish, "B@:");
        class_addMethod(runtimeClass, @selector(willTransitionToExpandedContentMode:), (IMP)VPNRuntimeExpand, "v@:B");
        class_addMethod(runtimeClass, @selector(willReturnToExpandedContentModule), (IMP)VPNRuntimeReturn, "v@:");
        class_addMethod(runtimeClass, @selector(preferredExpandedContentHeight), (IMP)VPNRuntimeHeight, "d@:");
        class_addMethod(runtimeClass, @selector(preferredExpandedContentWidth), (IMP)VPNRuntimeWidth, "d@:");
        class_addMethod(runtimeClass, @selector(providesOwnPlatter), (IMP)VPNRuntimeOwnPlatter, "B@:");
        objc_registerClassPair(runtimeClass);
    });
    return runtimeClass;
}

@implementation VPNNodeModule {
    UIViewController *_controller;
    BOOL _selected;
    NSUInteger _refreshGeneration;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        VPNActiveModule = self;
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, VPNStatusCallback, (__bridge CFStringRef)VPNStatusNotificationName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}
- (void)refreshVisualState { [self syncControllerVisualState]; }
- (void)syncControllerVisualState {
    BOOL active = VPNLegacyIsActive();
    _selected = active;
    [super refreshState];
    if ([_controller respondsToSelector:@selector(setSelected:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(_controller, @selector(setSelected:), active);
    }
    if ([_controller respondsToSelector:@selector(refreshState)]) {
        ((void (*)(id, SEL))objc_msgSend)(_controller, @selector(refreshState));
    }
}
- (void)scheduleRefreshBurst {
    NSUInteger generation = ++_refreshGeneration;
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[@0.08, @0.2, @0.45, @0.9, @1.5, @2.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (!selfRef || generation != selfRef->_refreshGeneration) return;
            [selfRef syncControllerVisualState];
        });
    }
}
- (void)vpnStatusDidChange {
    [self syncControllerVisualState];
    [self scheduleRefreshBurst];
    [VPNCoordinator(_controller) refreshForExternalVPNChange];
}
- (UIViewController *)contentViewController {
    if (!_controller) {
        Class cls = VPNRuntimeControllerClass();
        _controller = [cls new];
        VPNNodeViewController *coordinator = [VPNNodeViewController new];
        coordinator.module = self;
        objc_setAssociatedObject(_controller, VPNCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL setModule = NSSelectorFromString(@"setModule:");
        if ([_controller respondsToSelector:setModule]) ((void (*)(id, SEL, id))objc_msgSend)(_controller, setModule, self);
    }
    return _controller;
}
- (UIViewController *)backgroundViewController { return nil; }
- (BOOL)isSelected { return VPNLegacyIsActive(); }
- (void)setSelected:(BOOL)value {
    _selected = value;
    VPNLegacySetActive(value);
    [self syncControllerVisualState];
    [self scheduleRefreshBurst];
}
- (UIImage *)moduleGlyph {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *path = [bundle pathForResource:@"Icon@3x" ofType:@"png"];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
- (UIImage *)iconGlyph { return [self moduleGlyph]; }
- (UIImage *)selectedIconGlyph { return [self moduleGlyph]; }
- (UIColor *)selectedColor { return UIColor.systemBlueColor; }
- (void)dealloc {
    ++_refreshGeneration;
    if (VPNActiveModule == self) VPNActiveModule = nil;
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), NULL, (__bridge CFStringRef)VPNStatusNotificationName, NULL);
}
@end
