#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import "../SharedPrefs.h"

@interface ASPAppInfo : NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *bundleID;
@end
@implementation ASPAppInfo @end

static NSArray<ASPAppInfo *> *ASPAppsViaLS(void) {
    NSMutableDictionary<NSString *, ASPAppInfo *> *byID = [NSMutableDictionary dictionary];
    @try {
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        id ws = c ? ((id(*)(id,SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace")) : nil;
        NSArray *all = ws ? ((id(*)(id,SEL))objc_msgSend)(ws, NSSelectorFromString(@"allApplications")) : nil;
        for (id proxy in [all isKindOfClass:NSArray.class] ? all : @[]) {
            NSString *bid = [proxy valueForKey:@"applicationIdentifier"];
            NSString *name = [proxy valueForKey:@"localizedName"];
            if (![bid isKindOfClass:NSString.class] || !bid.length || [bid hasPrefix:@"com.apple."]) continue;
            if (![name isKindOfClass:NSString.class] || !name.length) name = bid;
            ASPAppInfo *a = [ASPAppInfo new]; a.bundleID = bid; a.name = name; byID[bid] = a;
        }
    } @catch (__unused NSException *e) {}
    return byID.allValues;
}

static NSArray<ASPAppInfo *> *ASPAppsViaFiles(void) {
    NSMutableDictionary<NSString *, ASPAppInfo *> *byID = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in @[@"/var/mobile/Containers/Bundle/Application", @"/var/containers/Bundle/Application"]) {
        for (NSString *uid in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *dir = [root stringByAppendingPathComponent:uid];
            for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
                if (![item hasSuffix:@".app"]) continue;
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[[dir stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bid = info[@"CFBundleIdentifier"];
                if (!bid.length || [bid hasPrefix:@"com.apple."]) continue;
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bid;
                ASPAppInfo *a = [ASPAppInfo new]; a.bundleID = bid; a.name = name; byID[bid] = a;
            }
        }
    }
    return byID.allValues;
}

static NSArray<ASPAppInfo *> *ASPAllApps(void) {
    NSArray *apps = ASPAppsViaLS();
    if (!apps.count) apps = ASPAppsViaFiles();
    return apps ?: @[];
}

@interface ASPAppListController : PSListController <UISearchResultsUpdating>
@property(nonatomic,strong) UISearchController *aspSearchController;
@property(nonatomic,copy) NSString *aspSearchTerm;
@property(nonatomic,strong) NSArray<ASPAppInfo *> *aspAllApps;
@end

@implementation ASPAppListController

- (NSString *)navigationTitle { return @"AdSkip 屏蔽广告"; }

- (NSArray<ASPAppInfo *> *)visibleApps {
    NSSet *enabled = ASPEnabledBundleIDs();
    NSString *term = [self.aspSearchTerm stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *visible = [NSMutableArray array];
    for (ASPAppInfo *app in self.aspAllApps ?: @[]) {
        if (term.length &&
            [app.name rangeOfString:term options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [app.bundleID rangeOfString:term options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [visible addObject:app];
    }
    [visible sortUsingComparator:^NSComparisonResult(ASPAppInfo *a, ASPAppInfo *b) {
        BOOL ae = [enabled containsObject:a.bundleID], be = [enabled containsObject:b.bundleID];
        if (ae != be) return ae ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = [a.name localizedCaseInsensitiveCompare:b.name];
        return r == NSOrderedSame ? [a.bundleID localizedCaseInsensitiveCompare:b.bundleID] : r;
    }];
    return visible;
}

- (void)rebuildSpecifiers {
    if (!_specifiers) _specifiers = [[NSMutableArray alloc] init];
    [_specifiers removeAllObjects];
    @try {
        NSArray<ASPAppInfo *> *apps = [self visibleApps];
        NSUInteger enabledCount = ASPEnabledBundleIDs().count;
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        NSString *footer = self.aspSearchTerm.length
            ? [NSString stringWithFormat:@"找到 %lu 个应用；已开启应用优先显示", (unsigned long)apps.count]
            : [NSString stringWithFormat:@"已开启 %lu 个应用；开启项优先显示", (unsigned long)enabledCount];
        [group setProperty:footer forKey:PSFooterTextGroupKey];
        [_specifiers addObject:group];
        for (ASPAppInfo *app in apps) {
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:app.name
                                                             target:self
                                                                set:@selector(setSwitch:forSpecifier:)
                                                                get:@selector(getSwitchForSpecifier:)
                                                             detail:nil
                                                               cell:PSSwitchCell
                                                               edit:nil];
            s.identifier = app.bundleID;
            [s setProperty:app.bundleID forKey:PSIDKey];
            [_specifiers addObject:s];
        }
    } @catch (__unused NSException *e) {
        [_specifiers removeAllObjects];
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:@"应用列表加载异常" forKey:PSFooterTextGroupKey];
        [_specifiers addObject:group];
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        self.aspAllApps = ASPAllApps();
        [self rebuildSpecifiers];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.aspSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.aspSearchController.obscuresBackgroundDuringPresentation = NO;
    self.aspSearchController.searchResultsUpdater = self;
    self.aspSearchController.searchBar.placeholder = @"名称或 Bundle ID";
    self.navigationItem.searchController = self.aspSearchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.aspSearchTerm = searchController.searchBar.text ?: @"";
    [self rebuildSpecifiers];
    [self.table reloadData];
}

- (void)setSwitch:(NSNumber *)value forSpecifier:(PSSpecifier *)specifier {
    NSString *bid = specifier.identifier ?: [specifier propertyForKey:PSIDKey];
    if (!bid.length) return;
    NSMutableSet *enabled = [ASPEnabledBundleIDs() mutableCopy];
    value.boolValue ? [enabled addObject:bid] : [enabled removeObject:bid];
    ASPSaveEnabledBundleIDs(enabled);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildSpecifiers];
        [self.table reloadData];
    });
}

- (NSNumber *)getSwitchForSpecifier:(PSSpecifier *)specifier {
    NSString *bid = specifier.identifier ?: [specifier propertyForKey:PSIDKey];
    return @(bid.length && [ASPEnabledBundleIDs() containsObject:bid]);
}

@end
