#import "PluginConfigViewController.h"
#import "AppDelegate.h"

static NSString *RHPCChoicyPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist");
}

static NSArray *RHPCPlugins(void) {
    NSString *dir = jbroot(@"/Library/MobileSubstrate/DynamicLibraries");
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"dylib"]) continue;
        NSString *name = file.stringByDeletingPathExtension;
        if ([name isEqualToString:@"   Choicy"] || [name isEqualToString:@"Choicy"] || [name isEqualToString:@"MobileSafety"]) continue;
        NSDictionary *filter = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]]];
        NSString *packageName = filter[@"Name"] ?: filter[@"Label"] ?: @"";
        [result addObject:@{ @"name": name, @"subtitle": packageName }];
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

@interface PluginConfigViewController ()
@property(nonatomic, strong) NSArray *plugins;
@property(nonatomic, strong) NSMutableSet *disabled;
@end

@implementation PluginConfigViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Localized(@"Plugin Configuration");
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.plugins = RHPCPlugins();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:RHPCChoicyPath()];
    self.disabled = [NSMutableSet setWithArray:prefs[@"globalDeniedTweaks"] ?: @[]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.plugins = RHPCPlugins();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:RHPCChoicyPath()];
    self.disabled = [NSMutableSet setWithArray:prefs[@"globalDeniedTweaks"] ?: @[]];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.plugins.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return Localized(@"Installed Plugins"); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return Localized(@"Changes take effect after respring. Choicy and MobileSafety always remain enabled."); }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *plugin = self.plugins[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = plugin[@"name"];
    cell.detailTextLabel.text = plugin[@"subtitle"];
    UISwitch *toggle = [UISwitch new];
    toggle.on = ![self.disabled containsObject:plugin[@"name"]];
    toggle.tag = indexPath.row;
    [toggle addTarget:self action:@selector(pluginSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)pluginSwitchChanged:(UISwitch *)sender {
    if (sender.tag >= self.plugins.count) return;
    NSString *name = self.plugins[sender.tag][@"name"];
    if (sender.on) [self.disabled removeObject:name]; else [self.disabled addObject:name];
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:RHPCChoicyPath()] mutableCopy];
    if (!prefs) {
        sender.on = !sender.on;
        [AppDelegate showMessage:Localized(@"Install Choicy from Sileo first, then try again.") title:Localized(@"Plugin Injection")];
        return;
    }
    prefs[@"globalDeniedTweaks"] = [[self.disabled allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    if (![prefs writeToFile:RHPCChoicyPath() atomically:YES]) {
        sender.on = !sender.on;
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.opa334.choicyprefs/ReloadPrefs"), NULL, NULL, YES);
}
@end
