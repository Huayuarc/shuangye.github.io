#import "DeepCleanController.h"
#import "AppDelegate.h"
#include <limits.h>

static NSString *RHSizeString(unsigned long long bytes) {
    NSByteCountFormatter *f=[NSByteCountFormatter new]; f.countStyle=NSByteCountFormatterCountStyleFile;
    return [f stringFromByteCount:(long long)bytes];
}

static BOOL RHIsUUID(NSString *s) {
    NSUUID *u=[[NSUUID alloc] initWithUUIDString:s]; return u && s.length==36;
}

static NSString *RHRealPath(NSString *path) {
    char out[PATH_MAX]; if (!realpath(path.fileSystemRepresentation,out)) return nil; return @(out);
}

static BOOL RHSafeContainerRoot(NSString *path, NSString *kind) {
    NSString *real=RHRealPath(path); if(!real) return NO;
    NSString *prefix=@"/private/var/mobile/Containers/Data/Application/";
    if(![real hasPrefix:prefix]) return NO;
    NSString *rest=[real substringFromIndex:prefix.length]; NSArray *parts=[rest pathComponents];
    if(parts.count<2 || !RHIsUUID(parts[0])) return NO;
    NSString *suffix=[[parts subarrayWithRange:NSMakeRange(1,parts.count-1)] componentsJoinedByString:@"/"];
    if([kind isEqualToString:@"cache"]) return [suffix isEqualToString:@"Library/Caches"];
    if([kind isEqualToString:@"tmp"]) return [suffix isEqualToString:@"tmp"];
    if([kind isEqualToString:@"web"]) return [@[@"Library/WebKit/WebsiteData",@"Library/WebKit/NetworkCache",@"Library/Cookies",@"Library/HTTPStorages"] containsObject:suffix];
    return NO;
}

static NSArray *RHContainerPaths(NSArray *suffixes, NSString *kind) {
    NSString *root=@"/var/mobile/Containers/Data/Application"; NSMutableArray *r=[NSMutableArray array];
    for(NSString *uuid in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]?:@[]) {
        if(!RHIsUUID(uuid)) continue;
        NSString *base=[root stringByAppendingPathComponent:uuid];
        NSDictionary *baseAttr=[NSFileManager.defaultManager attributesOfItemAtPath:base error:nil];
        if([baseAttr.fileType isEqualToString:NSFileTypeSymbolicLink]) continue;
        for(NSString *suffix in suffixes) { NSString *p=[base stringByAppendingPathComponent:suffix]; if(RHSafeContainerRoot(p,kind)) [r addObject:p]; }
    }
    return r;
}

static BOOL RHSymlink(NSString *path) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileType isEqualToString:NSFileTypeSymbolicLink];
}

static unsigned long long RHSafeSize(NSString *root, NSString *kind) {
    if(!RHSafeContainerRoot(root,kind)) return 0; unsigned long long total=0;
    NSDirectoryEnumerator *e=[NSFileManager.defaultManager enumeratorAtPath:root];
    for(NSString *sub in e) { NSString *p=[root stringByAppendingPathComponent:sub]; NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil]; if([a.fileType isEqualToString:NSFileTypeSymbolicLink]) {[e skipDescendants];continue;} if([a.fileType isEqualToString:NSFileTypeRegular]) total+=a.fileSize; }
    return total;
}

static BOOL RHIsLogFile(NSString *name) {
    return [@[@"log",@"ips",@"crash",@"panic",@"diag"] containsObject:name.pathExtension.lowercaseString];
}

static unsigned long long RHLogSize(void) {
    unsigned long long total=0; for(NSString *root in @[@"/var/mobile/Library/Logs/CrashReporter",@"/var/mobile/Library/Caches/CrashReporter"]) {
        NSDirectoryEnumerator *e=[NSFileManager.defaultManager enumeratorAtPath:root]; for(NSString *s in e) { NSString *p=[root stringByAppendingPathComponent:s]; NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil]; if([a.fileType isEqualToString:NSFileTypeRegular]&&RHIsLogFile(s)) total+=a.fileSize; }
    } return total;
}

static unsigned long long RHCleanContainerRoot(NSString *root, NSString *kind) {
    if(!RHSafeContainerRoot(root,kind)) return 0; unsigned long long before=RHSafeSize(root,kind);
    for(NSString *sub in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]?:@[]) { NSString *p=[root stringByAppendingPathComponent:sub]; if(RHSymlink(p)) continue; [NSFileManager.defaultManager removeItemAtPath:p error:nil]; }
    return before-RHSafeSize(root,kind);
}

static unsigned long long RHCleanLogs(void) {
    unsigned long long freed=0; for(NSString *root in @[@"/var/mobile/Library/Logs/CrashReporter",@"/var/mobile/Library/Caches/CrashReporter"]) {
        NSArray *subs=[[NSFileManager.defaultManager enumeratorAtPath:root] allObjects]; for(NSString *s in subs) { NSString *p=[root stringByAppendingPathComponent:s]; NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil]; if([a.fileType isEqualToString:NSFileTypeRegular]&&RHIsLogFile(s)) { freed+=a.fileSize; [NSFileManager.defaultManager removeItemAtPath:p error:nil]; } }
    } return freed;
}

