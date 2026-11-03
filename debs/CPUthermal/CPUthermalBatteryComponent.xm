// CPUthermal 电池维修/部件提示屏蔽
// isolation.24：两份还原样本并入单一开关 suppressBatteryServiceWarnings。
//   NoAppleMobileRepair：BatteryUIResourceClass、BatteryUIController、
//     FLGroupViewModelImpl、SystemHealthUI、SBIconController
//   NoPreferencesTips：PSUIPrefsListController、PSGAboutDataSource、
//     SBApplication、BSUIBadgeController
// 只改变 UI 呈现，不写入电池健康数据、不改变硬件保护。

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <CPUthermalPaths.h>

// Logos 只生成 @class 前置声明；这里给出真实接口，供语句级消息调用通过编译。
@interface PSSpecifier : NSObject
- (NSString *)name;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSGAboutController : NSObject
- (void)reloadSpecifiers;
@end

@interface CRUAlertCell : UITableViewCell
@end

static BOOL CPUthermalCellIsBatteryUnknownPart(UITableViewCell *cell);
static BOOL gCPUthermalComponentSuppressed = NO;
static int gCPUthermalComponentToken = -1;
static char kCPUthermalBatteryUnknownPartCellKey;
static char kCPUthermalCollapsedBatterySectionTableKey;
static NSInteger gCPUthermalBatteryUnknownPartSection = NSNotFound;

static UITableView *CPUthermalContainingTableView(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UITableView class]]) return (UITableView *)candidate;
    }
    return nil;
}

static void CPUthermalRecordBatteryUnknownPartSection(UITableViewCell *cell) {
    UITableView *table = CPUthermalContainingTableView(cell);
    NSIndexPath *indexPath = [table indexPathForCell:cell];
    if (!table || !indexPath) return;
    gCPUthermalBatteryUnknownPartSection = indexPath.section;
    if ([objc_getAssociatedObject(table, &kCPUthermalCollapsedBatterySectionTableKey) boolValue]) return;
    objc_setAssociatedObject(table, &kCPUthermalCollapsedBatterySectionTableKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        [table beginUpdates];
        [table endUpdates];
    });
}

static void CPUthermalMarkBatteryUnknownPartCell(UITableViewCell *cell) {
    if (!cell || !CPUthermalCellIsBatteryUnknownPart(cell)) return;
    objc_setAssociatedObject(cell, &kCPUthermalBatteryUnknownPartCellKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL CPUthermalCellMarkedBatteryUnknownPart(UITableViewCell *cell) {
    return [objc_getAssociatedObject(cell, &kCPUthermalBatteryUnknownPartCellKey) boolValue];
}

static BOOL CPUthermalComponentSuppressionEnabled(void) {
    return __atomic_load_n(&gCPUthermalComponentSuppressed, __ATOMIC_ACQUIRE);
}

static void CPUthermalReloadComponentSuppression(void) {
    @autoreleasepool {
        NSDictionary *prefs = CPUthermalReadPrefsSnapshot();
        id value = prefs[S("suppressBatteryServiceWarnings")];
        BOOL enabled = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
        // 兼容 isolation.23 曾独立存在的部件开关。
        if (!enabled) {
            id legacy = prefs[S("suppressComponentWarning")];
            enabled = [legacy respondsToSelector:@selector(boolValue)] ? [legacy boolValue] : NO;
        }
        __atomic_store_n(&gCPUthermalComponentSuppressed, enabled, __ATOMIC_RELEASE);
    }
}

static dispatch_queue_t CPUthermalComponentQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huayuarc.cputhermal.component", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static BOOL CPUthermalIsBatteryWarningItem(id item) {
    if (!item) return NO;
    NSString *identifier = nil;
    if ([item respondsToSelector:@selector(clientIdentifier)])
        identifier = [item performSelector:@selector(clientIdentifier)];
    else if ([item respondsToSelector:@selector(bundleIdentifier)])
        identifier = [item performSelector:@selector(bundleIdentifier)];
    if ([identifier isEqualToString:S("com.apple.mobilerepair")] ||
        [identifier isEqualToString:S("com.apple.SoftwareUpdateServices")]) return YES;

    NSString *label = nil;
    NSString *detail = nil;
    if ([item respondsToSelector:@selector(name)]) label = [item performSelector:@selector(name)];
    if (!label.length && [item respondsToSelector:@selector(label)])
        label = [item performSelector:@selector(label)];
    if ([item respondsToSelector:@selector(detailText)])
        detail = [item performSelector:@selector(detailText)];
    for (NSString *text in @[ label ?: S(""), detail ?: S("") ]) {
        if ([text containsString:S("未知部件")] || [text containsString:S("Unknown Part")] ||
            [text containsString:S("Important Battery Message")] ||
            [text containsString:S("重要电池信息")] ||
            [text containsString:S("电池维修")] || [text containsString:S("Battery Service")])
            return YES;
    }
    return NO;
}

// 关于本机「部件和服务历史记录」分组标题/页脚判定。
static BOOL CPUthermalIsPartsSectionTitle(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    return [text containsString:S("部件和服务历史")] ||
           [text containsString:S("部件与服务历史")] ||
           [text containsString:S("Parts and Service")];
}

static BOOL CPUthermalTextLooksLikeUnknownPart(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    return [text containsString:S("未知部件")] ||
           [text containsString:S("Unknown Part")] ||
           [text containsString:S("非正品")] ||
           [text containsString:S("Non-Genuine")] ||
           [text containsString:S("无法确定")];
}

// CRUAlertCell 的文案：左"电池"，右"未知部件 ⚠️"。两者同时命中才隐藏。
static BOOL CPUthermalCellIsBatteryUnknownPart(UITableViewCell *cell) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return NO;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    @try {
        if (cell.textLabel.text.length) [texts addObject:cell.textLabel.text];
        if (cell.detailTextLabel.text.length) [texts addObject:cell.detailTextLabel.text];
        for (UIView *sub in cell.contentView.subviews) {
            if (![sub isKindOfClass:[UILabel class]]) continue;
            NSString *t = ((UILabel *)sub).text;
            if (t.length) [texts addObject:t];
        }
    } @catch (...) {
        return NO;
    }
    BOOL hasUnknown = NO, hasBattery = NO;
    for (NSString *t in texts) {
        if (CPUthermalTextLooksLikeUnknownPart(t)) hasUnknown = YES;
        if ([t containsString:S("电池")] || [t containsString:S("Battery")]) hasBattery = YES;
    }
    return hasUnknown && hasBattery;
}

