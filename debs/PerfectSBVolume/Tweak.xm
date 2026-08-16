#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>

// A fixed thin HUD for iOS 15–17. The 22% short-side cap stays narrower
// than both the classic notch window and Dynamic Island on supported iPhones.
static double ThinWidth(void) {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat shortSide = MIN(CGRectGetWidth(screen), CGRectGetHeight(screen));
    return MIN(94.0, MAX(80.0, shortSide * 0.22));
}
static double ThinHeight(void) { return 6.0; }
static double ThinRadius(void) { return 3.0; }

static NSInteger hook_axis(id self, SEL _cmd) { return 1; }

static double (*orig_glyphScaleForState)(id, SEL, NSInteger);
static double hook_glyphScaleForState(id self, SEL _cmd, NSInteger state) {
    // Never request the expanded State 2 appearance.
    return orig_glyphScaleForState ? orig_glyphScaleForState(self, _cmd, 1) : 1.0;
}

static CGPoint (*orig_center)(id, SEL, NSInteger, CGSize, CGRect, BOOL);
static CGPoint hook_center(id self, SEL _cmd, NSInteger state, CGSize containerSize, CGRect bounds, BOOL useSpringData) {
    CGPoint point = orig_center(self, _cmd, 1, containerSize, bounds, useSpringData);
    CGFloat screenHeight = CGRectGetHeight(UIScreen.mainScreen.bounds);
    CGFloat y = containerSize.height * 0.5 + ((screenHeight - containerSize.height) / 100.0) * 4.0;
    return CGPointMake((CGFloat)(NSInteger)point.x, (CGFloat)(NSInteger)y);
}

static void hook_updateLabels(id self, SEL _cmd, NSInteger axis, CGSize size, NSInteger state, BOOL animated) {}

static CGSize hook_preferredContentSize(id self, SEL _cmd) {
    return CGSizeMake(ThinWidth(), ThinHeight());
}
static void (*orig_setPreferredContentSize)(id, SEL, CGSize);
static void hook_setPreferredContentSize(id self, SEL cmd, CGSize size) {
    if (orig_setPreferredContentSize) orig_setPreferredContentSize(self, cmd, CGSizeMake(ThinWidth(), ThinHeight()));
}
static void (*orig_viewDidLayoutSubviews)(id, SEL);
static void hook_viewDidLayoutSubviews(id self, SEL cmd) {
    if (orig_viewDidLayoutSubviews) orig_viewDidLayoutSubviews(self, cmd);
    UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(self, @selector(view));
    CGRect bounds = view.bounds;
    // SBElasticVolumeViewController's root is a compact HUD container. Clip it
    // after every state transition so cached iOS 15–17 State 2 metrics cannot expand it.
    if (CGRectGetWidth(bounds) <= 320.0 && CGRectGetHeight(bounds) <= 160.0) {
        bounds.size = CGSizeMake(ThinWidth(), ThinHeight());
        view.bounds = bounds;
        view.layer.cornerRadius = ThinRadius();
        view.clipsToBounds = YES;
    }
}

#define WIDTH_GETTER(NAME) static double hook_##NAME(id self, SEL _cmd) { return ThinWidth(); }
#define HEIGHT_GETTER(NAME) static double hook_##NAME(id self, SEL _cmd) { return ThinHeight(); }
#define RADIUS_GETTER(NAME) static double hook_##NAME(id self, SEL _cmd) { return ThinRadius(); }

WIDTH_GETTER(portraitState1Width) WIDTH_GETTER(portraitState2Width) WIDTH_GETTER(portraitState3Width)
HEIGHT_GETTER(portraitState1Height) HEIGHT_GETTER(portraitState2Height) HEIGHT_GETTER(portraitState3Height)
RADIUS_GETTER(portraitState1CornerRadius) RADIUS_GETTER(portraitState2CornerRadius) RADIUS_GETTER(portraitState3CornerRadius)
WIDTH_GETTER(landscapeState1Width) WIDTH_GETTER(landscapeState2Width) WIDTH_GETTER(landscapeState3Width)
HEIGHT_GETTER(landscapeState1Height) HEIGHT_GETTER(landscapeState2Height) HEIGHT_GETTER(landscapeState3Height)
RADIUS_GETTER(landscapeState1CornerRadius) RADIUS_GETTER(landscapeState2CornerRadius) RADIUS_GETTER(landscapeState3CornerRadius)

