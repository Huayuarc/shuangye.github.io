#import "AppBlacklistController.h"
#import <UIKit/UIKit.h>

// 私有 API 前向声明 — UIKit 存在该方法但 SDK 头文件未暴露
@interface UIImage (PrivateIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID;
@end

#define kPrefsDomain @"com.hoangdus.speedsterprefs"
#define kBlacklistKey @"proMotion120Blacklist"
#define kNotificationName @"com.hoangdus.speedsterprefs-updated"

@interface AppBlacklistController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSMutableArray *allApps;       // LSApplicationProxy 对象
@property (nonatomic, strong) NSMutableArray *filteredApps;
@property (nonatomic, strong) NSMutableSet *disabledSet;     // 被禁用的 Bundle ID 集合
@end

@implementation AppBlacklistController

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadBlacklist];
        [self loadInstalledApps];
    }
    return self;
}

// 从 NSUserDefaults 加载已禁用的应用列表（黑名单）
- (void)loadBlacklist {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kBlacklistKey];
    self.disabledSet = [NSMutableSet setWithArray:saved ?: @[]];
}

// 使用 LSApplicationWorkspace 枚举所有已安装应用
- (void)loadInstalledApps {
    self.allApps = [NSMutableArray array];

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return;

    id workspace = [wsClass performSelector:@selector(defaultWorkspace)];
    NSArray *apps = [workspace performSelector:@selector(allInstalledApplications)];

    for (id app in apps) {
        NSString *bundleID = [app performSelector:@selector(applicationIdentifier)];
        if (!bundleID) continue;
        // 排除一些特殊系统标识符
        if ([bundleID hasPrefix:@"com.apple.webapp"]) continue;
        if ([bundleID isEqualToString:@"com.apple.PurpleBuddy"]) continue; // 设置助手
        [self.allApps addObject:app];
    }

    // 按本地化名称排序
    [self.allApps sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *nameA = [a performSelector:@selector(localizedName)] ?: [a performSelector:@selector(applicationIdentifier)];
        NSString *nameB = [b performSelector:@selector(localizedName)] ?: [b performSelector:@selector(applicationIdentifier)];
        return [nameA localizedCompare:nameB];
    }];

    self.filteredApps = [self.allApps mutableCopy];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationItem.title = @"120Hz 应用排除";

    // 搜索栏
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    // 表格
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    [self.view addSubview:self.tableView];

    // 长按复制 Bundle ID 的手势
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tableView addGestureRecognizer:longPress];
}

// 保存黑名单到 NSUserDefaults 并通知 Tweak
- (void)saveBlacklist {
    NSArray *list = [self.disabledSet allObjects];
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:kBlacklistKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 发送 Darwin 通知，Tweak 端会重新读取配置
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.hoangdus.speedsterprefs-updated"),
        NULL, NULL, YES
    );
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    id app = self.filteredApps[indexPath.row];
    NSString *bundleID = [app performSelector:@selector(applicationIdentifier)];
    NSString *displayName = [app performSelector:@selector(localizedName)] ?: bundleID;

    cell.textLabel.text = displayName;
    cell.detailTextLabel.text = bundleID;
    cell.detailTextLabel.textColor = [UIColor grayColor];

    // 应用图标
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID];
    if (icon) {
        cell.imageView.image = icon;
        cell.imageView.layer.cornerRadius = 6;
        cell.imageView.clipsToBounds = YES;
    } else {
        cell.imageView.image = nil;
    }

    // 开关状态（ON = 不禁用 120Hz，OFF = 加入排除列表）
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    sw.on = ![self.disabledSet containsObject:bundleID];

    return cell;
}

#pragma mark - UITableViewDelegate

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"已安装 %ld 个应用 | 已排除 %ld 个",
            (long)self.filteredApps.count, (long)self.disabledSet.count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 52;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

#pragma mark - Switch 切换事件

- (void)switchToggled:(UISwitch *)sender {
    // 通过 cell 位置找到对应的 indexPath（比 tag 更可靠，搜索后也能正确对应）
    UIView *cellView = (UIView *)sender;
    while (cellView && ![cellView isKindOfClass:[UITableViewCell class]]) {
        cellView = cellView.superview;
    }
    if (!cellView) return;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:(UITableViewCell *)cellView];
    if (!indexPath) return;

    id app = self.filteredApps[indexPath.row];
    NSString *bundleID = [app performSelector:@selector(applicationIdentifier)];
    if (!bundleID) return;

    if (sender.on) {
        // 打开 = 不禁用 120Hz = 从黑名单移除
        [self.disabledSet removeObject:bundleID];
    } else {
        // 关闭 = 禁用 120Hz = 加入黑名单
        [self.disabledSet addObject:bundleID];
    }

    [self saveBlacklist];

    // 更新 header 显示统计
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchText = searchController.searchBar.text;
    if (searchText.length == 0) {
        self.filteredApps = [self.allApps mutableCopy];
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id app, NSDictionary *bindings) {
            NSString *name = [app performSelector:@selector(localizedName)] ?: @"";
            NSString *bundleID = [app performSelector:@selector(applicationIdentifier)] ?: @"";
            NSString *lowerSearch = searchText.lowercaseString;
            return [name.lowercaseString containsString:lowerSearch] ||
                   [bundleID.lowercaseString containsString:lowerSearch];
        }];
        self.filteredApps = [[self.allApps filteredArrayUsingPredicate:predicate] mutableCopy];
    }

    [self.tableView reloadData];
}

#pragma mark - 长按复制 Bundle ID

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;

    id app = self.filteredApps[indexPath.row];
    NSString *bundleID = [app performSelector:@selector(applicationIdentifier)];
    if (!bundleID) return;

    [UIPasteboard generalPasteboard].string = bundleID;

    // 简单反馈提示
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 40)];
    toast.center = CGPointMake(self.view.center.x, self.view.bounds.size.height - 120);
    toast.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.85];
    toast.textColor = [UIColor whiteColor];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:14];
    toast.text = [NSString stringWithFormat:@"已复制: %@", bundleID];
    toast.layer.cornerRadius = 10;
    toast.clipsToBounds = YES;
    toast.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:toast];

    [UIView animateWithDuration:0.3 delay:1.2 options:UIViewAnimationOptionCurveEaseOut animations:^{
        toast.alpha = 0;
    } completion:^(BOOL finished) {
        [toast removeFromSuperview];
    }];
}

@end