@interface DeepCleanController ()
@property(nonatomic,strong) NSMutableArray *items;
@end
@implementation DeepCleanController
+ (instancetype)sharedInstance { static id x;static dispatch_once_t once;dispatch_once(&once,^{x=[self new];});return x; }
- (void)viewDidLoad { [super viewDidLoad];self.title=Localized(@"Deep Clean");self.tableView=[[UITableView alloc]initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:Localized(@"Clean") style:UIBarButtonItemStylePlain target:self action:@selector(confirmClean)];self.refreshControl=[UIRefreshControl new];[self.refreshControl addTarget:self action:@selector(scan) forControlEvents:UIControlEventValueChanged];[self buildItems];[self scan]; }
- (void)buildItems { self.items=[@[
 [@{@"title":Localized(@"App Caches"),@"detail":Localized(@"Re-creatable cache files from installed apps"),@"kind":@"cache",@"paths":RHContainerPaths(@[@"Library/Caches"],@"cache"),@"selected":@YES,@"bytes":@0} mutableCopy],
 [@{@"title":Localized(@"Temporary Files"),@"detail":Localized(@"Only installed application tmp folders"),@"kind":@"tmp",@"paths":RHContainerPaths(@[@"tmp"],@"tmp"),@"selected":@YES,@"bytes":@0} mutableCopy],
 [@{@"title":Localized(@"Web Data"),@"detail":Localized(@"WebKit caches, cookies and website data; websites may sign out"),@"kind":@"web",@"paths":RHContainerPaths(@[@"Library/WebKit/WebsiteData",@"Library/WebKit/NetworkCache",@"Library/Cookies",@"Library/HTTPStorages"],@"web"),@"selected":@NO,@"bytes":@0} mutableCopy],
 [@{@"title":Localized(@"Diagnostic Logs"),@"detail":Localized(@"Only crash and diagnostic report files"),@"kind":@"logs",@"paths":@[],@"selected":@YES,@"bytes":@0} mutableCopy]
 ] mutableCopy]; }
- (void)scan { self.navigationItem.rightBarButtonItem.enabled=NO;[self.refreshControl beginRefreshing];dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{for(NSMutableDictionary *i in self.items){unsigned long long t=0;if([i[@"kind"] isEqual:@"logs"])t=RHLogSize();else for(NSString *p in i[@"paths"])t+=RHSafeSize(p,i[@"kind"]);i[@"bytes"]=@(t);}dispatch_async(dispatch_get_main_queue(),^{[self.refreshControl endRefreshing];self.navigationItem.rightBarButtonItem.enabled=YES;[self.tableView reloadData];});}); }
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 2;}- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return s?1:self.items.count;}
- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s{return s?Localized(@"Summary"):Localized(@"Cleanable Categories");}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s{return s?nil:Localized(@"Strict safe mode: app bundles, system paths, documents, photos and keychains are never touched.");}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip{UITableViewCell*c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];if(ip.section){unsigned long long n=0;for(NSDictionary*i in self.items)if([i[@"selected"]boolValue])n+=[i[@"bytes"]unsignedLongLongValue];c.textLabel.text=Localized(@"Selected Cleanable Space");c.detailTextLabel.text=RHSizeString(n);c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}NSDictionary*i=self.items[ip.row];c.textLabel.text=i[@"title"];c.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",i[@"detail"],RHSizeString([i[@"bytes"]unsignedLongLongValue])];c.accessoryType=[i[@"selected"]boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;return c;}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip{[t deselectRowAtIndexPath:ip animated:YES];if(ip.section)return;NSMutableDictionary*i=self.items[ip.row];i[@"selected"]=@(![i[@"selected"]boolValue]);[t reloadData];}
- (void)confirmClean{unsigned long long n=0;for(NSDictionary*i in self.items)if([i[@"selected"]boolValue])n+=[i[@"bytes"]unsignedLongLongValue];UIAlertController*a=[UIAlertController alertControllerWithTitle:Localized(@"Deep Clean") message:[NSString stringWithFormat:Localized(@"Clean selected categories and reclaim approximately %@?"),RHSizeString(n)] preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:Localized(@"Clean") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction*x){[self cleanSelected];}]];[self presentViewController:a animated:YES completion:nil];}
- (void)cleanSelected{self.navigationItem.rightBarButtonItem.enabled=NO;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{unsigned long long freed=0;for(NSDictionary*i in self.items)if([i[@"selected"]boolValue]){if([i[@"kind"]isEqual:@"logs"])freed+=RHCleanLogs();else for(NSString*p in i[@"paths"])freed+=RHCleanContainerRoot(p,i[@"kind"]); }dispatch_async(dispatch_get_main_queue(),^{[self buildItems];[self scan];[AppDelegate showMessage:[NSString stringWithFormat:Localized(@"Freed %@."),RHSizeString(freed)] title:Localized(@"Clean Complete")];});});}
@end
