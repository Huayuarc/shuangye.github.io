#import "CNSRulesListController.h"
#import "CNSRuleEditController.h"
#import "CNSPrefs.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 私有: 取 App 显示名(LSApplicationProxy, 运行时动态取类)
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *localizedName;
@end

// 私有: 取 App 图标(UIKit 私有 category, respondsToSelector 判存)
@interface UIImage (CNSPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

@implementation CNSRulesListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"通知规则";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemEdit
                                                      target:self action:@selector(cnsToggleEdit)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self buildSpecifiers];
    return _specifiers;
}

- (void)reloadSpecifiers {
    _specifiers = [self buildSpecifiers];
    [super reloadSpecifiers];
}

// App 显示名: 优先 LSApplicationProxy.localizedName, 取不到回退 BundleID
- (NSString *)appNameForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    Class lsCls = NSClassFromString(@"LSApplicationProxy");
    if ([lsCls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        LSApplicationProxy *proxy = [lsCls applicationProxyForIdentifier:bundleID];
        NSString *name = proxy.localizedName;
        if (name.length > 0) return name;
    }
    return bundleID;   // App 未安装/解析失败 → 回退原始 BundleID
}

// App 图标: UIKit 私有 API, 取不到返回 nil(只显示名字)
- (UIImage *)appIconForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
        if (icon) return icon;
    }
    return nil;
}

// 取规则 bundleID 列表的第一个(用于显示名/图标; 逗号分隔时取首个)
- (NSString *)firstBundleID:(NSDictionary *)rule {
    NSString *b = rule[CNS_RULE_BUNDLEID];
    if (b.length == 0) return nil;
    NSString *first = [[b componentsSeparatedByString:@","] firstObject];
    return [first stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// 主标题: [排除] 前缀 + App 名(取不到回退 BundleID) + 匹配标题; 都没有则按标题/任意通知
- (NSString *)titleForRule:(NSDictionary *)rule {
    NSString *bundleID = [self firstBundleID:rule];
    NSString *title    = rule[CNS_RULE_TITLE];
    NSString *prefix   = [rule[CNS_RULE_EXCLUDE] boolValue] ? @"[排除] " : @"";
    NSString *core;
    if (bundleID.length > 0) {
        NSString *appName = [self appNameForBundleID:bundleID];
        if (title.length > 0) core = [NSString stringWithFormat:@"%@ - %@", appName, title];
        else core = appName;
    } else if (title.length > 0) {
        core = [NSString stringWithFormat:@"标题“%@”", title];
    } else {
        core = @"任意通知";
    }
    return [prefix stringByAppendingString:core];
}

// 副标题: 显示已选音频文件名(无则提示未设置)
- (NSString *)subtitleForRule:(NSDictionary *)rule {
    NSString *sound = rule[CNS_RULE_SOUND];
    if (sound.length == 0) return @"未设置音频";
    return [sound lastPathComponent];
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSArray *rules = [CNSConfig loadRules];

    PSSpecifier *grp = [PSSpecifier groupSpecifierWithName:@""];
    if (rules.count == 0)
        [grp setProperty:@"还没有规则。点下方“添加规则”创建第一条。" forKey:@"footerText"];
    else
        [grp setProperty:@"点击编辑; 右上角“编辑”可删除或拖动排序(靠前的规则优先匹配)。" forKey:@"footerText"];
    [specs addObject:grp];

    for (NSDictionary *rule in rules) {
        PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:[self titleForRule:rule]
            target:self set:nil get:nil
            detail:[CNSRuleEditController class] cell:PSLinkCell edit:nil];
        [s setProperty:@YES forKey:@"isController"];
        // 以 ruleID 作为稳定主键(不再用下标), 增删改/排序后不会错位
        NSString *rid = rule[CNS_RULE_ID];
        if (rid.length > 0) [s setProperty:rid forKey:@"cnsRuleID"];
        // 行右侧加开关直接表示启用状态, 故标题不再带 (关) 前缀
        s.name = [self titleForRule:rule];
        [s setProperty:[self subtitleForRule:rule] forKey:@"subtitle"];
        // 主标题左侧显示 App 图标(取不到则无图标)
        UIImage *icon = [self appIconForBundleID:[self firstBundleID:rule]];
        if (icon) [s setProperty:icon forKey:@"iconImage"];
        [specs addObject:s];
    }

    PSSpecifier *grpAdd = [PSSpecifier groupSpecifierWithName:@""];
    [specs addObject:grpAdd];
    PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"添加规则"
        target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    add->action = @selector(cnsAddRule);
    [add setProperty:@YES forKey:@"enabled"];
    [specs addObject:add];

    return specs;
}

- (void)cnsAddRule {
    NSMutableDictionary *newRule = [@{
        CNS_RULE_ID:       [CNSConfig newRuleID],
        CNS_RULE_ENABLED:  @YES,
        CNS_RULE_BUNDLEID: @"",
        CNS_RULE_EXCLUDE:  @NO,
        CNS_RULE_TITLE:    @"",
        CNS_RULE_SUBTITLE: @"",
        CNS_RULE_MESSAGE:  @"",
        CNS_RULE_EXACT:    @YES,
        CNS_RULE_SOUND:    @"",
    } mutableCopy];
    [CNSConfig upsertRule:newRule];

    CNSRuleEditController *edit = [[CNSRuleEditController alloc] init];
    PSSpecifier *s = [PSSpecifier emptyGroupSpecifier];
    [s setProperty:newRule[CNS_RULE_ID] forKey:@"cnsRuleID"];
    edit.specifier = s;
    [self pushController:edit];
}

- (void)cnsToggleEdit {
    BOOL editing = !self.table.isEditing;
    [self.table setEditing:editing animated:YES];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:(editing ? UIBarButtonSystemItemDone : UIBarButtonSystemItemEdit)
                                                      target:self action:@selector(cnsToggleEdit)];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *s = [self specifierAtIndexPath:ip];
    if ([s propertyForKey:@"cnsRuleID"] != nil && s.detailControllerClass != nil)
        return UITableViewCellEditingStyleDelete;
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    PSSpecifier *s = [self specifierAtIndexPath:ip];
    NSString *rid = [s propertyForKey:@"cnsRuleID"];
    if (rid.length == 0) return;
    [CNSConfig deleteRuleID:rid];
    [self reloadSpecifiers];
}

