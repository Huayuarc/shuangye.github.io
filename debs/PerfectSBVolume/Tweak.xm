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

static double CompactWidth(void) {
    CGFloat shortSide = MIN(CGRectGetWidth(UIScreen.mainScreen.bounds), CGRectGetHeight(UIScreen.mainScreen.bounds));
    return MIN(112.0, MAX(96.0, shortSide * 0.25));
}
static double CompactHeight(void) { return 12.0; }
static double CompactRadius(void) { return 6.0; }

#define WIDTH_GETTER(NAME) static double hook_##NAME(id self, SEL _cmd) { return CompactWidth(); }
#define HEIGHT_GETTER(NAME) static double hook_##NAME(id self, SEL _cmd) { return CompactHeight(); }
#define RADIUS_GETTER(NAME) static double hook_##NAME(id self, SEL _cmd) { return CompactRadius(); }

WIDTH_GETTER(portraitState1Width)
WIDTH_GETTER(portraitState2Width)
WIDTH_GETTER(portraitState3Width)
HEIGHT_GETTER(portraitState1Height)
HEIGHT_GETTER(portraitState2Height)
HEIGHT_GETTER(portraitState3Height)
RADIUS_GETTER(portraitState1CornerRadius)
RADIUS_GETTER(portraitState2CornerRadius)
RADIUS_GETTER(portraitState3CornerRadius)
WIDTH_GETTER(landscapeState1Width)
WIDTH_GETTER(landscapeState2Width)
WIDTH_GETTER(landscapeState3Width)
HEIGHT_GETTER(landscapeState1Height)
HEIGHT_GETTER(landscapeState2Height)
HEIGHT_GETTER(landscapeState3Height)
RADIUS_GETTER(landscapeState1CornerRadius)
RADIUS_GETTER(landscapeState2CornerRadius)
RADIUS_GETTER(landscapeState3CornerRadius)

static void (*orig_setLandscapeState2Width)(id, SEL, double);
static void hook_setLandscapeState2Width(id self, SEL _cmd, double value) {
    orig_setLandscapeState2Width(self, _cmd, CompactWidth());
}
static void (*orig_setLabelMargin)(id, SEL, double);
static void hook_setLabelMargin(id self, SEL _cmd, double value) {
    orig_setLabelMargin(self, _cmd, MIN(value, 8.0));
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
        HOOK_GETTER(portraitState2Width); HOOK_GETTER(portraitState2Height); HOOK_GETTER(portraitState2CornerRadius);
        HOOK_GETTER(portraitState3Width); HOOK_GETTER(portraitState3Height); HOOK_GETTER(portraitState3CornerRadius);
        HOOK_GETTER(landscapeState1Width); HOOK_GETTER(landscapeState1Height); HOOK_GETTER(landscapeState1CornerRadius);
        HOOK_GETTER(landscapeState2Width); HOOK_GETTER(landscapeState2Height); HOOK_GETTER(landscapeState2CornerRadius);
        HOOK_GETTER(landscapeState3Width); HOOK_GETTER(landscapeState3Height); HOOK_GETTER(landscapeState3CornerRadius);
        Hook(settings, @selector(setLandscapeState2Width:), (IMP)hook_setLandscapeState2Width, (IMP *)&orig_setLandscapeState2Width);
        Hook(settings, @selector(setLabelMargin:), (IMP)hook_setLabelMargin, (IMP *)&orig_setLabelMargin);
    }
}
