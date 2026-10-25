#import "H120SettingsController.h"
#import "../Shared/H120Preferences.h"
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static NSString *H120Text(NSString *english, NSString *chinese) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? chinese : english;
}

static UIColor *H120Blue(void) { return UIColor.systemBlueColor; }

static void H120Alert(UIViewController *controller, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hello 120Hz"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:H120Text(@"OK", @"好")
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static UINavigationItem *H120NavigationItem(UIViewController *controller, UIViewController *owner) {
    return owner ? owner.navigationItem : controller.navigationItem;
}

static BOOL H120HUDEnabled(void) {
    typedef int (*Get)(uint32_t, uint32_t);
    Get option = (Get)dlsym(RTLD_DEFAULT, "CARenderServerGetDebugOption");
    return option && option(0, 0x24) != 0;
}

static BOOL H120SetHUDEnabled(BOOL enabled) {
    typedef void (*Set)(uint32_t, uint32_t, int);
    Set option = (Set)dlsym(RTLD_DEFAULT, "CARenderServerSetDebugOption");
    Set value = (Set)dlsym(RTLD_DEFAULT, "CARenderServerSetDebugValue");
    if (!option || !value) return NO;
    if (enabled) value(0, 1, 0);
    option(0, 0x24, enabled);
    return YES;
}

static NSString *H120FilterPath(void) {
    return H120JailbreakPath(@"/var/mobile/Library/Preferences/cn.zqbb.fix120hz.injection.plist");
}

static BOOL H120GlobalInjectionEnabled(void) {
    NSString *path = H120FilterPath();
    NSDictionary *dictionary = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    id bundles = [dictionary[@"Filter"] isKindOfClass:NSDictionary.class] ? dictionary[@"Filter"][@"Bundles"] : nil;
    return [bundles isKindOfClass:NSArray.class] && [bundles containsObject:@"com.apple.UIKit"];
}

static BOOL H120SetGlobalInjection(BOOL enabled) {
    NSString *path = H120FilterPath();
    if (!path) return NO;
    NSDictionary *dictionary = @{@"Filter": @{
        @"Mode": @"Any", @"Executables": @[@"SpringBoard", @"backboardd", @"replayd"],
        @"Bundles": enabled ? @[@"com.apple.UIKit", @"com.apple.Preferences"]
                            : @[@"com.apple.springboard", @"com.apple.Preferences"]
    }};
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return [dictionary writeToFile:path atomically:YES];
}

static void H120ReloadInterface(UIViewController *controller) {
    H120PostPreferencesChanged();
    NSString *path = H120JailbreakPath(@"/usr/bin/sbreload");
    if (!path || access(path.fileSystemRepresentation, X_OK) != 0) {
        H120Alert(controller, H120Text(@"Reload SpringBoard with your jailbreak manager.", @"请使用越狱管理器注销 SpringBoard。"));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        pid_t child = 0;
        const char *executable = path.fileSystemRepresentation;
        char *arguments[] = {(char *)executable, NULL};
        int result = posix_spawn(&child, executable, NULL, NULL, arguments, environ);
        int status = 0;
        if (result == 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            H120Alert(controller, H120Text(@"Reload SpringBoard with your jailbreak manager.", @"请使用越狱管理器注销 SpringBoard。"));
        });
    });
}

static id H120ReadSpecifier(id controller, SEL selector, PSSpecifier *specifier) {
    (void)controller; (void)selector;
    NSString *key = [specifier propertyForKey:@"key"];
    return key ? H120ReadPreferences()[key] ?: [specifier propertyForKey:@"default"] : nil;
}

static void H120WriteSpecifier(id controller, SEL selector, id value, PSSpecifier *specifier) {
    (void)selector;
    NSString *key = [specifier propertyForKey:@"key"];
    if (key && !H120WritePreference(key, value)) {
        H120Alert(controller, H120Text(@"Could not save preferences.", @"无法保存配置。"));
    }
}

static Class H120ApplicationListClass(void) {
    Class existing = NSClassFromString(@"H120ApplicationListController");
    if (existing) return existing;
    NSString *path = H120JailbreakPath(@"/Library/Frameworks/AltList.framework/AltList");
    if (path) dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    Class base = NSClassFromString(@"ATLApplicationListMultiSelectionController");
    if (!base) return Nil;
    Class result = objc_allocateClassPair(base, "H120ApplicationListController", 0);
    if (!result) return NSClassFromString(@"H120ApplicationListController");
    class_addMethod(result, @selector(readPreferenceValue:), (IMP)H120ReadSpecifier, "@@:@");
    class_addMethod(result, @selector(setPreferenceValue:specifier:), (IMP)H120WriteSpecifier, "v@:@@");
    objc_registerClassPair(result);
    return result;
}