// 兜底：遍历关于本机表格，隐藏命中行并把该分组头/页脚一起收起。
static void CPUthermalHideBatteryUnknownPartRows(id controller) {
    UITableView *table = nil;
    @try {
        if ([controller respondsToSelector:@selector(table)]) table = [controller performSelector:@selector(table)];
    } @catch (...) {
        return;
    }
    if (![table isKindOfClass:[UITableView class]]) return;

    NSInteger sections = [table numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        BOOL hit = NO;
        NSInteger rows = [table numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            UITableViewCell *cell = [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
            if (!cell) continue;
            if (CPUthermalCellIsBatteryUnknownPart(cell)) {
                cell.hidden = YES;
                cell.alpha = 0;
                cell.accessoryType = UITableViewCellAccessoryNone;
                hit = YES;
            }
        }
        if (!hit) continue;
        UIView *header = [table headerViewForSection:s];
        UIView *footer = [table footerViewForSection:s];
        header.hidden = YES;
        footer.hidden = YES;
    }
}

static void CPUthermalHideBatteryUnknownPartRows(id controller);

// 开关切换后立刻处理当前已打开的"关于本机"页面（无需退出重进）。
static void CPUthermalHideInVisibleAboutPages(void) {
    @try {
        UIWindow *window = nil;
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (!window) window = UIApplication.sharedApplication.windows.firstObject;
        UIViewController *root = window.rootViewController;
        NSMutableArray<UIViewController *> *stack = [NSMutableArray array];
        if (root) [stack addObject:root];
        while (stack.count) {
            UIViewController *vc = stack.firstObject;
            [stack removeObjectAtIndex:0];
            NSString *name = NSStringFromClass([vc class]);
            if ([name containsString:S("PSGAboutController")]) {
                CPUthermalHideBatteryUnknownPartRows(vc);
            }
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]])
                [stack addObjectsFromArray:((UINavigationController *)vc).viewControllers];
            if ([vc isKindOfClass:[UITabBarController class]])
                [stack addObjectsFromArray:((UITabBarController *)vc).viewControllers];
            [stack addObjectsFromArray:vc.childViewControllers];
        }
    } @catch (...) {
    }
}

