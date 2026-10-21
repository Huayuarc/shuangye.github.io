// HideNCHeaders - personal UI customization, iOS 16.
// Only notification HEADER and COALESCING CONTROL views are concealed. Cards are untouched.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

static IMP HNCOrigSetHidden;
static IMP HNCOrigSetAlpha;
static IMP HNCOrigLayout;
static IMP HNCOrigMoveToWindow;
static IMP HNCOrigMoveToSuperview;
static IMP HNCCoalescingOrigSetHidden;
static IMP HNCCoalescingOrigSetAlpha;
static IMP HNCCoalescingOrigLayout;
static IMP HNCCoalescingOrigMoveToWindow;
static IMP HNCCoalescingOrigMoveToSuperview;
static BOOL HNCLegacyInstalled;
static BOOL HNCCoalescingInstalled;
static BOOL HNCLegacyAttempted;
static BOOL HNCCoalescingAttempted;

static void HNCCollapseHeader(UIView *view);

// UIView visibility is applied, not just reported by a getter. Hidden views don't receive hits.
static void HNCConceal(UIView *view) {
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
    view.isAccessibilityElement = NO;
    HNCCollapseHeader(view);
}
static void HNCSetHidden(UIView *self, SEL cmd, BOOL ignored) {
    (void)ignored;
    ((void (*)(UIView *, SEL, BOOL))HNCOrigSetHidden)(self, cmd, YES);
}
static void HNCSetAlpha(UIView *self, SEL cmd, CGFloat ignored) {
    (void)ignored;
    ((void (*)(UIView *, SEL, CGFloat))HNCOrigSetAlpha)(self, cmd, 0.0);
}
static void HNCLayout(UIView *self, SEL cmd) {
    ((void (*)(UIView *, SEL))HNCOrigLayout)(self, cmd);
    HNCConceal(self);
}
static void HNCMoveToWindow(UIView *self, SEL cmd) {
    ((void (*)(UIView *, SEL))HNCOrigMoveToWindow)(self, cmd);
    HNCConceal(self);
}
static void HNCMoveToSuperview(UIView *self, SEL cmd) {
    ((void (*)(UIView *, SEL))HNCOrigMoveToSuperview)(self, cmd);
    HNCConceal(self);
}
static double HNCHeight(id self, SEL cmd, double width, id title, BOOL collapse) {
    (void)self; (void)cmd; (void)width; (void)title; (void)collapse;
    return 0.0;
}

// Independent wrappers are intentional: sharing saved IMPs across two unrelated classes
// would call the wrong original implementation or recurse through an inherited wrapper.
static void HNCCoalescingSetHidden(UIView *self, SEL cmd, BOOL ignored) {
    (void)ignored;
    ((void (*)(UIView *, SEL, BOOL))HNCCoalescingOrigSetHidden)(self, cmd, YES);
}
static void HNCCoalescingSetAlpha(UIView *self, SEL cmd, CGFloat ignored) {
    (void)ignored;
    ((void (*)(UIView *, SEL, CGFloat))HNCCoalescingOrigSetAlpha)(self, cmd, 0.0);
}
static void HNCCoalescingLayout(UIView *self, SEL cmd) {
    ((void (*)(UIView *, SEL))HNCCoalescingOrigLayout)(self, cmd);
    HNCConceal(self);
}
static void HNCCoalescingMoveToWindow(UIView *self, SEL cmd) {
    ((void (*)(UIView *, SEL))HNCCoalescingOrigMoveToWindow)(self, cmd);
    HNCConceal(self);
}
static void HNCCoalescingMoveToSuperview(UIView *self, SEL cmd) {
    ((void (*)(UIView *, SEL))HNCCoalescingOrigMoveToSuperview)(self, cmd);
    HNCConceal(self);
}
static double HNCCoalescingHeight(id self, SEL cmd, double width, id title) {
    (void)self; (void)cmd; (void)width; (void)title;
    return 0.0;
}

