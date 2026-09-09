#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#import <CPUthermalPaths.h>

@interface CPUthermalAppListController : PSListController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSDictionary *> *allApps;
@property(nonatomic,copy) NSString *searchTerm;
@property(nonatomic,strong) UISearchController *searchController;
@end

@implementation CPUthermalAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = S("指定应用低功耗");
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = S("名称或 Bundle ID");
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (NSString *)stringFromObject:(id)object selectors:(NSArray<NSString *> *)selectors {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}

- (void)addApplicationAtPath:(NSString *)appPath toMap:(NSMutableDictionary *)map {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:S("Info.plist")]];
    NSString *bundleID = info[S("CFBundleIdentifier")];
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0 || [bundleID hasPrefix:S("com.apple.")]) return;
    NSString *name = info[S("CFBundleDisplayName")];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = info[S("CFBundleName")];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bundleID;
    map[bundleID] = @{S("id"):bundleID, S("name"):name};
}

- (NSArray<NSDictionary *> *)enumerateApplications {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    @try {
        Class workspaceClass = NSClassFromString(S("LSApplicationWorkspace"));
        id workspace = [workspaceClass respondsToSelector:NSSelectorFromString(S("defaultWorkspace"))] ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(S("defaultWorkspace"))) : nil;
        id applications = [workspace respondsToSelector:NSSelectorFromString(S("allApplications"))] ? ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(S("allApplications"))) : nil;
        if ([applications isKindOfClass:[NSArray class]]) for (id proxy in applications) {
            NSString *bundleID = [self stringFromObject:proxy selectors:@[S("applicationIdentifier"),S("bundleIdentifier")]];
            if (bundleID.length == 0 || [bundleID hasPrefix:S("com.apple.")]) continue;
            NSString *name = [self stringFromObject:proxy selectors:@[S("localizedName"),S("itemName"),S("localizedShortName")]] ?: bundleID;
            map[bundleID] = @{S("id"):bundleID, S("name"):name};
        }
    } @catch (__unused NSException *exception) {}
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in @[S("/var/mobile/Containers/Bundle/Application"), S("/var/containers/Bundle/Application")]) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *container = [root stringByAppendingPathComponent:uuid];
            for (NSString *entry in [fm contentsOfDirectoryAtPath:container error:nil] ?: @[]) if ([[entry pathExtension] caseInsensitiveCompare:S("app")] == NSOrderedSame) [self addApplicationAtPath:[container stringByAppendingPathComponent:entry] toMap:map];
        }
    }
    return [map allValues];
}

- (NSMutableSet<NSString *> *)enabledBundleIDs {
    id value = CPUthermalReadPrefs()[S("lowPowerApps")];
    return [NSMutableSet setWithArray:[value isKindOfClass:[NSArray class]] ? value : @[]];
}

- (NSArray<NSDictionary *> *)visibleApplications {
    if (!self.allApps) self.allApps = [self enumerateApplications];
    NSString *term = [[self.searchTerm ?: S("") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *app in self.allApps) {
        NSString *name = app[S("name")], *bundleID = app[S("id")];
        if (term.length == 0 || [[name lowercaseString] containsString:term] || [[bundleID lowercaseString] containsString:term]) [visible addObject:app];
    }
    NSSet *enabled = [self enabledBundleIDs];
    [visible sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ae = [enabled containsObject:a[S("id")]], be = [enabled containsObject:b[S("id")]];
        if (ae != be) return ae ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = [a[S("name")] localizedCaseInsensitiveCompare:b[S("name")]];
        return r == NSOrderedSame ? [a[S("id")] compare:b[S("id")]] : r;
    }];
    return visible;
}

- (void)rebuildSpecifiers {
    if (!_specifiers) _specifiers = [[NSMutableArray alloc] init];
    [_specifiers removeAllObjects];
    @try {
        NSArray *apps = [self visibleApplications];
        NSUInteger enabledCount = [self enabledBundleIDs].count;
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        NSString *footer = self.searchTerm.length ? [NSString stringWithFormat:S("找到 %lu 个应用；已开启应用优先显示。"), (unsigned long)apps.count] : [NSString stringWithFormat:S("已指定 %lu 个应用。进入所选应用自动启用低功耗；退至后台后恢复插件对应模式。"), (unsigned long)enabledCount];
        if (!self.allApps.count) footer = S("没有枚举到可用的第三方应用。");
        [group setProperty:footer forKey:S("footerText")];
        [_specifiers addObject:group];
        for (NSDictionary *app in apps) {
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:app[S("name")] target:self set:@selector(setAppEnabled:specifier:) get:@selector(appEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            specifier.identifier = app[S("id")];
            [specifier setProperty:app[S("id")] forKey:S("id")];
            [_specifiers addObject:specifier];
        }
    } @catch (__unused NSException *exception) {
        [_specifiers removeAllObjects];
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("应用列表加载异常。") forKey:S("footerText")];
        [_specifiers addObject:group];
    }
}

- (NSArray *)specifiers { if (!_specifiers) [self rebuildSpecifiers]; return _specifiers; }
- (id)appEnabled:(PSSpecifier *)specifier { return @([[self enabledBundleIDs] containsObject:specifier.identifier ?: [specifier propertyForKey:S("id")]]); }
- (void)setAppEnabled:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleID = specifier.identifier ?: [specifier propertyForKey:S("id")];
    if (bundleID.length == 0) return;
    NSMutableSet *enabled = [self enabledBundleIDs];
    [value boolValue] ? [enabled addObject:bundleID] : [enabled removeObject:bundleID];
    NSMutableDictionary *prefs = CPUthermalReadMutablePrefs() ?: [NSMutableDictionary dictionary];
    prefs[S("lowPowerApps")] = [[enabled allObjects] sortedArrayUsingSelector:@selector(compare:)];
    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
    dispatch_async(dispatch_get_main_queue(), ^{ [self rebuildSpecifiers]; [self.table reloadData]; });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { self.searchTerm = searchController.searchBar.text ?: S(""); [self rebuildSpecifiers]; [self.table reloadData]; }
@end
