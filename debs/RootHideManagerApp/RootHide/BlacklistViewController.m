// ref https://github.com/XsF1re/FlyJB-App

#import "BlacklistViewController.h"
#include "AppDelegate.h"
#import "AppInfo.h"

static NSString *RHChoicyPrefsPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist");
}

static BOOL RHChoicyDisabledForApp(NSString *bundleID) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:RHChoicyPrefsPath()];
    return [prefs[@"appSettings"][bundleID][@"tweakInjectionDisabled"] boolValue];
}

static void RHSetChoicyModeForApp(NSString *bundleID, NSInteger mode) {
    if (!bundleID.length) return;
    NSString *path = RHChoicyPrefsPath();
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *apps = [prefs[@"appSettings"] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *app = [apps[bundleID] mutableCopy] ?: [NSMutableDictionary new];
    if (mode == 2) {
        app[@"tweakInjectionDisabled"] = @NO;
        app[@"customTweakConfigurationEnabled"] = @YES;
        app[@"allowDenyMode"] = @1;
        app[@"allowedTweaks"] = @[@"RootHideSupport"];
        app[@"deniedTweaks"] = @[];
    } else {
        app[@"tweakInjectionDisabled"] = @(mode == 1);
        [app removeObjectForKey:@"customTweakConfigurationEnabled"];
        [app removeObjectForKey:@"allowDenyMode"];
        [app removeObjectForKey:@"allowedTweaks"];
        [app removeObjectForKey:@"deniedTweaks"];
    }
    apps[bundleID] = app; prefs[@"appSettings"] = apps;
    [prefs writeToFile:path atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.opa334.choicyprefs/ReloadPrefs"), NULL, NULL, YES);
}

static void RHSetChoicyDisabledForApp(NSString *bundleID, BOOL disabled) { RHSetChoicyModeForApp(bundleID, disabled ? 1 : 0); }

static NSArray<NSString *> *RHIdentifiersForApp(AppInfo *app) {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    if (app.bundleIdentifier.length) [ids addObject:app.bundleIdentifier];
    for (LSPlugInKitProxy *plugin in app.plugInKitPlugins ?: @[]) {
        if (plugin.bundleIdentifier.length) [ids addObject:plugin.bundleIdentifier];
    }
    return ids.array;
}

static NSInteger RHShieldMode(NSString *bundleID) {
    NSDictionary *modes = [AppDelegate getDefaultsForKey:@"strictShieldModes"];
    return [modes[bundleID] integerValue];
}

static void RHApplyShieldMode(AppInfo *app, NSInteger mode) {
    NSArray<NSString *> *ids = RHIdentifiersForApp(app);
    NSMutableDictionary *appconfig = [[AppDelegate getDefaultsForKey:@"appconfig"] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *modes = [[AppDelegate getDefaultsForKey:@"strictShieldModes"] mutableCopy] ?: [NSMutableDictionary new];
    for (NSString *identifier in ids) {
        BOOL enabled = mode == 2 || (mode == 1 && [identifier isEqualToString:app.bundleIdentifier]);
        appconfig[identifier] = @(enabled);
        RHSetChoicyModeForApp(identifier, mode);
    }
    for (NSString *identifier in ids) {
        if (mode > 0) modes[identifier] = @(mode); else [modes removeObjectForKey:identifier];
    }
    [AppDelegate setDefaults:appconfig forKey:@"appconfig"];
    [AppDelegate setDefaults:modes forKey:@"strictShieldModes"];
    void killAllForBundle(const char *bundlePath);
    killAllForBundle(app.bundleURL.path.fileSystemRepresentation);
}

static void RHClearDetectionCache(AppInfo *app) {
    NSString *cache = [app.containerURL.path stringByAppendingPathComponent:@"Library/Caches"];
    NSString *realContainer = app.containerURL.path.stringByStandardizingPath;
    NSString *realCache = cache.stringByStandardizingPath;
    if (!realContainer.length || ![realCache hasPrefix:[realContainer stringByAppendingString:@"/"]]) return;
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:cache error:nil] ?: @[]) {
        [NSFileManager.defaultManager removeItemAtPath:[cache stringByAppendingPathComponent:entry] error:nil];
    }
}

BOOL isUUIDPathOf(NSString* path, NSString* parent);

BOOL isDefaultInstallationPath(NSString* path)
{
    return isUUIDPathOf(path, @"/private/var/containers/Bundle/Application/");
}

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray*)allApplications;
- (NSArray*)allInstalledApplications;
@end