static const char *HNCSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) ++type;
    return type;
}
static BOOL HNCTypeMatches(Method method, int index, char expected) {
    char *type = index < 0 ? method_copyReturnType(method)
                           : method_copyArgumentType(method, (unsigned int)index);
    const char *base = HNCSkipQualifiers(type);
    BOOL match = base[0] == expected;
    // iOS arm64 BOOL encodes as B; older class-dump files may represent it as c.
    if (expected == 'B') match = base[0] == 'B' || base[0] == 'c';
    if (match) {
        // Some runtime versions retain stack/frame offsets in copied types (e.g. B16).
        // Only decimal offset suffixes are allowed; pointers, blocks and aggregates fail.
        const char *tail = base + 1;
        if (*tail == '+' || *tail == '-') ++tail;
        while (*tail >= '0' && *tail <= '9') ++tail;
        match = *tail == '\0';
    }
    free(type);
    return match;
}
static BOOL HNCValid(Method method, char result, const char *arguments) {
    if (!method || method_getNumberOfArguments(method) != strlen(arguments) + 2 ||
        !HNCTypeMatches(method, -1, result) ||
        !HNCTypeMatches(method, 0, '@') || !HNCTypeMatches(method, 1, ':')) return NO;
    for (size_t i = 0; arguments[i]; ++i) {
        if (!HNCTypeMatches(method, (int)i + 2, arguments[i])) return NO;
    }
    return YES;
}
// Add an override on THIS class for inherited methods. Never replace UIView's method.
// Objective-C runtime APIs handle signed IMPs correctly on the real arm64e ABI.
// main queue installation is completed before any view callback can run on that queue.
static BOOL HNCApplyMethod(Class cls, SEL selector, Method method, IMP replacement, IMP *original) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method local = NULL;
    for (unsigned int i = 0; i < count; ++i) {
        if (strcmp(sel_getName(method_getName(methods[i])), sel_getName(selector)) == 0) {
            local = methods[i];
            break;
        }
    }
    free(methods);
    IMP previous = method_getImplementation(local ? local : method);
    if (original) *original = previous;
    if (!local) {
        // If addition fails, fail closed. Never fall back to mutating an inherited method.
        return class_addMethod(cls, method_getName(method), replacement, method_getTypeEncoding(method));
    }
    previous = method_setImplementation(local, replacement);
    if (original) *original = previous;
    return YES;
}
static BOOL HNCReplace(Class cls, SEL selector, IMP replacement, IMP *original,
                       char result, const char *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!HNCValid(method, result, arguments)) return NO;
    return HNCApplyMethod(cls, selector, method, replacement, original);
}
#include "HNCViewFallback.h"