@interface H120SettingsCell : UITableViewCell
@property(nonatomic, strong) UIImageView *h120SymbolView;
@property(nonatomic, strong) UILabel *h120NameLabel;
@property(nonatomic, strong) UILabel *h120SubtitleLabel;
@property(nonatomic, strong) UILabel *h120ValueLabel;
@property(nonatomic, strong) UIImageView *h120DisclosureView;
@property(nonatomic, strong) UIView *h120SeparatorLine;
@property(nonatomic, strong) UISwitch *h120Toggle;
@property(nonatomic) BOOL h120HasSymbol;
@property(nonatomic) BOOL h120ShowsDisclosure;
@property(nonatomic) BOOL h120ShowsCheckmark;
@property(nonatomic) BOOL h120ActionStyle;
@property(nonatomic) CGFloat h120TitleLeading;
@property(nonatomic) UIRectCorner h120Corners;
- (void)setName:(NSString *)name subtitle:(NSString *)subtitle symbol:(NSString *)symbol;
@end

@implementation H120SettingsCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    if (self) {
        self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.h120NameLabel = [UILabel new];
        self.h120NameLabel.font = [UIFont systemFontOfSize:14];
        self.h120NameLabel.adjustsFontForContentSizeCategory = NO;
        self.h120SubtitleLabel = [UILabel new];
        self.h120SubtitleLabel.font = [UIFont systemFontOfSize:11];
        self.h120SubtitleLabel.textColor = UIColor.secondaryLabelColor;
        self.h120SubtitleLabel.numberOfLines = 0;
        self.h120ValueLabel = [UILabel new];
        self.h120ValueLabel.font = [UIFont systemFontOfSize:14];
        self.h120ValueLabel.textColor = UIColor.secondaryLabelColor;
        self.h120ValueLabel.textAlignment = NSTextAlignmentRight;
        self.h120SymbolView = [UIImageView new];
        self.h120SymbolView.tintColor = H120Blue();
        self.h120SymbolView.contentMode = UIViewContentModeCenter;
        self.h120DisclosureView = [UIImageView new];
        self.h120DisclosureView.contentMode = UIViewContentModeScaleAspectFit;
        self.h120SeparatorLine = [UIView new];
        self.h120SeparatorLine.backgroundColor = UIColor.separatorColor;
        for (UIView *view in @[self.h120SymbolView, self.h120NameLabel, self.h120SubtitleLabel, self.h120ValueLabel,
                               self.h120DisclosureView, self.h120SeparatorLine]) [self.contentView addSubview:view];
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = UIColor.tertiarySystemGroupedBackgroundColor;
    }
    return self;
}
- (void)setFrame:(CGRect)frame {
    if (frame.origin.x < 15.5 && frame.size.width > 100) {
        frame.origin.x += 16;
        frame.size.width -= 32;
    }
    [super setFrame:frame];
}
- (void)setName:(NSString *)name subtitle:(NSString *)subtitle symbol:(NSString *)symbol {
    self.h120NameLabel.text = name;
    self.h120SubtitleLabel.text = subtitle;
    self.h120HasSymbol = symbol.length > 0;
    self.h120SymbolView.image = symbol.length ? [UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular]] : nil;
    self.h120SymbolView.hidden = !self.h120HasSymbol;
    self.h120SubtitleLabel.hidden = subtitle.length == 0;
    self.h120NameLabel.textColor = self.h120ActionStyle ? H120Blue() : UIColor.labelColor;
    self.accessibilityLabel = name;
    self.accessibilityHint = subtitle;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat leading = self.h120TitleLeading > 0 ? self.h120TitleLeading : self.h120HasSymbol ? 52 : 16;
    CGFloat trailing = self.h120ShowsDisclosure || self.h120ShowsCheckmark ? 36 : 16;
    CGFloat valueWidth = self.h120ValueLabel.text.length ? ceil([self.h120ValueLabel sizeThatFits:CGSizeMake(width, height)].width) : 0;
    if (self.h120Toggle) {
        [self.h120Toggle sizeToFit];
        self.h120Toggle.frame = CGRectMake(width - 16 - CGRectGetWidth(self.h120Toggle.bounds),
            (height - CGRectGetHeight(self.h120Toggle.bounds)) / 2,
            CGRectGetWidth(self.h120Toggle.bounds), CGRectGetHeight(self.h120Toggle.bounds));
        trailing = 83;
    }
    CGFloat textWidth = width - leading - trailing - (valueWidth > 0 ? valueWidth + 12 : 0);
    CGFloat titleHeight = ceil(self.h120NameLabel.font.lineHeight);
    CGFloat subtitleHeight = self.h120SubtitleLabel.text.length ? ceil([self.h120SubtitleLabel sizeThatFits:
        CGSizeMake(width - leading - trailing, CGFLOAT_MAX)].height) : 0;
    CGFloat total = titleHeight + (subtitleHeight > 0 ? 2 + subtitleHeight : 0);
    self.h120NameLabel.frame = CGRectMake(leading, (height - total) / 2, MAX(0, textWidth), titleHeight);
    self.h120SubtitleLabel.frame = CGRectMake(leading, CGRectGetMaxY(self.h120NameLabel.frame) + 2,
        width - leading - trailing, subtitleHeight);
    self.h120SymbolView.frame = CGRectMake(14, (height - 24) / 2, 24, 24);
    self.h120ValueLabel.frame = CGRectMake(width - trailing - valueWidth, 0, valueWidth, height);
    self.h120DisclosureView.hidden = !self.h120ShowsDisclosure && !self.h120ShowsCheckmark;
    if (self.h120ShowsCheckmark) {
        self.h120DisclosureView.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]];
        self.h120DisclosureView.tintColor = H120Blue();
        self.h120DisclosureView.frame = CGRectMake(width - 34, (height - 22) / 2, 18, 22);
    } else {
        self.h120DisclosureView.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
        self.h120DisclosureView.tintColor = UIColor.tertiaryLabelColor;
        self.h120DisclosureView.frame = CGRectMake(width - 24, (height - 16) / 2, 8, 16);
    }
    CGFloat separatorLeading = self.h120HasSymbol ? 52 : 16;
    self.h120SeparatorLine.frame = CGRectMake(separatorLeading, height - 1.0 / UIScreen.mainScreen.scale,
        width - separatorLeading, 1.0 / UIScreen.mainScreen.scale);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:self.bounds byRoundingCorners:self.h120Corners
        cornerRadii:CGSizeMake(10, 10)];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = path.CGPath;
    self.layer.mask = mask;
}
@end

