// 隐藏通知清除按钮 · L.E
// Included after HNCValid/HNCReplace. This changes HEADER height, not card spacing.
static Class HNCGapLegacyHeader;
static Class HNCGapCoalescingHeader;
static IMP HNCOrigListHeaderHeight;
static BOOL HNCListSpacingInstalled;

typedef struct {
    IMP dataSourceHeight;
    IMP cachedHeight;
    BOOL attempted;
    BOOL installed;
} HNCHeaderHeightHooks;
static HNCHeaderHeightHooks HNCGroupHeightHooks;
static HNCHeaderHeightHooks HNCSectionHeightHooks;

static BOOL HNCClassInheritsFrom(Class cls, Class base) {
    if (!base) return NO;
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == base) return YES;
    }
    return NO;
}
static BOOL HNCHeaderIsSuppressed(id header) {
    if (!header) return NO;
    Class cls = object_getClass(header);
    return (HNCCoalescingInstalled && HNCClassInheritsFrom(cls, HNCGapCoalescingHeader)) ||
           (HNCLegacyInstalled && HNCClassInheritsFrom(cls, HNCGapLegacyHeader));
}
// Do not use KVC, raw ivar offsets or instantiate a missing header during a size query.
static id HNCReadObject(id object, const char *accessor) {
    if (!object) return nil;
    SEL selector = sel_registerName(accessor);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!HNCValid(method, '@', "")) return nil;
    return ((id (*)(id, SEL))method_getImplementation(method))(object, selector);
}
static BOOL HNCProviderHasSuppressedHeader(id owner, id list, const char *listAccessor) {
    if (!list || HNCReadObject(owner, listAccessor) != list) return NO;
    return HNCHeaderIsSuppressed(HNCReadObject(owner, "headerView")) ||
           HNCHeaderIsSuppressed(HNCReadObject(list, "headerView"));
}
static double HNCListHeaderHeight(id self, SEL cmd) {
    // Preserve original work: it may configure/retrieve the header on first use.
    double original = ((double (*)(id, SEL))HNCOrigListHeaderHeight)(self, cmd);
    if (HNCHeaderIsSuppressed(HNCReadObject(self, "headerView"))) return 0.0;
    id owner = HNCReadObject(self, "dataSource");
    if (HNCProviderHasSuppressedHeader(owner, self, "groupListView") ||
        HNCProviderHasSuppressedHeader(owner, self, "sectionListView")) return 0.0;
    return original;
}
#define HNC_DEFINE_PROVIDER_HEIGHTS(PREFIX, STATE, LIST_ACCESSOR) \
static double PREFIX##DataSourceHeight(id self, SEL cmd, id list, double width) { \
    double original = ((double (*)(id, SEL, id, double))STATE.dataSourceHeight)(self, cmd, list, width); \
    return HNCProviderHasSuppressedHeader(self, list, LIST_ACCESSOR) ? 0.0 : original; \
} \
static double PREFIX##CachedHeight(id self, SEL cmd) { \
    double original = ((double (*)(id, SEL))STATE.cachedHeight)(self, cmd); \
    return HNCHeaderIsSuppressed(HNCReadObject(self, "headerView")) ? 0.0 : original; \
}
HNC_DEFINE_PROVIDER_HEIGHTS(HNCGroup, HNCGroupHeightHooks, "groupListView")
HNC_DEFINE_PROVIDER_HEIGHTS(HNCSection, HNCSectionHeightHooks, "sectionListView")
#undef HNC_DEFINE_PROVIDER_HEIGHTS

static BOOL HNCInstallProviderHeightHooks(Class cls, HNCHeaderHeightHooks *state,
                                         IMP dataSource, IMP getter) {
    if (state->attempted) return state->installed;
    if (!cls) return NO;
    // Missing/mismatched selectors are not guessed. Every installed IMP has its own slot.
    state->installed = HNCReplace(cls,
        sel_registerName("headerViewHeightForNotificationList:withWidth:"),
        dataSource, &state->dataSourceHeight, 'd', "@d");
    HNCReplace(cls, sel_registerName("headerViewHeight"),
        getter, &state->cachedHeight, 'd', "");
    // Keep raw cache/setter untouched: a reused owner can later display another header type.
    state->attempted = YES;
    return state->installed;
}
static BOOL HNCInstallSpacing(void) {
    if (!HNCGapLegacyHeader) HNCGapLegacyHeader = objc_lookUpClass("NCNotificationListSectionHeaderView");
    if (!HNCGapCoalescingHeader) HNCGapCoalescingHeader = objc_lookUpClass("NCNotificationListCoalescingHeaderCell");
    if (!HNCListSpacingInstalled) {
        Class cls = objc_lookUpClass("NCNotificationListView");
        if (cls) HNCListSpacingInstalled = HNCReplace(cls,
            sel_registerName("_headerViewHeight"), (IMP)HNCListHeaderHeight,
            &HNCOrigListHeaderHeight, 'd', "");
    }
    BOOL group = HNCInstallProviderHeightHooks(objc_lookUpClass("NCNotificationListPresentableGroup"),
        &HNCGroupHeightHooks, (IMP)HNCGroupDataSourceHeight,
        (IMP)HNCGroupCachedHeight);
    BOOL section = HNCInstallProviderHeightHooks(objc_lookUpClass("NCNotificationStructuredSectionList"),
        &HNCSectionHeightHooks, (IMP)HNCSectionDataSourceHeight,
        (IMP)HNCSectionCachedHeight);
    return HNCListSpacingInstalled && group && section;
}
