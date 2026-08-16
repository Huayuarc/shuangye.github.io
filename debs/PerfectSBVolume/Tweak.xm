#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface SBVolumeHUDSettings : NSObject
- (double)portraitState2Width;
- (double)portraitState2Height;
- (double)portraitState2CornerRadius;
- (double)landscapeState2Width;
- (double)landscapeState2Height;
- (double)landscapeState2CornerRadius;
@end

static NSInteger hook_axis(id self, SEL _cmd) { return 1; }

static double (*orig_glyphScaleForState)(id, SEL, NSInteger);
static double hook_glyphScaleForState(id self, SEL _cmd, NSInteger state) {
    return orig_glyphScaleForState(self, _cmd, 2);
}

static CGPoint (*orig_center)(id, SEL, NSInteger, CGSize, CGRect, BOOL);
static CGPoint hook_center(id self, SEL _cmd, NSInteger state, CGSize containerSize, CGRect bounds, BOOL useSpringData) {
    CGPoint original = orig_center(self, _cmd, state, containerSize, bounds, useSpringData);
    CGFloat screenHeight = CGRectGetHeight(UIScreen.mainScreen.bounds);
    CGFloat y = containerSize.height * 0.5 + ((screenHeight - containerSize.height) / 100.0) * 4.0;
    return CGPointMake((CGFloat)(NSInteger)original.x, (CGFloat)(NSInteger)y);
}

static void hook_updateLabels(id self, SEL _cmd, NSInteger axis, CGSize containerSize, NSInteger state, BOOL animated) {}

#define FORWARD_DOUBLE(NAME, TARGET) \
static double hook_##NAME(id self, SEL _cmd) { return ((double (*)(id, SEL))objc_msgSend)(self, @selector(TARGET)); }

FORWARD_DOUBLE(portraitState1Width, portraitState2Width)
FORWARD_DOUBLE(portraitState1Height, portraitState2Height)
FORWARD_DOUBLE(portraitState1CornerRadius, portraitState2CornerRadius)
FORWARD_DOUBLE(portraitState3Width, portraitState2Width)
FORWARD_DOUBLE(portraitState3Height, portraitState2Height)
FORWARD_DOUBLE(portraitState3CornerRadius, portraitState2CornerRadius)
FORWARD_DOUBLE(landscapeState1Width, landscapeState2Width)
FORWARD_DOUBLE(landscapeState1Height, landscapeState2Height)
FORWARD_DOUBLE(landscapeState1CornerRadius, landscapeState2CornerRadius)
FORWARD_DOUBLE(landscapeState3Width, landscapeState2Width)
FORWARD_DOUBLE(landscapeState3Height, landscapeState2Height)
FORWARD_DOUBLE(landscapeState3CornerRadius, landscapeState2CornerRadius)

static void (*orig_setLandscapeState2Width)(id, SEL, double);
static void hook_setLandscapeState2Width(id self, SEL _cmd, double value) {
    orig_setLandscapeState2Width(self, _cmd, 150.0);
}
static void (*orig_setLabelMargin)(id, SEL, double);
static void hook_setLabelMargin(id self, SEL _cmd, double value) {
    orig_setLabelMargin(self, _cmd, 100.0);
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

        Class settings = objc_getClass("SBVolumeHUDSettings");
#define HOOK_GETTER(NAME) Hook(settings, @selector(NAME), (IMP)hook_##NAME, NULL)
        HOOK_GETTER(portraitState1Width); HOOK_GETTER(portraitState1Height); HOOK_GETTER(portraitState1CornerRadius);
        HOOK_GETTER(portraitState3Width); HOOK_GETTER(portraitState3Height); HOOK_GETTER(portraitState3CornerRadius);
        HOOK_GETTER(landscapeState1Width); HOOK_GETTER(landscapeState1Height); HOOK_GETTER(landscapeState1CornerRadius);
        HOOK_GETTER(landscapeState3Width); HOOK_GETTER(landscapeState3Height); HOOK_GETTER(landscapeState3CornerRadius);
        Hook(settings, @selector(setLandscapeState2Width:), (IMP)hook_setLandscapeState2Width, (IMP *)&orig_setLandscapeState2Width);
        Hook(settings, @selector(setLabelMargin:), (IMP)hook_setLabelMargin, (IMP *)&orig_setLabelMargin);
    }
}