@interface H120TableCoordinator : NSObject <UITableViewDelegate, UITableViewDataSource>
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, weak) UITableView *tableView;
@property(nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@property(nonatomic, strong) NSArray<NSString *> *headers;
@property(nonatomic, strong) NSArray<NSString *> *footers;
@property(nonatomic, copy) void (^selection)(NSString *identifier);
@property(nonatomic, copy) void (^toggleChanged)(BOOL value);
@end

@implementation H120TableCoordinator
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return self.sections[section].count;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; return [self.sections[indexPath.section][indexPath.row][@"height"] doubleValue];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *row = self.sections[indexPath.section][indexPath.row];
    H120SettingsCell *cell = [[H120SettingsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.h120ActionStyle = [row[@"action"] boolValue];
    cell.h120ShowsDisclosure = [row[@"disclosure"] boolValue];
    cell.h120ShowsCheckmark = [row[@"checked"] boolValue];
    [cell setName:row[@"title"] subtitle:row[@"subtitle"] symbol:row[@"symbol"]];
    cell.h120ValueLabel.text = row[@"value"];
    cell.h120SeparatorLine.hidden = indexPath.row == (NSInteger)self.sections[indexPath.section].count - 1;
    if (indexPath.row == 0) cell.h120Corners |= UIRectCornerTopLeft | UIRectCornerTopRight;
    if (cell.h120SeparatorLine.hidden) cell.h120Corners |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
    if (row[@"h120Toggle"]) {
        cell.h120Toggle = [UISwitch new];
        cell.h120Toggle.on = [row[@"h120Toggle"] boolValue];
        cell.h120Toggle.accessibilityLabel = row[@"title"];
        [cell.h120Toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:cell.h120Toggle];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)switchChanged:(UISwitch *)sender { if (self.toggleChanged) self.toggleChanged(sender.on); }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *identifier = self.sections[indexPath.section][indexPath.row][@"identifier"];
    if (self.selection && identifier.length) self.selection(identifier);
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section < (NSInteger)self.headers.count && self.headers[section].length ? 50 : 35;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSString *text = section < (NSInteger)self.footers.count ? self.footers[section] : @"";
    if (!text.length) return CGFLOAT_MIN;
    CGFloat width = CGRectGetWidth(tableView.bounds) - 64;
    CGRect bounds = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12]} context:nil];
    return MAX(23, ceil(bounds.size.height) + 7);
}
- (UIView *)textView:(NSString *)text table:(UITableView *)tableView height:(CGFloat)height header:(BOOL)header {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(tableView.bounds), height)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(32, header ? height - 8 - 16 : 5,
        CGRectGetWidth(tableView.bounds) - 64, header ? 16 : MAX(0, height - 5))];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.text = text;
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = UIColor.secondaryLabelColor;
    label.numberOfLines = 0;
    [view addSubview:label];
    return view;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *text = section < (NSInteger)self.headers.count ? self.headers[section] : @"";
    return [self textView:text table:tableView height:[self tableView:tableView heightForHeaderInSection:section] header:YES];
}
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSString *text = section < (NSInteger)self.footers.count ? self.footers[section] : @"";
    return text.length ? [self textView:text table:tableView height:
        [self tableView:tableView heightForFooterInSection:section] header:NO] : nil;
}
@end