static BOOL CPUthermalSpecifierIsBatteryUnknownPart(id spec) {
    if (!spec || ![spec respondsToSelector:@selector(name)]) return NO;
    NSString *label = nil;
    @try { label = [(PSSpecifier *)spec name]; } @catch (...) { return NO; }
    if (![label isKindOfClass:[NSString class]] || label.length == 0) return NO;
    if (![label containsString:S("电池")] && ![label containsString:S("Battery")]) return NO;

    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithObject:label];
    @try {
        for (NSString *key in @[ S("value"), S("detail"), S("footerText") ]) {
            id v = [(PSSpecifier *)spec propertyForKey:key];
            if ([v isKindOfClass:[NSString class]] && [v length]) [texts addObject:v];
        }
    } @catch (...) {
    }
    for (NSString *t in texts) {
        if (CPUthermalTextLooksLikeUnknownPart(t)) return YES;
    }
    return NO;
}

static BOOL CPUthermalSpecifierIsGroup(id spec) {
    if (!spec) return NO;
    @try {
        SEL cellTypeSelector = NSSelectorFromString(S("cellType"));
        if ([spec respondsToSelector:cellTypeSelector]) {
            NSInteger cellType = ((NSInteger (*)(id, SEL))objc_msgSend)(spec, cellTypeSelector);
            if (cellType == 0) return YES; // PSGroupCell
        }
        if ([spec respondsToSelector:@selector(propertyForKey:)]) {
            id cell = [(PSSpecifier *)spec propertyForKey:S("cell")];
            if ([cell respondsToSelector:@selector(integerValue)] && [cell integerValue] == 0)
                return YES;
        }
    } @catch (...) {
    }
    return NO;
}

// PSSpecifier 是扁平数组：每个 PSGroupCell 后跟该 section 的行。
// 暂存 group，直到看见普通行才提交；若该组只有未知部件行，则连 group 一起丢弃。
static id CPUthermalFilterAboutSpecifiers(id result) {
    if (![result isKindOfClass:[NSArray class]]) return result;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[(NSArray *)result count]];
    id pendingGroup = nil;
    BOOL pendingGroupHadVisibleRow = NO;

    for (id spec in (NSArray *)result) {
        NSString *name = nil;
        @try {
            if ([spec respondsToSelector:@selector(name)]) name = [(PSSpecifier *)spec name];
        } @catch (...) {
        }

        if (CPUthermalSpecifierIsGroup(spec)) {
            if (pendingGroup && pendingGroupHadVisibleRow) [kept addObject:pendingGroup];
            pendingGroup = spec;
            pendingGroupHadVisibleRow = NO;
            continue;
        }

        BOOL warning = CPUthermalSpecifierIsBatteryUnknownPart(spec) || CPUthermalIsBatteryWarningItem(spec);
        if (warning || CPUthermalIsPartsSectionTitle(name)) continue;

        if (pendingGroup) {
            [kept addObject:pendingGroup];
            pendingGroup = nil;
        }
        pendingGroupHadVisibleRow = YES;
        [kept addObject:spec];
    }

    if (pendingGroup && pendingGroupHadVisibleRow) [kept addObject:pendingGroup];
    return kept;
}

static id CPUthermalAboutSpecifierAtIndexPath(id controller, NSIndexPath *indexPath) {
    if (!controller || !indexPath) return nil;
    SEL selector = NSSelectorFromString(S("specifierAtIndexPath:"));
    if (![controller respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, indexPath);
    } @catch (...) {
        return nil;
    }
}

static BOOL CPUthermalAboutRowIsBatteryWarning(id controller, UITableView *table, NSIndexPath *indexPath) {
    (void)table;
    id specifier = CPUthermalAboutSpecifierAtIndexPath(controller, indexPath);
    return CPUthermalSpecifierIsBatteryUnknownPart(specifier) || CPUthermalIsBatteryWarningItem(specifier);
}

static BOOL CPUthermalAboutSectionIsBatteryWarning(id controller, NSInteger section) {
    NSIndexPath *firstRow = [NSIndexPath indexPathForRow:0 inSection:section];
    id specifier = CPUthermalAboutSpecifierAtIndexPath(controller, firstRow);
    return CPUthermalSpecifierIsBatteryUnknownPart(specifier) || CPUthermalIsBatteryWarningItem(specifier);
}

static BOOL CPUthermalIsPreferencesBundle(id object) {
    NSString *bundleID = nil;
    if ([object respondsToSelector:@selector(bundleIdentifier)])
        bundleID = [object performSelector:@selector(bundleIdentifier)];
    else if ([object respondsToSelector:@selector(applicationBundleID)])
        bundleID = [object performSelector:@selector(applicationBundleID)];
    return [bundleID isEqualToString:S("com.apple.Preferences")];
}

%group CPUthermalComponentHooks

%hook BatteryUIResourceClass

