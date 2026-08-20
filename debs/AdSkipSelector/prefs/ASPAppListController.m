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
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        id ws = c ? ((id(*)(id,SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace")) : nil;
        NSArray *all = ws ? ((id(*)(id,SEL))objc_msgSend)(ws, NSSelectorFromString(@"allApplications")) : nil;
        for (id proxy in [all isKindOfClass:NSArray.class] ? all : @[]) {
            NSString *bid = [proxy valueForKey:@"applicationIdentifier"];
            NSString *name = [proxy valueForKey:@"localizedName"];
            if (![bid isKindOfClass:NSString.class] || !bid.length || [bid hasPrefix:@"com.apple."]) continue;
            if (![name isKindOfClass:NSString.class] || !name.length) name = bid;
            ASPAppInfo *a = [ASPAppInfo new]; a.bundleID = bid; a.name = name; [out addObject:a];
        }
    } @catch (__unused NSException *e) {}
    return out;
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
    return [apps sortedArrayUsingComparator:^NSComparisonResult(ASPAppInfo *a, ASPAppInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

@interface ASPAppListController : PSListController
@end

@implementation ASPAppListController

- (NSString *)navigationTitle { return @"AdSkip 屏蔽广告"; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[NSMutableArray alloc] init];
        @try {
            NSArray<ASPAppInfo *> *apps = ASPAllApps();
            PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
            [group setProperty:apps.count ? @"选择需要启用广告屏蔽的应用" : @"没有可枚举的应用" forKey:PSFooterTextGroupKey];
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
    return _specifiers;
}

- (void)setSwitch:(NSNumber *)value forSpecifier:(PSSpecifier *)specifier {
    NSString *bid = specifier.identifier ?: [specifier propertyForKey:PSIDKey];
    if (!bid.length) return;
    NSMutableSet *enabled = [ASPEnabledBundleIDs() mutableCopy];
    value.boolValue ? [enabled addObject:bid] : [enabled removeObject:bid];
    ASPSaveEnabledBundleIDs(enabled);
}

- (NSNumber *)getSwitchForSpecifier:(PSSpecifier *)specifier {
    NSString *bid = specifier.identifier ?: [specifier propertyForKey:PSIDKey];
    return @(bid.length && [ASPEnabledBundleIDs() containsObject:bid]);
}

@end