static UITableView *H120CreateTable(UIViewController *controller, H120TableCoordinator *coordinator) {
    UITableView *table = [[UITableView alloc] initWithFrame:controller.view.bounds style:UITableViewStyleGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.estimatedRowHeight = 0;
    table.estimatedSectionHeaderHeight = 0;
    table.estimatedSectionFooterHeight = 0;
    table.sectionHeaderTopPadding = 0;
    table.delegate = coordinator;
    table.dataSource = coordinator;
    coordinator.controller = controller;
    coordinator.tableView = table;
    controller.view.backgroundColor = table.backgroundColor;
    [controller.view addSubview:table];
    return table;
}

static NSDictionary *H120Row(NSString *identifier, NSString *title, NSString *subtitle,
    NSString *symbol, CGFloat height, BOOL action, BOOL disclosure) {
    return @{@"identifier":identifier, @"title":title, @"subtitle":subtitle ?: @"", @"symbol":symbol ?: @"",
        @"height":@(height), @"action":@(action), @"disclosure":@(disclosure)};
}

@interface H120FrameRateController : UIViewController
@property(nonatomic, strong) UITableView *settingsTable;
@property(nonatomic, strong) H120TableCoordinator *coordinator;
@end

@implementation H120FrameRateController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = H120Text(@"Preferred Frame Rate", @"优选帧率");
    self.coordinator = [H120TableCoordinator new];
    __weak H120FrameRateController *weakSelf = self;
    self.coordinator.selection = ^(NSString *identifier) {
        H120FrameRateController *owner = weakSelf;
        if (!owner) return;
        if (!H120WritePreference(@"wantsFPS", @([identifier integerValue]))) {
            H120Alert(owner, H120Text(@"Could not save preferences.", @"无法保存配置。"));
        }
        [owner reloadValues];
    };
    self.settingsTable = H120CreateTable(self, self.coordinator);
    [self reloadValues];
}
- (void)reloadValues {
    NSInteger selected = [H120ReadPreferences()[@"wantsFPS"] integerValue];
    if (![@[@10,@30,@60,@80,@120] containsObject:@(selected)]) selected = 120;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSNumber *value in @[@10,@30,@60,@80,@120]) {
        NSMutableDictionary *row = [H120Row(value.stringValue, value.stringValue, nil, nil, 44, NO, NO) mutableCopy];
        row[@"checked"] = @([value integerValue] == selected);
        [rows addObject:row];
    }
    self.coordinator.sections = @[rows];
    [self.settingsTable reloadData];
}
@end

@interface H120SettingsController ()
@property(nonatomic, strong) UITableView *settingsTable;
@property(nonatomic, strong) H120TableCoordinator *coordinator;
@end

