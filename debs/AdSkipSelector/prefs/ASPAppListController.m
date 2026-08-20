#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../SharedPrefs.h"

@interface ASPAppInfo : NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *bundleID;
@property(nonatomic,strong) UIImage *icon;
@end
@implementation ASPAppInfo @end

@interface ASPAppListController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,strong) NSArray<ASPAppInfo *> *apps;
@property(nonatomic,strong) NSArray<ASPAppInfo *> *filtered;
@property(nonatomic,strong) NSMutableSet<NSString *> *enabledIDs;
@end

@implementation ASPAppListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AdSkip 应用选择";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.enabledIDs = [ASPEnabledBundleIDs() mutableCopy];
    [self reloadApplications];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    self.tableView.rowHeight = 72;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"名字或者标识符";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)reloadApplications {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = ((id(*)(id,SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    NSArray *proxies = ((id(*)(id,SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allApplications"));
    NSMutableArray *result = [NSMutableArray array];
    NSString *own = NSBundle.mainBundle.bundleIdentifier;
    for (id proxy in proxies) {
        NSString *bid = nil, *name = nil, *type = nil;
        @try {
            bid = [proxy valueForKey:@"applicationIdentifier"];
            name = [proxy valueForKey:@"localizedName"];
            type = [proxy valueForKey:@"applicationType"];
        } @catch (__unused NSException *e) { continue; }
        if (!bid.length || !name.length || [bid isEqualToString:own]) continue;
        if ([type isKindOfClass:NSString.class] && ![type isEqualToString:@"User"]) continue;
        ASPAppInfo *info = [ASPAppInfo new]; info.bundleID = bid; info.name = name;
        SEL iconSEL = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([UIApplication.sharedApplication respondsToSelector:iconSEL])
            info.icon = ((id(*)(id,SEL,id,NSInteger,CGFloat))objc_msgSend)(UIApplication.sharedApplication, iconSEL, bid, 2, UIScreen.mainScreen.scale);
        [result addObject:info];
    }
    self.apps = [result sortedArrayUsingComparator:^NSComparisonResult(ASPAppInfo *a, ASPAppInfo *b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
    self.filtered = self.apps;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.filtered.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"已开启 %lu 个应用", (unsigned long)self.enabledIDs.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"Application";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    ASPAppInfo *app = self.filtered[indexPath.row];
    cell.textLabel.text = app.name; cell.textLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
    cell.detailTextLabel.text = app.bundleID; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = app.icon ?: [UIImage systemImageNamed:@"app.fill"];
    cell.imageView.layer.cornerRadius = 12; cell.imageView.clipsToBounds = YES;
    UISwitch *toggle = [UISwitch new]; toggle.on = [self.enabledIDs containsObject:app.bundleID];
    objc_setAssociatedObject(toggle, @selector(toggleChanged:), app.bundleID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    NSString *bid = objc_getAssociatedObject(sender, _cmd);
    if (!bid.length) return;
    if (sender.on) [self.enabledIDs addObject:bid]; else [self.enabledIDs removeObject:bid];
    ASPSaveEnabledBundleIDs(self.enabledIDs);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!q.length) self.filtered = self.apps;
    else self.filtered = [self.apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ASPAppInfo *app, NSDictionary *_) {
        return [app.name localizedCaseInsensitiveContainsString:q] || [app.bundleID localizedCaseInsensitiveContainsString:q];
    }]];
    [self.tableView reloadData];
}
@end
