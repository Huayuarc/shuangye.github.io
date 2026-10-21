// 隐藏通知清除按钮 · L.E · 1.0.4
// Footer spacing only: do not change card size, whole-list geometry, or raw size caches.
static IMP HNCOrigListFooterHeight;
static IMP HNCOrigListFooterMargin;
static IMP HNCOrigGroupFooterHeight;
static IMP HNCOrigGroupFooterCachedHeight;
static BOOL HNCListFooterSpacingAttempted;
static BOOL HNCGroupFooterSpacingAttempted;
static BOOL HNCListFooterSpacingInstalled;
static BOOL HNCGroupFooterSpacingInstalled;

static BOOL HNCProviderHasSuppressedFooter(id owner, id list) {
    if (!list || HNCReadObject(owner, "groupListView") != list) return NO;
    id actualFooter = HNCReadObject(list, "footerView");
    if (actualFooter) return HNCFooterIsSuppressed(actualFooter);
    return HNCFooterIsSuppressed(HNCReadObject(owner, "footerView"));
}
static BOOL HNCListHasSuppressedFooter(id list) {
    id actualFooter = HNCReadObject(list, "footerView");
    if (actualFooter) return HNCFooterIsSuppressed(actualFooter);
    return HNCProviderHasSuppressedFooter(HNCReadObject(list, "dataSource"), list);
}
static double HNCListFooterHeight(id self, SEL cmd) {
    double original = ((double (*)(id, SEL))HNCOrigListFooterHeight)(self, cmd);
    return HNCListHasSuppressedFooter(self) ? 0.0 : original;
}
static double HNCListFooterMargin(id self, SEL cmd) {
    double original = ((double (*)(id, SEL))HNCOrigListFooterMargin)(self, cmd);
    return HNCListHasSuppressedFooter(self) ? 0.0 : original;
}
static double HNCGroupFooterHeight(id self, SEL cmd, id list, double width) {
    double original = ((double (*)(id, SEL, id, double))HNCOrigGroupFooterHeight)(self, cmd, list, width);
    return HNCProviderHasSuppressedFooter(self, list) ? 0.0 : original;
}
static double HNCGroupFooterCachedHeight(id self, SEL cmd) {
    double original = ((double (*)(id, SEL))HNCOrigGroupFooterCachedHeight)(self, cmd);
    id list = HNCReadObject(self, "groupListView");
    id actualFooter = HNCReadObject(list, "footerView");
    if (actualFooter) return HNCFooterIsSuppressed(actualFooter) ? 0.0 : original;
    return HNCFooterIsSuppressed(HNCReadObject(self, "footerView")) ? 0.0 : original;
}
static BOOL HNCInstallFooterSpacing(void) {
    if (!HNCListFooterSpacingAttempted) {
        Class cls = objc_lookUpClass("NCNotificationListView");
        if (cls) {
            HNCListFooterSpacingAttempted = YES;
            HNCListFooterSpacingInstalled = HNCReplace(cls, sel_registerName("_footerViewHeight"),
                (IMP)HNCListFooterHeight, &HNCOrigListFooterHeight, 'd', "");
            BOOL margin = HNCReplace(cls, sel_registerName("footerViewVerticalMargin"),
                (IMP)HNCListFooterMargin, &HNCOrigListFooterMargin, 'd', "");
            HNCListFooterSpacingInstalled = HNCListFooterSpacingInstalled && margin;
        }
    }
    if (!HNCGroupFooterSpacingAttempted) {
        Class cls = objc_lookUpClass("NCNotificationListPresentableGroup");
        if (cls) {
            HNCGroupFooterSpacingAttempted = YES;
            HNCGroupFooterSpacingInstalled = HNCReplace(cls,
                sel_registerName("footerViewHeightForNotificationList:withWidth:"),
                (IMP)HNCGroupFooterHeight, &HNCOrigGroupFooterHeight, 'd', "@d");
            BOOL getter = HNCReplace(cls, sel_registerName("footerViewHeight"),
                (IMP)HNCGroupFooterCachedHeight, &HNCOrigGroupFooterCachedHeight, 'd', "");
            HNCGroupFooterSpacingInstalled = HNCGroupFooterSpacingInstalled && getter;
        }
    }
    return HNCListFooterSpacingInstalled && HNCGroupFooterSpacingInstalled;
}