@interface BlacklistViewController () {
    UISearchController *searchController;
    NSArray *applications;
    NSArray *appsArray;
    
    NSMutableArray* filteredApps;
    BOOL isFiltered;
    
    BOOL blacklistDisabled;
    BOOL spinlockFixApplied;
}

@end

@implementation BlacklistViewController

+ (instancetype)sharedInstance {
    static BlacklistViewController* sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

-(void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}
- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    if(isFiltered) {
        self->appsArray = [self sortAppList:YES];
    }
    isFiltered = false;
    [self.tableView reloadData];
}

-(void)reloadSearch {
    NSString* searchText = searchController.searchBar.text;
    if(searchText.length == 0) {
        isFiltered = false;
    } else {
        isFiltered = true;
        filteredApps = [[NSMutableArray alloc] init];
        searchText = searchText.lowercaseString;
        for (AppInfo* app in appsArray) {
            NSRange nameRange = [app.name.lowercaseString rangeOfString:searchText options:NSCaseInsensitiveSearch];
            NSRange bundleIdRange = [app.bundleIdentifier.lowercaseString rangeOfString:searchText options:NSCaseInsensitiveSearch];
            if(nameRange.location != NSNotFound || bundleIdRange.location != NSNotFound) {
                [filteredApps addObject:app];
            }
        }
    }
}

-(void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self reloadSearch];
    [self.tableView reloadData];
}


- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.tableFooterView = [[UIView alloc] init];
    
    [self setTitle:Localized(@"Blacklist")];
    
    self->blacklistDisabled = [[AppDelegate getDefaultsForKey:@"blacklistDisabled"] boolValue];
    self->spinlockFixApplied = [[AppDelegate getDefaultsForKey:@"spinlockFixApplied"] boolValue];
    
    isFiltered = false;
    
    searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchBar.delegate = self;
    searchController.searchBar.placeholder = Localized(@"name or identifier");
    searchController.searchBar.barTintColor = [UIColor whiteColor];
    searchController.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    refreshControl.tintColor = [UIColor grayColor];
    [refreshControl addTarget:self action:@selector(manualRefresh) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;
    
    self->applications = [self updateData];
    self->appsArray = [self sortAppList:YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(autoRefresh)
                                          name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)startRefresh:(BOOL)resort {
    [self.tableView.refreshControl beginRefreshing];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSArray* newData = [self updateData];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->applications = newData;
            self->appsArray = [self sortAppList:resort];
            [self reloadSearch];
            [self.tableView reloadData];
            [self.tableView.refreshControl endRefreshing];
        });
    });
}

- (void)manualRefresh {
    [self startRefresh:YES];
}

