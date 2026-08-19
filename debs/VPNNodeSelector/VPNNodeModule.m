#import "VPNNodeModule.h"
#import "VPNBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *VPNCoordinatorKey = &VPNCoordinatorKey;

static void VPNSendSuperVoid(id object, SEL selector) {
    Class cls = object_getClass(object);
    struct objc_super info = { object, class_getSuperclass(cls) };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&info, selector);
}
static VPNNodeViewController *VPNCoordinator(id host) {
    return objc_getAssociatedObject(host, VPNCoordinatorKey);
}
static void VPNRuntimeViewDidLoad(id self, SEL _cmd) {
    VPNSendSuperVoid(self, _cmd);
    VPNNodeViewController *coordinator = VPNCoordinator(self);
    UIViewController *host = self;
    [host addChildViewController:coordinator];
    coordinator.view.frame = host.view.bounds;
    coordinator.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    coordinator.view.hidden = YES;
    [host.view addSubview:coordinator.view];
    [coordinator didMoveToParentViewController:host];
}
static void VPNRuntimeButtonTapped(id self, SEL _cmd, id sender, id event) {
    [VPNCoordinator(self) buttonTapped:sender forEvent:event];
}
static BOOL VPNRuntimeBegin(id self, SEL _cmd) { return YES; }
static BOOL VPNRuntimeFinish(id self, SEL _cmd) { return YES; }
static void VPNRuntimeExpand(id self, SEL _cmd, BOOL animated) {
    Class cls = object_getClass(self);
    Class parent = class_getSuperclass(cls);
    if (class_getInstanceMethod(parent, _cmd)) {
        struct objc_super info = { self, parent };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&info, _cmd, animated);
    }
    VPNNodeViewController *coordinator = VPNCoordinator(self);
    coordinator.view.hidden = NO;
    [coordinator willTransitionToExpandedContentMode:animated];
}
static void VPNRuntimeReturn(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    Class parent = class_getSuperclass(cls);
    if (class_getInstanceMethod(parent, _cmd)) VPNSendSuperVoid(self, _cmd);
    VPNNodeViewController *coordinator = VPNCoordinator(self);
    [coordinator willReturnToExpandedContentModule];
    coordinator.view.hidden = YES;
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
        runtimeClass = objc_allocateClassPair(base, "VPNNodeRuntimeController", 0);
        if (!runtimeClass) { runtimeClass = NSClassFromString(@"VPNNodeRuntimeController"); return; }
        class_addMethod(runtimeClass, @selector(viewDidLoad), (IMP)VPNRuntimeViewDidLoad, "v@:");
        class_addMethod(runtimeClass, NSSelectorFromString(@"buttonTapped:forEvent:"), (IMP)VPNRuntimeButtonTapped, "v@:@@");
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
}
- (VPNNodeViewController *)contentViewController {
    if (!_controller) {
        Class cls = VPNRuntimeControllerClass();
        _controller = [cls new];
        VPNNodeViewController *coordinator = [VPNNodeViewController new];
        coordinator.module = self;
        objc_setAssociatedObject(_controller, VPNCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL setModule = NSSelectorFromString(@"setModule:");
        if ([_controller respondsToSelector:setModule]) ((void (*)(id, SEL, id))objc_msgSend)(_controller, setModule, self);
    }
    return (id)_controller;
}
- (UIViewController *)backgroundViewController { return nil; }
- (BOOL)isSelected { return VPNLegacyIsActive(); }
- (void)setSelected:(BOOL)value {
    if (VPNLegacyIsActive() != value) VPNLegacyToggle();
    _selected = value;
    [super refreshState];
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
@end