+ (int)getBatteryHealthServiceState {
    if (CPUthermalComponentSuppressionEnabled()) return 0;
    return %orig;
}

+ (int)genuineBatteryStatus {
    if (CPUthermalComponentSuppressionEnabled()) return 1;
    return %orig;
}

+ (int)getManagementState {
    if (CPUthermalComponentSuppressionEnabled()) return 2;
    return %orig;
}

%end

%hook BatteryUIController

- (id)getBatteryServiceSuggestion:(uintptr_t)suggestion {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig(suggestion);
}

- (id)setUpBatteryHealthSpecifiers {
    id result = %orig;
    if (!CPUthermalComponentSuppressionEnabled() || ![result respondsToSelector:@selector(lastObject)])
        return result;
    id last = [result lastObject];
    if ([last respondsToSelector:@selector(setProperty:forKey:)])
        [last setProperty:@NO forKey:S("enabled")];
    return result;
}

%end

%hook FLGroupViewModelImpl

- (void)addItem:(id)item {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsBatteryWarningItem(item)) return;
    %orig(item);
}

%end

%hook SystemHealthUI

+ (id)getCurrentSystemHealthInfoSpecifiers {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig;
}

- (id)getCurrentSystemHealthInfoSpecifiers {
    id result = %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return result;
    if (![result isKindOfClass:[NSArray class]]) return result;
    NSMutableArray *kept = [NSMutableArray array];
    for (id spec in (NSArray *)result) {
        if (!CPUthermalIsBatteryWarningItem(spec)) [kept addObject:spec];
    }
    return kept;
}

%end

%hook PSGAboutDataSource

- (id)nonGenuineComponentSpecifierForComponent:(id)component {
    if (CPUthermalComponentSuppressionEnabled()) return nil;
    return %orig(component);
}

%end

%hook PSUIPrefsListController

- (void)updateFollowupSpecifiersWithCompletion:(id)completion {
    if (CPUthermalComponentSuppressionEnabled()) {
        if (completion) ((void (^)(void))completion)();
        return;
    }
    %orig(completion);
}

%end

// ===== 关于本机「部件和服务历史记录」=====
// iOS 16 上这一行由 PSGAboutController 构建、渲染为 CRUAlertCell；
// PSGAboutDataSource 在部分版本不存在，故同时做数据源与 UI 两层拦截。
%hook PSGAboutController

// 数据源级：真正把「部件和服务历史」分组与未知部件行从 specifier 数组移除，
// 再触发一次 reload，避免只隐藏 cell 留下空白行。
- (id)specifiers {
    id result = %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return result;
    if (![self isKindOfClass:objc_getClass("PSGAboutController")]) return result;
    return CPUthermalFilterAboutSpecifiers(result);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *title = %orig;
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsPartsSectionTitle(title)) return nil;
    return title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *title = %orig;
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsPartsSectionTitle(title)) return nil;
    return title;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (CPUthermalComponentSuppressionEnabled() &&
        CPUthermalAboutRowIsBatteryWarning(self, tableView, indexPath)) return 0.01;
    return %orig(tableView, indexPath);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (CPUthermalComponentSuppressionEnabled() &&
        (section == gCPUthermalBatteryUnknownPartSection ||
         CPUthermalAboutSectionIsBatteryWarning(self, section))) return 0.01;
    return %orig(tableView, section);
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (CPUthermalComponentSuppressionEnabled() &&
        (section == gCPUthermalBatteryUnknownPartSection ||
         CPUthermalAboutSectionIsBatteryWarning(self, section))) return 0.01;
    return %orig(tableView, section);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return;
    if ([self respondsToSelector:@selector(reloadSpecifiers)])
        [self performSelector:@selector(reloadSpecifiers)];
    dispatch_async(dispatch_get_main_queue(), ^{ CPUthermalHideBatteryUnknownPartRows(self); });
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return;
    dispatch_async(dispatch_get_main_queue(), ^{ CPUthermalHideBatteryUnknownPartRows(self); });
}

%end

%hook CRUAlertCell

- (void)refreshCellContentsWithSpecifier:(id)specifier {
    %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return;
    CPUthermalMarkBatteryUnknownPartCell(self);
    if (CPUthermalCellMarkedBatteryUnknownPart(self)) {
        CPUthermalRecordBatteryUnknownPartSection(self);
        ((UITableViewCell *)self).hidden = YES;
        ((UITableViewCell *)self).contentView.hidden = YES;
        ((UITableViewCell *)self).accessoryType = UITableViewCellAccessoryNone;
    }
}

