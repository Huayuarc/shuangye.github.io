#import "DeepCleanController.h"
#import "AppDelegate.h"

static NSString *RHSizeString(unsigned long long bytes) {
    NSByteCountFormatter *f = [NSByteCountFormatter new];
    f.countStyle = NSByteCountFormatterCountStyleFile;
    return [f stringFromByteCount:(long long)bytes];
}

static unsigned long long RHDirectorySize(NSString *path) {
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) return [[[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] objectForKey:NSFileSize] unsignedLongLongValue];
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:path];
    for (NSString *sub in e) {
        NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:[path stringByAppendingPathComponent:sub] error:nil];
        if ([a.fileType isEqualToString:NSFileTypeRegular]) total += a.fileSize;
    }
    return total;
}

static NSArray *RHSubpaths(NSString *root, NSArray *suffixes) {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
    for (NSString *child in children) for (NSString *suffix in suffixes) {
        NSString *p = [[root stringByAppendingPathComponent:child] stringByAppendingPathComponent:suffix];
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) [result addObject:p];
    }
    return result;
}

@interface DeepCleanController ()
@property(nonatomic, strong) NSMutableArray *items;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation DeepCleanController
+ (instancetype)sharedInstance { static id x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Localized(@"Deep Clean");
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Localized(@"Clean") style:UIBarButtonItemStylePlain target:self action:@selector(confirmClean)];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(scan) forControlEvents:UIControlEventValueChanged];
    self.items = [NSMutableArray array];
    [self buildItems];
    [self scan];
}

- (void)buildItems {
    NSString *containers = @"/var/mobile/Containers/Data/Application";
    self.items = [@[
      [@{ @"title":Localized(@"App Caches"), @"detail":Localized(@"Re-creatable cache files from installed apps"), @"paths":RHSubpaths(containers,@[@"Library/Caches"]), @"selected":@YES, @"bytes":@0 } mutableCopy],
      [@{ @"title":Localized(@"Temporary Files"), @"detail":Localized(@"Application tmp folders and system temporary files"), @"paths":[RHSubpaths(containers,@[@"tmp"]) arrayByAddingObjectsFromArray:@[@"/var/tmp",@"/var/mobile/Library/Caches/Snapshots"]], @"selected":@YES, @"bytes":@0 } mutableCopy],
      [@{ @"title":Localized(@"Web Data"), @"detail":Localized(@"WebKit caches, cookies and website data; websites may sign out"), @"paths":RHSubpaths(containers,@[@"Library/WebKit/WebsiteData",@"Library/WebKit/NetworkCache",@"Library/Cookies",@"Library/HTTPStorages"]), @"selected":@NO, @"bytes":@0 } mutableCopy],
      [@{ @"title":Localized(@"System Logs"), @"detail":Localized(@"Crash reports, diagnostic and log files"), @"paths":@[@"/var/mobile/Library/Logs",@"/var/mobile/Library/Caches/CrashReporter",@"/var/mobile/Library/Logs/CrashReporter",@"/var/log"], @"selected":@YES, @"bytes":@0 } mutableCopy],
      [@{ @"title":Localized(@"System Caches"), @"detail":Localized(@"Re-creatable mobile user and system cache data"), @"paths":@[@"/var/mobile/Library/Caches/com.apple.keyboards",@"/var/mobile/Library/Caches/com.apple.UIKit.pboard",@"/var/mobile/Library/Caches/com.apple.nsurlsessiond",@"/var/mobile/Library/Caches/com.apple.WebKit.Networking"], @"selected":@YES, @"bytes":@0 } mutableCopy]
    ] mutableCopy];
}

- (void)scan {
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.refreshControl beginRefreshing];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        for (NSMutableDictionary *item in self.items) {
            unsigned long long total=0; for (NSString *p in item[@"paths"]) total += RHDirectorySize(p);
            item[@"bytes"] = @(total);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self.refreshControl endRefreshing]; self.navigationItem.rightBarButtonItem.enabled=YES; [self.tableView reloadData]; });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0 ? self.items.count : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section==0?Localized(@"Cleanable Categories"):Localized(@"Summary"); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return section==0?Localized(@"Documents, photos, messages, contacts, health data and keychains are excluded."):nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section==1) {
        unsigned long long t=0; for (NSDictionary *i in self.items) if([i[@"selected"] boolValue]) t += [i[@"bytes"] unsignedLongLongValue];
        cell.textLabel.text=Localized(@"Selected Cleanable Space"); cell.detailTextLabel.text=RHSizeString(t); cell.selectionStyle=UITableViewCellSelectionStyleNone; return cell;
    }
    NSDictionary *item=self.items[ip.row]; cell.textLabel.text=item[@"title"];
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",item[@"detail"],RHSizeString([item[@"bytes"] unsignedLongLongValue])];
    cell.accessoryType=[item[@"selected"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip { [tableView deselectRowAtIndexPath:ip animated:YES]; if(ip.section){return;} NSMutableDictionary *i=self.items[ip.row];i[@"selected"]=@(![i[@"selected"] boolValue]);[tableView reloadData]; }

- (void)confirmClean {
    unsigned long long total=0; for(NSDictionary *i in self.items) if([i[@"selected"] boolValue]) total += [i[@"bytes"] unsignedLongLongValue];
    NSString *msg=[NSString stringWithFormat:Localized(@"Clean selected categories and reclaim approximately %@?"),RHSizeString(total)];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:Localized(@"Deep Clean") message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:Localized(@"Clean") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x){[self cleanSelected];}]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)cleanSelected {
    self.navigationItem.rightBarButtonItem.enabled=NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        unsigned long long before=0,after=0;
        for(NSDictionary *i in self.items) if([i[@"selected"] boolValue]) for(NSString *p in i[@"paths"]) {
            before += RHDirectorySize(p); BOOL dir=NO;
            if([NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && dir) {
                for(NSString *sub in [NSFileManager.defaultManager contentsOfDirectoryAtPath:p error:nil] ?: @[]) [NSFileManager.defaultManager removeItemAtPath:[p stringByAppendingPathComponent:sub] error:nil];
            } else [NSFileManager.defaultManager removeItemAtPath:p error:nil];
            after += RHDirectorySize(p);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self buildItems]; [self scan]; [AppDelegate showMessage:[NSString stringWithFormat:Localized(@"Freed %@."),RHSizeString(before>after?before-after:0)] title:Localized(@"Clean Complete")]; });
    });
}
@end