- (void)autoRefresh {
    [self startRefresh:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSMutableDictionary *appconfig = [[AppDelegate getDefaultsForKey:@"appconfig"] mutableCopy] ?: [NSMutableDictionary new];
    BOOL changed = NO;
    for (AppInfo *app in applications) {
        NSInteger mode = RHShieldMode(app.bundleIdentifier);
        if (mode == 2) {
            for (NSString *identifier in RHIdentifiersForApp(app)) {
                if (![appconfig[identifier] boolValue]) { appconfig[identifier] = @YES; changed = YES; }
                NSDictionary *cp = [NSDictionary dictionaryWithContentsOfFile:RHChoicyPrefsPath()];
                NSDictionary *entry = cp[@"appSettings"][identifier];
                BOOL supportOnly = [entry[@"customTweakConfigurationEnabled"] boolValue] && [entry[@"allowedTweaks"] containsObject:@"RootHideSupport"];
                if (!supportOnly) RHSetChoicyModeForApp(identifier, 2);
            }
        } else {
            BOOL linked = [appconfig[app.bundleIdentifier] boolValue] || RHChoicyDisabledForApp(app.bundleIdentifier);
            if (linked != [appconfig[app.bundleIdentifier] boolValue]) { appconfig[app.bundleIdentifier] = @(linked); changed = YES; }
            if (linked != RHChoicyDisabledForApp(app.bundleIdentifier)) RHSetChoicyDisabledForApp(app.bundleIdentifier, linked);
        }
    }
    if (changed) [AppDelegate setDefaults:appconfig forKey:@"appconfig"];
    self->appsArray = [self sortAppList:YES];
    [self.tableView reloadData];
}

- (NSArray*)sortAppList:(BOOL)sortWithStatus {
    NSArray *result = nil;
    
    if(sortWithStatus)
    {
        NSMutableDictionary* appconfig = [AppDelegate getDefaultsForKey:@"appconfig"];
        
        result = [applications sortedArrayUsingComparator:^NSComparisonResult(AppInfo *app1, AppInfo *app2) {

            BOOL enabled1 = [[appconfig objectForKey:app1.bundleIdentifier] boolValue];
            BOOL enabled2 = [[appconfig objectForKey:app2.bundleIdentifier] boolValue];
            
            if((enabled1&&!enabled2) || (!enabled1&&enabled2)) {
                return [@(enabled2) compare:@(enabled1)];
            }
            
            if(app1.isHiddenApp || app2.isHiddenApp) {
                return (enabled1&&enabled2) ? [@(app2.isHiddenApp) compare:@(app1.isHiddenApp)] : [@(app1.isHiddenApp) compare:@(app2.isHiddenApp)];
            }
            
            return [app1.name localizedStandardCompare:app2.name];
        }];
    }
    else
    {
        NSMutableArray *newapps = [NSMutableArray array];
        [applications enumerateObjectsUsingBlock:^(AppInfo *newobj, NSUInteger idx, BOOL * _Nonnull stop) {
            __block BOOL hasBeenContained = NO;
            [self->appsArray enumerateObjectsUsingBlock:^(AppInfo *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if ([obj.bundleIdentifier isEqualToString:newobj.bundleIdentifier]) {
                    hasBeenContained = YES;
                    *stop = YES;
                }
            }];
            if (!hasBeenContained) {
                [newapps addObject:newobj];
            }
        }];
        
        NSMutableArray *tmpArray = [NSMutableArray array];
        [self->appsArray enumerateObjectsUsingBlock:^(AppInfo *obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [applications enumerateObjectsUsingBlock:^(AppInfo *newobj, NSUInteger idx, BOOL * _Nonnull stop) {
                if ([obj.bundleIdentifier isEqualToString:newobj.bundleIdentifier]) {
                    [tmpArray addObject:newobj];
                    *stop = YES;
                }
            }];
        }];

        [tmpArray addObjectsFromArray:newapps];
        result = tmpArray.copy;
    }
    
    return result;
}

- (NSArray*)updateData {
    NSMutableArray* applications = [NSMutableArray new];
    NSArray* allInstalledApplications = [LSApplicationWorkspace.defaultWorkspace allInstalledApplications];
    for(id proxy in allInstalledApplications)
    {
        AppInfo* app = [AppInfo appWithPrivateProxy:proxy];
        //if(!app.isHiddenApp && ([app.applicationType containsString:@"User"]))
        //some apps can be installed in trollstore but detect jailbreak
        if(!app.isHiddenApp
           && ![app.bundleIdentifier hasPrefix:@"com.apple."]
           && isDefaultInstallationPath(app.bundleURL.path))
        {
            [applications addObject:app];
        }
    }
    
    return applications;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return isFiltered? filteredApps.count : appsArray.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"Applist";
}

- (nullable UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}
- (nullable UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AppInfo *app = isFiltered ? filteredApps[indexPath.row] : appsArray[indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [self showAppMenuForApp:app sourceView:cell ?: tableView];
}

- (UIImage *)imageWithImage:(UIImage *)image scaledToSize:(CGSize)newSize {
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
    [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    
    AppInfo* app = isFiltered? filteredApps[indexPath.row] : appsArray[indexPath.row];
    
    UIImage *image = app.icon;
    cell.imageView.image = [self imageWithImage:image scaledToSize:CGSizeMake(40, 40)];
    
    NSInteger shieldMode = RHShieldMode(app.bundleIdentifier);
    cell.textLabel.text = app.name;
    if (shieldMode == 2) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", app.bundleIdentifier, Localized(@"Strict Shield")];
    else if (shieldMode == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", app.bundleIdentifier, Localized(@"Normal Shield")];
    else cell.detailTextLabel.text = app.bundleIdentifier;
    
    UISwitch *theSwitch = [[UISwitch alloc] init];
    
    NSMutableDictionary* appconfig = [AppDelegate getDefaultsForKey:@"appconfig"];
    BOOL linkedEnabled = [[appconfig objectForKey:app.bundleIdentifier] boolValue] || RHChoicyDisabledForApp(app.bundleIdentifier);
    [theSwitch setOn:linkedEnabled];
    [theSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    
    if(blacklistDisabled) {
        //theSwitch.enabled = NO;
        [theSwitch setOn:NO];
    }
    
    cell.accessoryView = theSwitch;
    
    return cell;
}

- (void)showAppMenuForApp:(AppInfo *)app sourceView:(UIView *)sourceView
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:app.name ?: @"" message:app.bundleIdentifier ?: @"" preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:Localized(@"Normal Shield") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ RHApplyShieldMode(app,1); [self.tableView reloadData]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:Localized(@"Strict Shield") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ RHApplyShieldMode(app,2); RHClearDetectionCache(app); [self.tableView reloadData]; [AppDelegate showMessage:Localized(@"Main app and all extensions are blacklisted, tweak injection is disabled, and detection cache was cleared.") title:Localized(@"Strict Shield")]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:Localized(@"Disable Shield") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){ RHApplyShieldMode(app,0); [self.tableView reloadData]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:Localized(@"Shield Diagnostics") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){
        NSArray *ids=RHIdentifiersForApp(app); NSMutableArray *lines=[NSMutableArray array]; NSDictionary *cfg=[AppDelegate getDefaultsForKey:@"appconfig"];
        for(NSString *identifier in ids) [lines addObject:[NSString stringWithFormat:@"%@\nRootHide: %@ · Choicy: %@",identifier,[cfg[identifier] boolValue]?@"ON":@"OFF",RHChoicyDisabledForApp(identifier)?@"ON":@"OFF"]];
        NSString *summary=[NSString stringWithFormat:Localized(@"Mode: %@\nExtensions: %lu\n\n%@"),RHShieldMode(app.bundleIdentifier)==2?Localized(@"Strict Shield"):(RHShieldMode(app.bundleIdentifier)==1?Localized(@"Normal Shield"):@"OFF"),(unsigned long)(ids.count-1),[lines componentsJoinedByString:@"\n\n"]]; [AppDelegate showMessage:summary title:Localized(@"Shield Diagnostics")];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:Localized(@"Clear App Data") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x){
        NSString *containerPath=app.containerURL.path;
        NSString *message=[NSString stringWithFormat:Localized(@"This will permanently delete the main data container for %@. Documents, preferences, caches and login state inside it will be removed. Shared App Group containers are not deleted."),app.name ?: app.bundleIdentifier];
        UIAlertController *confirm=[UIAlertController alertControllerWithTitle:Localized(@"Clear App Data") message:message preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:Localized(@"Delete Data") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *y){
            void killAllForBundle(const char*); killAllForBundle(app.bundleURL.path.fileSystemRepresentation);
            NSString *error=nil; if(geteuid()==0&&getegid()==0){ NSString *clearAppData(AppInfo*); error=clearAppData(app); } else { NSString *RootUserClearAppData(AppInfo*); error=RootUserClearAppData(app); }
            BOOL gone=containerPath.length && ![NSFileManager.defaultManager fileExistsAtPath:containerPath];
            if(error.length) [AppDelegate showMessage:error title:Localized(@"Error")];
            else if(gone) [AppDelegate showMessage:Localized(@"The main app data container was removed successfully. It will be recreated empty on next launch.") title:Localized(@"Data Cleared")];
            else [AppDelegate showMessage:Localized(@"The deletion command completed, but the original data container still exists. No success was reported.") title:Localized(@"Verification Failed")];
        }]]; [self presentViewController:confirm animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=sourceView; menu.popoverPresentationController.sourceRect=sourceView.bounds;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)switchChanged:(id)sender {
    // https://stackoverflow.com/questions/31063571/getting-indexpath-from-switch-on-uitableview
    UISwitch *switchInCell = (UISwitch *)sender;
    
    CGPoint pos = [switchInCell convertPoint:switchInCell.bounds.origin toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:pos];
    
    AppInfo* app = isFiltered? filteredApps[indexPath.row] : appsArray[indexPath.row];
    
    if(blacklistDisabled)
    {
        [switchInCell setOn:NO];
        
        NSString* msg = Localized(@"Blacklist is not supported in current environment.");
        if([NSFileManager.defaultManager fileExistsAtPath:jbroot(@"/.bootstrapped")]
           || [NSFileManager.defaultManager fileExistsAtPath:jbroot(@"/.thebootstrapped")])
        {
            msg = Localized(@"Apps are blacklisted by default in current environment, just disable tweaks for this app in the AppList of Bootstrap.");
        }
        
        [AppDelegate showMessage:msg title:@""];
        
        return;
    }
    
    
    if([NSFileManager.defaultManager fileExistsAtPath:jbroot(@"/.thebootstrapped")])
    {
        if([NSFileManager.defaultManager fileExistsAtPath:[app.bundleURL.path stringByAppendingString:@"/../.appbackup"]]
           || [NSFileManager.defaultManager fileExistsAtPath:[app.bundleURL.path stringByAppendingPathExtension:@"appbackup"]]
           || [NSFileManager.defaultManager fileExistsAtPath:[app.bundleURL.path stringByAppendingPathComponent:@".jbroot"]])
        {
            [AppDelegate showMessage:Localized(@"This app is tweaked by Bootstrap, please disable tweak for it in the AppList of Bootstrap first.") title:@""];
            [switchInCell setOn:NO];
            return;
        }
    }
    
#ifdef __arm64e__
    if (spinlockFixApplied && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15) {
        static BOOL Alerted = NO;
        if(!Alerted && switchInCell.on) {
            Alerted = YES;
            [AppDelegate showMessage:Localized(@"\nFor iOS15 A12+ devices:\n\nthe blacklisted app will have its app extension disabled, and may cause a spinlock panic when the app is running in the foreground/background.\n\nYou can first try disabling tweak injection for this app in Choicy, and only blacklist the app if it doesn't work.") title:Localized(@"Warning")];
        }
    }
#endif
    
    NSMutableDictionary* appconfig = [AppDelegate getDefaultsForKey:@"appconfig"];
    if(!appconfig) appconfig = [[NSMutableDictionary alloc] init];
    [appconfig setObject:@(switchInCell.on) forKey:app.bundleIdentifier];
    [AppDelegate setDefaults:appconfig forKey:@"appconfig"];
    NSMutableDictionary *modes = [[AppDelegate getDefaultsForKey:@"strictShieldModes"] mutableCopy] ?: [NSMutableDictionary new];
    if (switchInCell.on) modes[app.bundleIdentifier] = @1; else [modes removeObjectForKey:app.bundleIdentifier];
    [AppDelegate setDefaults:modes forKey:@"strictShieldModes"];
    RHSetChoicyDisabledForApp(app.bundleIdentifier, switchInCell.on);
    
    void killAllForBundle(const char* bundlePath);
    killAllForBundle(app.bundleURL.path.UTF8String);
    
}
@end
