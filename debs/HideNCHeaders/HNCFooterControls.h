// 隐藏通知清除按钮 · L.E · 1.0.4
// Additional footer controls. No notification-card class or generic button is modified.
typedef struct {
    Class cls;
    IMP hidden, alpha, layout, window, superview;
    BOOL attempted, installed, lifecycleInstalled, complete;
} HNCControlVisibilityHooks;
static HNCControlVisibilityHooks HNCFooterCellControls;
static HNCControlVisibilityHooks HNCStandaloneControls;

#define HNC_DEFINE_CONTROL_VISIBILITY(PREFIX, STATE) \
static void PREFIX##Hidden(UIView *self, SEL cmd, BOOL ignored) { \
    (void)ignored; ((void (*)(UIView *, SEL, BOOL))STATE.hidden)(self, cmd, YES); \
} \
static void PREFIX##Alpha(UIView *self, SEL cmd, CGFloat ignored) { \
    (void)ignored; ((void (*)(UIView *, SEL, CGFloat))STATE.alpha)(self, cmd, 0.0); \
} \
static void PREFIX##Layout(UIView *self, SEL cmd) { \
    ((void (*)(UIView *, SEL))STATE.layout)(self, cmd); HNCConceal(self); \
} \
static void PREFIX##Window(UIView *self, SEL cmd) { \
    ((void (*)(UIView *, SEL))STATE.window)(self, cmd); HNCConceal(self); \
} \
static void PREFIX##Superview(UIView *self, SEL cmd) { \
    ((void (*)(UIView *, SEL))STATE.superview)(self, cmd); HNCConceal(self); \
}
HNC_DEFINE_CONTROL_VISIBILITY(HNCFooterCell, HNCFooterCellControls)
HNC_DEFINE_CONTROL_VISIBILITY(HNCStandalone, HNCStandaloneControls)
#undef HNC_DEFINE_CONTROL_VISIBILITY

static BOOL HNCInstallControlVisibility(Class cls, HNCControlVisibilityHooks *state,
                                        IMP hidden, IMP alpha, IMP layout, IMP window, IMP superview) {
    if (state->attempted) return state->installed;
    if (!cls || ![cls isSubclassOfClass:[UIView class]]) return NO;
    if (!HNCValid(class_getInstanceMethod(cls, @selector(setHidden:)), 'v', "B") ||
        !HNCValid(class_getInstanceMethod(cls, @selector(setAlpha:)), 'v', "d")) return NO;
    state->cls = cls;
    state->attempted = YES;
    BOOL hiddenOK = HNCReplace(cls, @selector(setHidden:), hidden, &state->hidden, 'v', "B");
    BOOL alphaOK = HNCReplace(cls, @selector(setAlpha:), alpha, &state->alpha, 'v', "d");
    if (!hiddenOK || !alphaOK) return NO;
    BOOL layoutOK = HNCReplace(cls, @selector(layoutSubviews), layout, &state->layout, 'v', "");
    BOOL windowOK = HNCReplace(cls, @selector(didMoveToWindow), window, &state->window, 'v', "");
    BOOL superviewOK = HNCReplace(cls, @selector(didMoveToSuperview), superview, &state->superview, 'v', "");
    state->lifecycleInstalled = layoutOK && windowOK && superviewOK;
    state->installed = YES;
    return YES;
}
static double HNCFooterCellClassHeight(id self, SEL cmd, BOOL showControls) {
    (void)self; (void)cmd; (void)showControls;
    return 0.0;
}
static double HNCControlsPreferredHeight(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0.0;
}
static BOOL HNCInstallFooterCell(void) {
    if (HNCFooterCellControls.attempted) return HNCFooterCellControls.complete;
    Class cls = objc_lookUpClass("NCNotificationListCoalescingControlsCell");
    if (!HNCInstallControlVisibility(cls, &HNCFooterCellControls,
        (IMP)HNCFooterCellHidden, (IMP)HNCFooterCellAlpha, (IMP)HNCFooterCellLayout,
        (IMP)HNCFooterCellWindow, (IMP)HNCFooterCellSuperview)) return NO;
    BOOL heightOK = HNCReplace(object_getClass(cls),
        sel_registerName("coalescingControlsCellHeightShowingCoalescingControls:"),
        (IMP)HNCFooterCellClassHeight, NULL, 'd', "B");
    BOOL geometryOK = HNCInstallViewHeightHooks(cls, &HNCFooterCellViewHooks,
        (IMP)HNCFooterCellGeometryFrame, (IMP)HNCFooterCellGeometryBounds,
        (IMP)HNCFooterCellGeometryFit, (IMP)HNCFooterCellGeometryIntrinsic,
        (IMP)HNCFooterCellGeometryFitting, (IMP)HNCFooterCellGeometryFittingPriorities);
    HNCFooterCellControls.complete = heightOK && geometryOK && HNCFooterCellControls.lifecycleInstalled;
    return HNCFooterCellControls.complete;
}
static BOOL HNCInstallStandaloneControls(void) {
    if (HNCStandaloneControls.attempted) return HNCStandaloneControls.complete;
    Class cls = objc_lookUpClass("NCNotificationListCoalescingControlsView");
    if (!HNCInstallControlVisibility(cls, &HNCStandaloneControls,
        (IMP)HNCStandaloneHidden, (IMP)HNCStandaloneAlpha, (IMP)HNCStandaloneLayout,
        (IMP)HNCStandaloneWindow, (IMP)HNCStandaloneSuperview)) return NO;
    BOOL heightOK = HNCReplace(object_getClass(cls), sel_registerName("preferredHeight"),
        (IMP)HNCControlsPreferredHeight, NULL, 'd', "");
    BOOL geometryOK = HNCInstallViewHeightHooks(cls, &HNCControlsViewHooks,
        (IMP)HNCControlsViewGeometryFrame, (IMP)HNCControlsViewGeometryBounds,
        (IMP)HNCControlsViewGeometryFit, (IMP)HNCControlsViewGeometryIntrinsic,
        (IMP)HNCControlsViewGeometryFitting, (IMP)HNCControlsViewGeometryFittingPriorities);
    HNCStandaloneControls.complete = heightOK && geometryOK && HNCStandaloneControls.lifecycleInstalled;
    return HNCStandaloneControls.complete;
}
static BOOL HNCFooterIsSuppressed(id view) {
    if (!view) return NO;
    return (HNCFooterCellControls.installed && HNCViewIsHeaderClass(view, HNCFooterCellControls.cls)) ||
           (HNCStandaloneControls.installed && HNCViewIsHeaderClass(view, HNCStandaloneControls.cls));
}
