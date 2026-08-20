#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../SharedPrefs.h"

#pragma mark - 数据模型

@interface ASPAppInfo : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, strong) UIImage *icon;
@end
@implementation ASPAppInfo @end

#pragma mark - 枚举应用（多重兜底，保证不空不崩）

// 手段1：LSApplicationWorkspace（iOS 私有，多数系统进程可用）
static NSArray<ASPAppInfo *> *ASPAppsViaLS(void) {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (!ws) return nil;
    id workspace = ((id(*)(id, SEL))objc_msgSend)(ws, sel_registerName("defaultWorkspace"));
    if (!workspace) return nil;
    NSArray *all = [workspace valueForKey:@"allApplications"];
    if (![all isKindOfClass:NSArray.class]) return nil;

    NSMutableArray *apps = [NSMutableArray array];
    for (id proxy in all) {
        if (![proxy isKindOfClass:NSObject.class]) continue;
        NSString *bid = nil, *name = nil, *type = nil;
        @try {
            id b = [proxy valueForKey:@"applicationIdentifier"];
            if ([b isKindOfClass:NSString.class]) bid = b;
            id n = [proxy valueForKey:@"localizedName"];
            if ([n isKindOfClass:NSString.class]) name = n;
            id t = [proxy valueForKey:@"applicationType"];
            if ([t isKindOfClass:NSString.class]) type = t;
        } @catch (__unused NSException *e) { continue; }
        if (!bid.length || !name.length) continue;
        if ([type isKindOfClass:NSString.class] && ![type isEqualToString:@"User"]) continue;
        ASPAppInfo *info = [ASPAppInfo new];
        info.bundleID = bid;
        info.name = name;
        [apps addObject:info];
    }
    return apps.count ? apps : nil;
}

// 手段2：扫文件系统 /var/mobile/Containers/Bundle/Application/*/*.app（始终可用）
static NSArray<ASPAppInfo *> *ASPAppsViaFileSystem(void) {
    NSMutableArray *apps = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = @"/var/mobile/Containers/Bundle/Application";
    NSArray *uids = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *uid in uids ?: @[]) {
        NSString *dir = [root stringByAppendingPathComponent:uid];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *bundle in items ?: @[]) {
            if (![bundle hasSuffix:@".app"]) continue;
            NSString *infoPath = [[dir stringByAppendingPathComponent:bundle] stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if (!info) continue;
            NSString *bid = info[@"CFBundleIdentifier"];
            if (!bid.length) continue;
            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
            if (!name.length) name = bid;
            ASPAppInfo *a = [ASPAppInfo new];
            a.bundleID = bid;
            a.name = name;
            [apps addObject:a];
        }
    }
    return apps.count ? apps : nil;
}