static BOOL HNCInstallLegacy(void) {
    if (HNCLegacyAttempted) return HNCLegacyInstalled;
    Class cls = objc_lookUpClass("NCNotificationListSectionHeaderView");
    if (!cls || ![cls isSubclassOfClass:[UIView class]]) return NO;
    // Check both setters first, so mismatched OS versions fail closed.
    if (!HNCValid(class_getInstanceMethod(cls, @selector(setHidden:)), 'v', "B") ||
        !HNCValid(class_getInstanceMethod(cls, @selector(setAlpha:)), 'v', "d")) return NO;
    HNCLegacyAttempted = YES;
    BOOL hidden = HNCReplace(cls, @selector(setHidden:), (IMP)HNCSetHidden,
               &HNCOrigSetHidden, 'v', "B");
    BOOL alpha = HNCReplace(cls, @selector(setAlpha:), (IMP)HNCSetAlpha,
               &HNCOrigSetAlpha, 'v', "d");
    if (!hidden || !alpha) return NO;
    HNCReplace(cls, @selector(layoutSubviews), (IMP)HNCLayout,
               &HNCOrigLayout, 'v', "");
    HNCReplace(cls, @selector(didMoveToWindow), (IMP)HNCMoveToWindow,
               &HNCOrigMoveToWindow, 'v', "");
    HNCReplace(cls, @selector(didMoveToSuperview), (IMP)HNCMoveToSuperview,
               &HNCOrigMoveToSuperview, 'v', "");
    // The exact selector is verified at runtime before touching it. No global layout hooks.
    HNCReplace(object_getClass(cls),
               sel_registerName("headerHeightWithWidth:title:isShowingCollapseButton:"),
               (IMP)HNCHeight, NULL, 'd', "d@B");
    HNCLegacyInstalled = YES;
    HNCInstallViewHeightHooks(cls, &HNCLegacyViewHooks,
        (IMP)HNCLegacyGeometryFrame, (IMP)HNCLegacyGeometryBounds,
        (IMP)HNCLegacyGeometryFit, (IMP)HNCLegacyGeometryIntrinsic,
        (IMP)HNCLegacyGeometryFitting, (IMP)HNCLegacyGeometryFittingPriorities);
    return YES;
}
static BOOL HNCInstallCoalescing(void) {
    if (HNCCoalescingAttempted) return HNCCoalescingInstalled;
    Class cls = objc_lookUpClass("NCNotificationListCoalescingHeaderCell");
    if (!cls || ![cls isSubclassOfClass:[UIView class]]) return NO;
    if (!HNCValid(class_getInstanceMethod(cls, @selector(setHidden:)), 'v', "B") ||
        !HNCValid(class_getInstanceMethod(cls, @selector(setAlpha:)), 'v', "d")) return NO;
    HNCCoalescingAttempted = YES;
    BOOL hidden = HNCReplace(cls, @selector(setHidden:), (IMP)HNCCoalescingSetHidden,
               &HNCCoalescingOrigSetHidden, 'v', "B");
    BOOL alpha = HNCReplace(cls, @selector(setAlpha:), (IMP)HNCCoalescingSetAlpha,
               &HNCCoalescingOrigSetAlpha, 'v', "d");
    if (!hidden || !alpha) return NO;
    HNCReplace(cls, @selector(layoutSubviews), (IMP)HNCCoalescingLayout,
               &HNCCoalescingOrigLayout, 'v', "");
    HNCReplace(cls, @selector(didMoveToWindow), (IMP)HNCCoalescingMoveToWindow,
               &HNCCoalescingOrigMoveToWindow, 'v', "");
    HNCReplace(cls, @selector(didMoveToSuperview), (IMP)HNCCoalescingMoveToSuperview,
               &HNCCoalescingOrigMoveToSuperview, 'v', "");
    BOOL height = HNCReplace(object_getClass(cls),
               sel_registerName("coalescingHeaderCellHeightForWidth:title:"),
               (IMP)HNCCoalescingHeight, NULL, 'd', "d@");
    HNCCoalescingInstalled = YES;
    HNCInstallViewHeightHooks(cls, &HNCCoalescingViewHooks,
        (IMP)HNCCoalescingGeometryFrame, (IMP)HNCCoalescingGeometryBounds,
        (IMP)HNCCoalescingGeometryFit, (IMP)HNCCoalescingGeometryIntrinsic,
        (IMP)HNCCoalescingGeometryFitting, (IMP)HNCCoalescingGeometryFittingPriorities);
    NSLog(@"[隐藏通知清除按钮 1.0.4 / L.E] CoalescingHeaderCell installed; height=%d", height);
    return YES;
}
#include "HNCSpacing.h"
#include "HNCFooterControls.h"
#include "HNCFooterSpacing.h"

static void HNCAttempt(unsigned int attempt) {
    // Never let successful installation of the legacy class short-circuit the new class.
    BOOL coalescing = HNCInstallCoalescing();
    BOOL legacy = HNCInstallLegacy();
    BOOL spacing = HNCInstallSpacing();
    BOOL footer = HNCInstallFooterCell();
    BOOL controls = HNCInstallStandaloneControls();
    BOOL footerSpacing = HNCInstallFooterSpacing();
    if (coalescing && legacy && spacing && footer && controls && footerSpacing) return;
    if (attempt >= 12) {
        NSLog(@"[隐藏通知清除按钮 1.0.4 / L.E] install: coalescing=%d legacy=%d spacing=%d footer=%d controls=%d footerSpacing=%d", coalescing, legacy, spacing, footer, controls, footerSpacing);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ HNCAttempt(attempt + 1); });
}
__attribute__((constructor)) static void HNCStart(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        // Framework classes may be registered after tweak initializers. Bounded startup retry only.
        dispatch_async(dispatch_get_main_queue(), ^{ HNCAttempt(0); });
    }
}