#define WIDTH_SETTER(NAME) \
static void (*orig_##NAME)(id, SEL, double); \
static void hook_##NAME(id self, SEL cmd, double value) { if (orig_##NAME) orig_##NAME(self, cmd, ThinWidth()); }
#define HEIGHT_SETTER(NAME) \
static void (*orig_##NAME)(id, SEL, double); \
static void hook_##NAME(id self, SEL cmd, double value) { if (orig_##NAME) orig_##NAME(self, cmd, ThinHeight()); }
#define RADIUS_SETTER(NAME) \
static void (*orig_##NAME)(id, SEL, double); \
static void hook_##NAME(id self, SEL cmd, double value) { if (orig_##NAME) orig_##NAME(self, cmd, ThinRadius()); }

WIDTH_SETTER(setPortraitState1Width) WIDTH_SETTER(setPortraitState2Width) WIDTH_SETTER(setPortraitState3Width)
HEIGHT_SETTER(setPortraitState1Height) HEIGHT_SETTER(setPortraitState2Height) HEIGHT_SETTER(setPortraitState3Height)
RADIUS_SETTER(setPortraitState1CornerRadius) RADIUS_SETTER(setPortraitState2CornerRadius) RADIUS_SETTER(setPortraitState3CornerRadius)
WIDTH_SETTER(setLandscapeState1Width) WIDTH_SETTER(setLandscapeState2Width) WIDTH_SETTER(setLandscapeState3Width)
HEIGHT_SETTER(setLandscapeState1Height) HEIGHT_SETTER(setLandscapeState2Height) HEIGHT_SETTER(setLandscapeState3Height)
RADIUS_SETTER(setLandscapeState1CornerRadius) RADIUS_SETTER(setLandscapeState2CornerRadius) RADIUS_SETTER(setLandscapeState3CornerRadius)

static void (*orig_setLabelMargin)(id, SEL, double);
static void hook_setLabelMargin(id self, SEL cmd, double value) {
    if (orig_setLabelMargin) orig_setLabelMargin(self, cmd, MIN(value, 4.0));
}

static void Hook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (cls && class_getInstanceMethod(cls, sel)) MSHookMessageEx(cls, sel, replacement, original);
}

%ctor {
    @autoreleasepool {
        Class view = objc_getClass("SBElasticVolumeViewController");
        Hook(view, @selector(axis), (IMP)hook_axis, NULL);
        Hook(view, @selector(glyphScaleForState:), (IMP)hook_glyphScaleForState, (IMP *)&orig_glyphScaleForState);
        Hook(view, @selector(centerForState:containerViewSize:bounds:useSpringData:), (IMP)hook_center, (IMP *)&orig_center);
        Hook(view, @selector(_updateLabelsForAxis:containerViewSize:state:animated:), (IMP)hook_updateLabels, NULL);
        Hook(view, @selector(preferredContentSize), (IMP)hook_preferredContentSize, NULL);
        Hook(view, @selector(setPreferredContentSize:), (IMP)hook_setPreferredContentSize, (IMP *)&orig_setPreferredContentSize);
        Hook(view, @selector(viewDidLayoutSubviews), (IMP)hook_viewDidLayoutSubviews, (IMP *)&orig_viewDidLayoutSubviews);

        Class settings = objc_getClass("SBVolumeHUDSettings");
#define HOOK_GET(NAME) Hook(settings, @selector(NAME), (IMP)hook_##NAME, NULL)
        HOOK_GET(portraitState1Width); HOOK_GET(portraitState2Width); HOOK_GET(portraitState3Width);
        HOOK_GET(portraitState1Height); HOOK_GET(portraitState2Height); HOOK_GET(portraitState3Height);
        HOOK_GET(portraitState1CornerRadius); HOOK_GET(portraitState2CornerRadius); HOOK_GET(portraitState3CornerRadius);
        HOOK_GET(landscapeState1Width); HOOK_GET(landscapeState2Width); HOOK_GET(landscapeState3Width);
        HOOK_GET(landscapeState1Height); HOOK_GET(landscapeState2Height); HOOK_GET(landscapeState3Height);
        HOOK_GET(landscapeState1CornerRadius); HOOK_GET(landscapeState2CornerRadius); HOOK_GET(landscapeState3CornerRadius);
#define HOOK_SET(NAME) Hook(settings, @selector(NAME:), (IMP)hook_##NAME, (IMP *)&orig_##NAME)
        HOOK_SET(setPortraitState1Width); HOOK_SET(setPortraitState2Width); HOOK_SET(setPortraitState3Width);
        HOOK_SET(setPortraitState1Height); HOOK_SET(setPortraitState2Height); HOOK_SET(setPortraitState3Height);
        HOOK_SET(setPortraitState1CornerRadius); HOOK_SET(setPortraitState2CornerRadius); HOOK_SET(setPortraitState3CornerRadius);
        HOOK_SET(setLandscapeState1Width); HOOK_SET(setLandscapeState2Width); HOOK_SET(setLandscapeState3Width);
        HOOK_SET(setLandscapeState1Height); HOOK_SET(setLandscapeState2Height); HOOK_SET(setLandscapeState3Height);
        HOOK_SET(setLandscapeState1CornerRadius); HOOK_SET(setLandscapeState2CornerRadius); HOOK_SET(setLandscapeState3CornerRadius);
        Hook(settings, @selector(setLabelMargin:), (IMP)hook_setLabelMargin, (IMP *)&orig_setLabelMargin);
    }
}