@implementation H120SettingsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hello 120Hz";
    UINavigationItem *item = H120NavigationItem(self, self.navigationOwner);
    item.title = self.title;
    item.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.title style:UIBarButtonItemStylePlain target:nil action:NULL];
    item.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:H120Text(@"Respring", @"注销") style:UIBarButtonItemStylePlain target:self action:@selector(respring)],
        [[UIBarButtonItem alloc] initWithTitle:H120Text(@"Reset", @"重置") style:UIBarButtonItemStylePlain target:self action:@selector(reset)]
    ];
    for (UIBarButtonItem *button in item.rightBarButtonItems) [button setTitleTextAttributes:
        @{NSFontAttributeName:[UIFont systemFontOfSize:17]} forState:UIControlStateNormal];
    self.coordinator = [H120TableCoordinator new];
    __weak H120SettingsController *weakSelf = self;
    self.coordinator.selection = ^(NSString *identifier) { [weakSelf selectIdentifier:identifier]; };
    self.coordinator.toggleChanged = ^(BOOL enabled) {
        H120SettingsController *owner = weakSelf;
        if (!H120WritePreference(@"wantsEnable", @(enabled))) {
            H120Alert(owner, H120Text(@"Could not save preferences.", @"无法保存配置。"));
            [owner reloadValues];
        }
    };
    self.settingsTable = H120CreateTable(self, self.coordinator);
    [self reloadValues];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.tintColor = H120Blue();
    [self reloadValues];
}
- (void)reloadValues {
    if (!self.coordinator) return;
    NSDictionary *preferences = H120ReadPreferences();
    NSInteger fps = [preferences[@"wantsFPS"] integerValue];
    if (![@[@10,@30,@60,@80,@120] containsObject:@(fps)]) fps = 120;
    NSMutableDictionary *enabled = [H120Row(@"enabled", H120Text(@"Enable Tweak", @"启用调整"), nil, @"switch.2", 44, NO, NO) mutableCopy];
    enabled[@"h120Toggle"] = @([preferences[@"wantsEnable"] boolValue]);
    NSMutableDictionary *rate = [H120Row(@"rate", H120Text(@"Preferred Frame Rate", @"优选帧率"), nil, @"waveform.path.ecg", 44, NO, YES) mutableCopy];
    rate[@"value"] = [@(fps) stringValue];
    NSMutableArray *actions = [NSMutableArray array];
    if (H120GlobalInjectionEnabled()) {
        [actions addObject:H120Row(@"excluded", H120Text(@"Black List", @"屏蔽异常"),
            H120Text(@"Resolve conflicts with a few apps", @"解决少数应用冲突"), @"xmark.circle", 50, NO, YES)];
        [actions addObject:H120Row(@"system", H120Text(@"Restore Defaults", @"恢复默认"),
            H120Text(@"Only inject into system processes", @"只注入系统进程"), @"arrow.counterclockwise", 50, YES, NO)];
    } else {
        NSString *subtitle = H120Text(
            @"Benefits: Reduce 60Hz fallback, making animations smoother.\nDrawbacks: Games may increase the risk of a ban if not excluded.",
            @"好处: 减少 60Hz 回落，使部分动画更加流畅丝滑。\n坏处: 如果不对游戏进行屏蔽，可能会增加被封号的风险。");
        CGFloat textWidth = CGRectGetWidth(self.view.bounds) - 32 - 52 - 16;
        CGRect bounds = [subtitle boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:11]} context:nil];
        CGFloat height = MAX(63, ceil(bounds.size.height) + ceil([UIFont systemFontOfSize:14].lineHeight) + 18);
        [actions addObject:H120Row(@"global", H120Text(@"Global Injection", @"全局注入"), subtitle,
            @"sparkles.rectangle.stack", height, YES, NO)];
    }
    [actions addObject:H120Row(@"hud", H120HUDEnabled() ? H120Text(@"Disable Debug HUD", @"关闭调试")
        : H120Text(@"Enable Debug HUD", @"打开调试"), H120Text(@"Show system-level debug information", @"显示系统级的调试信息"),
        @"lasso", 50, YES, NO)];
    self.coordinator.sections = @[@[enabled, rate], actions];
    self.coordinator.footers = @[@"3.3.3-3", @""];
    [self.settingsTable reloadData];
}
- (void)selectIdentifier:(NSString *)identifier {
    if ([identifier isEqual:@"rate"]) {
        [self.navigationController pushViewController:[H120FrameRateController new] animated:YES];
    } else if ([identifier isEqual:@"excluded"]) {
        Class controller = NSClassFromString(@"Mode3Controller");
        if (controller) [self.navigationController pushViewController:[controller new] animated:YES];
    } else if ([identifier isEqual:@"global"] || [identifier isEqual:@"system"]) {
        if (!H120SetGlobalInjection([identifier isEqual:@"global"])) {
            H120Alert(self, H120Text(@"Could not save injection settings.", @"无法保存注入设置。"));
        }
        [self reloadValues];
    } else if ([identifier isEqual:@"hud"]) {
        if (!H120SetHUDEnabled(!H120HUDEnabled())) {
            H120Alert(self, H120Text(@"This system does not provide the debug HUD interface.", @"当前系统未提供调试信息接口。"));
        }
        [self reloadValues];
    }
}
- (void)reset {
    if (!H120ReplacePreferences(@{@"wantsEnable":@NO, @"wantsFPS":@120, @"selectedApps":@[]})) {
        H120Alert(self, H120Text(@"Could not save preferences.", @"无法保存配置。"));
    }
    [self reloadValues];
}
- (void)respring { H120ReloadInterface(self); }
@end