// ===== 拖动排序(按 ruleID 重排数组) =====
- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip {
    PSSpecifier *s = [self specifierAtIndexPath:ip];
    return ([s propertyForKey:@"cnsRuleID"] != nil && s.detailControllerClass != nil);
}

- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    PSSpecifier *s = [self specifierAtIndexPath:to];
    if ([s propertyForKey:@"cnsRuleID"] != nil && s.detailControllerClass != nil) return to;
    return from;
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    PSSpecifier *sf = [self specifierAtIndexPath:from];
    PSSpecifier *st = [self specifierAtIndexPath:to];
    NSString *fromID = [sf propertyForKey:@"cnsRuleID"];
    NSString *toID   = [st propertyForKey:@"cnsRuleID"];
    if (fromID.length == 0 || toID.length == 0) { [self reloadSpecifiers]; return; }

    NSMutableArray *rules = [CNSConfig loadRules];
    NSUInteger fromIdx = NSNotFound, toIdx = NSNotFound;
    for (NSUInteger i = 0; i < rules.count; i++) {
        NSString *rid = rules[i][CNS_RULE_ID];
        if ([rid isEqualToString:fromID]) fromIdx = i;
        if ([rid isEqualToString:toID])   toIdx = i;
    }
    if (fromIdx != NSNotFound && toIdx != NSNotFound) {
        NSDictionary *moved = rules[fromIdx];
        [rules removeObjectAtIndex:fromIdx];
        [rules insertObject:moved atIndex:toIdx];
        [CNSConfig saveRules:rules];
    }
    [self reloadSpecifiers];
}

// ===== 行右侧开关: 点行进编辑, 拨开关直接启用/禁用 =====
// 给每个规则行的 cell 挂一个 UISwitch 作 accessoryView, ruleID 用关联对象绑到开关上。
static const void *kCNSSwitchRuleIDKey = &kCNSSwitchRuleIDKey;

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [super tableView:tv cellForRowAtIndexPath:ip];
    PSSpecifier *s = [self specifierAtIndexPath:ip];
    NSString *rid = [s propertyForKey:@"cnsRuleID"];

    // 非规则行(组头/添加按钮): 清掉可能复用残留的开关
    if (rid.length == 0) {
        if ([cell.accessoryView isKindOfClass:[UISwitch class]]) cell.accessoryView = nil;
        return cell;
    }

    UISwitch *sw = [cell.accessoryView isKindOfClass:[UISwitch class]]
        ? (UISwitch *)cell.accessoryView : [[UISwitch alloc] init];
    objc_setAssociatedObject(sw, kCNSSwitchRuleIDKey, rid, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSDictionary *rule = [CNSConfig ruleWithID:rid];
    sw.on = [rule[CNS_RULE_ENABLED] boolValue];
    [sw removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
    [sw addTarget:self action:@selector(cnsRuleSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    cell.accessoryView = sw;                              // 开关占据右侧, 取代默认箭头
    cell.editingAccessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)cnsRuleSwitchChanged:(UISwitch *)sw {
    NSString *rid = objc_getAssociatedObject(sw, kCNSSwitchRuleIDKey);
    if (rid.length == 0) return;
    NSMutableDictionary *rule = [CNSConfig ruleWithID:rid];
    if (rule == nil) return;
    rule[CNS_RULE_ENABLED] = @(sw.on);
    [CNSConfig upsertRule:rule];
}
@end