- (void)setSpecifier:(id)specifier {
    objc_setAssociatedObject(self, &kCPUthermalBatteryUnknownPartCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return;
    CPUthermalMarkBatteryUnknownPartCell(self);
    if (CPUthermalCellMarkedBatteryUnknownPart(self)) {
        CPUthermalRecordBatteryUnknownPartSection(self);
        ((UITableViewCell *)self).hidden = YES;
        ((UITableViewCell *)self).contentView.hidden = YES;
        ((UITableViewCell *)self).accessoryType = UITableViewCellAccessoryNone;
    }
}

- (CGSize)sizeThatFits:(CGSize)size {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalCellMarkedBatteryUnknownPart(self))
        return CGSizeMake(size.width, 0.01);
    return %orig(size);
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize
       withHorizontalFittingPriority:(UILayoutPriority)horizontalFittingPriority
             verticalFittingPriority:(UILayoutPriority)verticalFittingPriority {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalCellMarkedBatteryUnknownPart(self))
        return CGSizeMake(targetSize.width, 0.01);
    return %orig(targetSize, horizontalFittingPriority, verticalFittingPriority);
}

- (void)layoutSubviews {
    %orig;
    if (!CPUthermalComponentSuppressionEnabled()) return;
    CPUthermalMarkBatteryUnknownPartCell(self);
    if (CPUthermalCellMarkedBatteryUnknownPart(self)) {
        CPUthermalRecordBatteryUnknownPartSection(self);
        ((UITableViewCell *)self).hidden = YES;
        ((UITableViewCell *)self).contentView.hidden = YES;
    }
}

%end

%end

%group CPUthermalSpringBoardComponent

%hook SBIconController

- (BOOL)allowsBadgingForIcon:(id)icon {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsPreferencesBundle(icon)) return NO;
    return %orig(icon);
}

%end

%hook SBApplication

- (id)badgeValue {
    if (CPUthermalComponentSuppressionEnabled() && CPUthermalIsPreferencesBundle(self)) return nil;
    return %orig;
}

%end

%hook BSUIBadgeController

- (void)updateBadgeValue:(id)value forBundleID:(id)bundleID {
    if (CPUthermalComponentSuppressionEnabled() &&
        [bundleID isKindOfClass:[NSString class]] &&
        [bundleID isEqualToString:S("com.apple.Preferences")]) {
        %orig(nil, bundleID);
        return;
    }
    %orig(value, bundleID);
}

%end

%end

static void CPUthermalInstallComponentHooks(void);

static void CPUthermalComponentBundleLoaded(CFNotificationCenterRef c, void *o, CFStringRef n,
                                            const void *obj, CFDictionaryRef ui) {
    (void)c; (void)o; (void)n; (void)obj; (void)ui;
    if (objc_getClass("BatteryUIResourceClass") != Nil ||
        objc_getClass("BatteryUIController") != Nil ||
        objc_getClass("PSGAboutController") != Nil)
        CPUthermalInstallComponentHooks();
}

static void CPUthermalInstallComponentHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init(CPUthermalComponentHooks);
        if ([NSProcessInfo.processInfo.processName isEqualToString:S("SpringBoard")])
            %init(CPUthermalSpringBoardComponent);
    });
}

%ctor {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        if (![process isEqualToString:S("Preferences")] && ![process isEqualToString:S("SpringBoard")])
            return;

        dispatch_async(CPUthermalComponentQueue(), ^{ CPUthermalReloadComponentSuppression(); });
        notify_register_dispatch(kCPUthermalSettingsChangedNotifC, &gCPUthermalComponentToken,
                                 CPUthermalComponentQueue(), ^(int token) {
            (void)token;
            CPUthermalReloadComponentSuppression();
            if (![NSProcessInfo.processInfo.processName isEqualToString:S("Preferences")]) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (CPUthermalComponentSuppressionEnabled()) CPUthermalHideInVisibleAboutPages();
            });
        });

        if ([process isEqualToString:S("SpringBoard")]) {
            CPUthermalInstallComponentHooks();
        } else {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                            CPUthermalComponentBundleLoaded,
                                            (__bridge CFStringRef)NSBundleDidLoadNotification,
                                            NULL, CFNotificationSuspensionBehaviorCoalesce);
            if (objc_getClass("BatteryUIResourceClass") != Nil ||
                objc_getClass("PSUIPrefsListController") != Nil ||
                objc_getClass("PSGAboutDataSource") != Nil ||
                objc_getClass("PSGAboutController") != Nil ||
                objc_getClass("CRUAlertCell") != Nil)
                CPUthermalInstallComponentHooks();
        }
    }
}