@interface H120ExclusionsController ()
@property(nonatomic, strong) UITableView *settingsTable;
@property(nonatomic, strong) H120TableCoordinator *coordinator;
@end

@implementation H120ExclusionsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = H120Text(@"Black List", @"屏蔽异常");
    UINavigationItem *item = H120NavigationItem(self, self.navigationOwner);
    item.title = self.title;
    item.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:H120Text(@"Apply", @"点我生效") style:UIBarButtonItemStylePlain target:self action:@selector(apply)],
        [[UIBarButtonItem alloc] initWithTitle:H120Text(@"Reset", @"重置") style:UIBarButtonItemStylePlain target:self action:@selector(reset)]
    ];
    for (UIBarButtonItem *button in item.rightBarButtonItems) [button setTitleTextAttributes:
        @{NSFontAttributeName:[UIFont systemFontOfSize:17]} forState:UIControlStateNormal];
    self.coordinator = [H120TableCoordinator new];
    self.coordinator.sections = @[@[H120Row(@"select", H120Text(@"Select App", @"请选择应用"), nil,
        @"rectangle.and.hand.point.up.left", 44, NO, YES)]];
    self.coordinator.headers = @[H120Text(@"Disable some code", @"禁止一些代码生效")];
    self.coordinator.footers = @[H120Text(
        @"If an abnormal application is encountered, select it.\nRespring to apply.\n\nUse the roothide blacklist to prevent jailbreak detection in games.",
        @"如果遇到异常应用\n请勾选这个应用\n注销后生效\n\n如果想要防止游戏检测越狱\n请使用roothide越狱, 把游戏纳入黑名单")];
    __weak H120ExclusionsController *weakSelf = self;
    self.coordinator.selection = ^(NSString *identifier) {
        if ([identifier isEqual:@"select"]) [weakSelf selectApplications];
    };
    self.settingsTable = H120CreateTable(self, self.coordinator);
}
- (void)reset {
    if (!H120WritePreference(@"selectedApps", @[])) H120Alert(self, H120Text(@"Could not save preferences.", @"无法保存配置。"));
}
- (void)apply { H120ReloadInterface(self); }
- (void)selectApplications {
    Class controllerClass = H120ApplicationListClass();
    Class specifierClass = NSClassFromString(@"PSSpecifier");
    if (!controllerClass || !specifierClass) {
        H120Alert(self, H120Text(@"Install AltList to select applications.", @"安装 AltList 后可选择应用。"));
        return;
    }
    PSSpecifier *specifier = [specifierClass preferenceSpecifierNamed:H120Text(@"Select App", @"请选择应用")
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:controllerClass cell:PSLinkListCell edit:Nil];
    for (NSString *key in @[@"key",@"defaults",@"sections",@"useSearchBar",@"defaultApplicationSwitchValue",@"showIdentifiersAsSubtitle",@"default"]) {
        NSDictionary *properties = @{@"key":@"selectedApps", @"defaults":@"cn.zqbb.fix120hz",
            @"sections":@[@{@"sectionType":@"Visible"}], @"useSearchBar":@YES,
            @"defaultApplicationSwitchValue":@NO, @"showIdentifiersAsSubtitle":@YES, @"default":@[]};
        [specifier setProperty:properties[key] forKey:key];
    }
    UIViewController *controller = [controllerClass new];
    using SetObject = void (*)(id, SEL, id);
    if ([controller respondsToSelector:@selector(setSpecifier:)]) ((SetObject)objc_msgSend)(controller, @selector(setSpecifier:), specifier);
    if ([controller respondsToSelector:@selector(setParentController:)]) ((SetObject)objc_msgSend)(controller, @selector(setParentController:), self.navigationOwner ?: self);
    controller.title = H120Text(@"Select App", @"请选择应用");
    [self.navigationController pushViewController:controller animated:YES];
}
- (id)readPreferenceValue:(PSSpecifier *)specifier { return H120ReadSpecifier(self, _cmd, specifier); }
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier { H120WriteSpecifier(self, _cmd, value, specifier); }
@end