static NSArray<ASPAppInfo *> *ASPAllUserApplications(void) {
    NSArray *apps = ASPAppsViaLS();
    if (!apps) apps = ASPAppsViaFileSystem();
    if (!apps) return @[];
    return [apps sortedArrayUsingComparator:^NSComparisonResult(ASPAppInfo *a, ASPAppInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

#pragma mark - 弱链接设置框架（不依赖编译期 Preferences.framework）

static id ASPNewSpecifier(NSString *name, id target, SEL set, SEL get, NSInteger cellType) {
    Class specClass = NSClassFromString(@"PSSpecifier");
    if (!specClass) return nil;
    return ((id(*)(id, SEL, id, id, SEL, SEL, id, NSInteger, id))objc_msgSend)(
        specClass,
        sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        name, target, set, get, nil, cellType, nil);
}

static id ASPEmptyGroup(void) {
    Class specClass = NSClassFromString(@"PSSpecifier");
    if (!specClass) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(specClass, sel_registerName("emptyGroupSpecifier"));
}

static void ASPProp(id obj, id prop, NSString *key) {
    if (!obj) return;
    SEL s = sel_registerName("setProperty:forKey:");
    if ([obj respondsToSelector:s]) {
        typedef void (*fn)(id, SEL, id, id);
        ((fn)objc_msgSend)(obj, s, prop, key);
    }
}

#pragma mark - PSListController 方法实现（C IMP，ABI 严格匹配）

// - (NSMutableArray *)specifiers
static NSMutableArray *ASP_specifiers(id self, SEL _cmd) {
    @try {
        NSMutableArray *result = [NSMutableArray array];
        NSMutableSet *enabled = [ASPEnabledBundleIDs() mutableCopy];

        NSArray *apps = ASPAllUserApplications();
        BOOL addedGroup = NO;
        for (ASPAppInfo *app in apps) {
            if (!addedGroup) {
                id g = ASPEmptyGroup();
                if (g) { [result addObject:g]; ASPProp(g, @"已安装应用（开关逐个生效）", @"footerText"); }
                addedGroup = YES;
            }
            id spec = ASPNewSpecifier(app.name, self,
                                      sel_registerName("setSwitch:forSpecifier:"),
                                      sel_registerName("getSwitchForSpecifier:"),
                                      6 /* PSSwitchCell */);
            if (!spec) continue;
            // 记录 bundle id（规范做法：identifier 属性 + 缓存 key）
            SEL idSEL = sel_registerName("setIdentifier:");
            if ([spec respondsToSelector:idSEL]) {
                typedef void (*fn)(id, SEL, id);
                ((fn)objc_msgSend)(spec, idSEL, app.bundleID);
            }
            ASPProp(spec, app.bundleID, @"id");
            ASPProp(spec, @([enabled containsObject:app.bundleID]), @"default");
            [result addObject:spec];
        }

        if (!apps.count) {
            id g = ASPEmptyGroup();
            if (g) {
                ASPProp(g, @"没有可枚举的应用", @"footerText");
                [result addObject:g];
            }
        }
        return result;
    } @catch (__unused NSException *e) {
        // 任何异常都返回空组，避免设置进程崩溃
        NSMutableArray *r = [NSMutableArray array];
        id g = ASPEmptyGroup();
        if (g) { ASPProp(g, @"加载失败", @"footerText"); [r addObject:g]; }
        return r;
    }
}

// - (void)setSwitch:forSpecifier:
static void ASP_setSwitch(id self, SEL _cmd, NSNumber *value, id specifier) {
    @try {
        NSString *bid = [specifier valueForKey:@"identifier"];
        if (![bid isKindOfClass:NSString.class]) bid = nil;
        if (!bid.length) return;
        NSMutableSet *enabled = [ASPEnabledBundleIDs() mutableCopy];
        if ([value boolValue]) [enabled addObject:bid];
        else [enabled removeObject:bid];
        ASPSaveEnabledBundleIDs(enabled);
    } @catch (__unused NSException *e) {}
}

// - (NSNumber *)getSwitchForSpecifier:
static id ASP_getSwitch(id self, SEL _cmd, id specifier) {
    @try {
        NSString *bid = [specifier valueForKey:@"identifier"];
        if (![bid isKindOfClass:NSString.class]) return @NO;
        return @(bid.length && [ASPEnabledBundleIDs() containsObject:bid]);
    } @catch (__unused NSException *e) {
        return @NO;
    }
}

// - (NSString *)navigationTitle
static id ASP_navigationTitle(id self, SEL _cmd) {
    return @"AdSkip 屏蔽广告";
}

#pragma mark - 动态子类注册

__attribute__((constructor))
static void ASPRegisterListController(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class ps = NSClassFromString(@"PSListController");
        if (!ps) return;
        if (objc_getClass("ASPAppListController")) return;

        Class cls = objc_allocateClassPair(ps, "ASPAppListController", 0);
        if (!cls) return;

        class_addMethod(cls, sel_registerName("specifiers"), (IMP)ASP_specifiers, "@@:");
        class_addMethod(cls, sel_registerName("setSwitch:forSpecifier:"), (IMP)ASP_setSwitch, "v@:@@");
        class_addMethod(cls, sel_registerName("getSwitchForSpecifier:"), (IMP)ASP_getSwitch, "@@:@");
        class_addMethod(cls, sel_registerName("navigationTitle"), (IMP)ASP_navigationTitle, "@@:");

        objc_registerClassPair(cls);
    });
}
