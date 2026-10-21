// 隐藏通知清除按钮 · L.E
// View fallback: only notification HEADER/COALESCING CONTROL classes.
// Never install geometry hooks on NCNotificationListView/UIView or notification cards.
typedef struct {
    Class cls;
    IMP frameSetter, boundsSetter, fit, intrinsic, fitting, fittingPriorities;
    BOOL attempted, installed, complete;
} HNCViewHeightHooks;
static HNCViewHeightHooks HNCLegacyViewHooks;
static HNCViewHeightHooks HNCCoalescingViewHooks;
static HNCViewHeightHooks HNCFooterCellViewHooks;
static HNCViewHeightHooks HNCControlsViewHooks;

static BOOL HNCEncodedTypeMatches(Method method, int index, const char *expected) {
    char *type = index < 0 ? method_copyReturnType(method)
                           : method_copyArgumentType(method, (unsigned int)index);
    const char *base = HNCSkipQualifiers(type);
    size_t length = strlen(expected);
    BOOL match = strncmp(base, expected, length) == 0;
    if (match) {
        const char *tail = base + length;
        if (*tail == '+' || *tail == '-') ++tail;
        while (*tail >= '0' && *tail <= '9') ++tail;
        match = *tail == '\0';
    }
    free(type);
    return match;
}
static BOOL HNCReplaceGeometry(Class cls, const char *name, IMP replacement, IMP *original,
                                const char *result, unsigned int argc, const char **args) {
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != argc + 2 ||
        !HNCTypeMatches(method, 0, '@') || !HNCTypeMatches(method, 1, ':') ||
        !HNCEncodedTypeMatches(method, -1, result)) return NO;
    for (unsigned int i = 0; i < argc; ++i) {
        if (!HNCEncodedTypeMatches(method, (int)i + 2, args[i])) return NO;
    }
    return HNCApplyMethod(cls, selector, method, replacement, original);
}
#define HNC_DEFINE_VIEW_HEIGHTS(PREFIX, STATE) \
static void PREFIX##Frame(UIView *self, SEL cmd, CGRect value) { \
    value.size.height = 0.0; \
    ((void (*)(UIView *, SEL, CGRect))STATE.frameSetter)(self, cmd, value); \
} \
static void PREFIX##Bounds(UIView *self, SEL cmd, CGRect value) { \
    value.size.height = 0.0; \
    ((void (*)(UIView *, SEL, CGRect))STATE.boundsSetter)(self, cmd, value); \
} \
static CGSize PREFIX##Fit(UIView *self, SEL cmd, CGSize value) { \
    CGSize result = ((CGSize (*)(UIView *, SEL, CGSize))STATE.fit)(self, cmd, value); \
    result.height = 0.0; return result; \
} \
static CGSize PREFIX##Intrinsic(UIView *self, SEL cmd) { \
    CGSize result = ((CGSize (*)(UIView *, SEL))STATE.intrinsic)(self, cmd); \
    result.height = 0.0; return result; \
} \
static CGSize PREFIX##Fitting(UIView *self, SEL cmd, CGSize value) { \
    CGSize result = ((CGSize (*)(UIView *, SEL, CGSize))STATE.fitting)(self, cmd, value); \
    result.height = 0.0; return result; \
} \
static CGSize PREFIX##FittingPriorities(UIView *self, SEL cmd, CGSize value, float horizontal, float vertical) { \
    CGSize result = ((CGSize (*)(UIView *, SEL, CGSize, float, float))STATE.fittingPriorities)(self, cmd, value, horizontal, vertical); \
    result.height = 0.0; return result; \
}
HNC_DEFINE_VIEW_HEIGHTS(HNCLegacyGeometry, HNCLegacyViewHooks)
HNC_DEFINE_VIEW_HEIGHTS(HNCCoalescingGeometry, HNCCoalescingViewHooks)
HNC_DEFINE_VIEW_HEIGHTS(HNCFooterCellGeometry, HNCFooterCellViewHooks)
HNC_DEFINE_VIEW_HEIGHTS(HNCControlsViewGeometry, HNCControlsViewHooks)
#undef HNC_DEFINE_VIEW_HEIGHTS

static BOOL HNCInstallViewHeightHooks(Class cls, HNCViewHeightHooks *state,
                                      IMP frame, IMP bounds, IMP fit, IMP intrinsic,
                                      IMP fitting, IMP priorities) {
    if (state->attempted) return state->complete;
    if (!cls) return NO;
    state->cls = cls;
    state->attempted = YES;
    const char *rectArgs[] = { @encode(CGRect) };
    const char *sizeArgs[] = { @encode(CGSize) };
    const char *priorityArgs[] = { @encode(CGSize), @encode(float), @encode(float) };
    BOOL frameOK = HNCReplaceGeometry(cls, "setFrame:", frame, &state->frameSetter,
                                     @encode(void), 1, rectArgs);
    BOOL boundsOK = HNCReplaceGeometry(cls, "setBounds:", bounds, &state->boundsSetter,
                                      @encode(void), 1, rectArgs);
    BOOL fitOK = HNCReplaceGeometry(cls, "sizeThatFits:", fit, &state->fit, @encode(CGSize), 1, sizeArgs);
    BOOL intrinsicOK = HNCReplaceGeometry(cls, "intrinsicContentSize", intrinsic, &state->intrinsic, @encode(CGSize), 0, NULL);
    BOOL fittingOK = HNCReplaceGeometry(cls, "systemLayoutSizeFittingSize:", fitting, &state->fitting,
                       @encode(CGSize), 1, sizeArgs);
    BOOL prioritiesOK = HNCReplaceGeometry(cls, "systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:",
                       priorities, &state->fittingPriorities, @encode(CGSize), 3, priorityArgs);
    state->installed = frameOK && boundsOK;
    state->complete = state->installed && fitOK && intrinsicOK && fittingOK && prioritiesOK;
    return state->complete;
}
static BOOL HNCViewIsHeaderClass(UIView *view, Class target) {
    if (!target) return NO;
    for (Class cls = object_getClass(view); cls; cls = class_getSuperclass(cls)) {
        if (cls == target) return YES;
    }
    return NO;
}
static void HNCCollapseHeader(UIView *view) {
    if ((!HNCLegacyViewHooks.installed || !HNCViewIsHeaderClass(view, HNCLegacyViewHooks.cls)) &&
        (!HNCCoalescingViewHooks.installed || !HNCViewIsHeaderClass(view, HNCCoalescingViewHooks.cls)) &&
        (!HNCFooterCellViewHooks.installed || !HNCViewIsHeaderClass(view, HNCFooterCellViewHooks.cls)) &&
        (!HNCControlsViewHooks.installed || !HNCViewIsHeaderClass(view, HNCControlsViewHooks.cls))) return;
    // Work in local bounds rather than shifting the parent/list or changing sibling frames.
    CGRect bounds = view.bounds;
    if (bounds.size.height != 0.0) {
        bounds.size.height = 0.0;
        view.bounds = bounds;
    }
}
