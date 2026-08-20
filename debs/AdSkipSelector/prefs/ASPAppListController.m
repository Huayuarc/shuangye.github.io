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

// 通过 LSApplicationWorkspace 枚举用户安装的应用
static NSArray<ASPAppInfo *> *ASPAllUserApplications(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return @[];
    id workspace = ((id(*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    if (!workspace) return @[];
    NSArray *proxies = ((id(*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allApplications"));
    if (!proxies) return @[];

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

        ASPAppInfo *info = [ASPAppInfo new];
        info.bundleID = bid;
        info.name = name;
        SEL iconSEL = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([UIApplication.sharedApplication respondsToSelector:iconSEL])
            info.icon = ((id(*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(UIApplication.sharedApplication, iconSEL, bid, 2, UIScreen.mainScreen.scale);
        [result addObject:info];
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(ASPAppInfo *a, ASPAppInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

#pragma mark - 弱链接设置框架（不依赖编译期 Preferences.framework）

// PSSpecifier 的类方法：+preferenceSpecifierNamed:target:set:get:detail:cell:edit:
static id ASPNewSpecifier(NSString *name, id target, SEL set, SEL get, NSInteger cellType) {
    Class specClass = NSClassFromString(@"PSSpecifier");
    if (!specClass) return nil;
    return ((id(*)(id, SEL, id, id, SEL, SEL, id, NSInteger, id))objc_msgSend)(
        specClass,
        sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        name, target, set ?: (SEL)NULL, get ?: (SEL)NULL, nil, cellType, nil);
}

static void ASPSetProperty(id obj, id prop, NSString *key) {
    SEL s = sel_registerName("setProperty:forKey:");
    if (obj && [obj respondsToSelector:s]) {
        typedef void (*fn)(id, SEL, id, id);
        ((fn)objc_msgSend)(obj, s, prop, key);
    }
}

static void ASPSetIdentifier(id obj, NSString *identifier) {
    SEL s = sel_registerName("setIdentifier:");
    if (obj && [obj respondsToSelector:s]) {
        typedef void (*fn)(id, SEL, id);
        ((fn)objc_msgSend)(obj, s, identifier);
    }
}

#pragma mark - 运行时动态实现（PSListController 的 .specifiers / setter / getter）

// - (NSMutableArray *)specifiers
static NSMutableArray *ASP_specifiers(id self, SEL _cmd) {
    NSMutableSet *enabled = [ASPEnabledBundleIDs() mutableCopy];
    NSArray *apps = ASPAllUserApplications();
    NSMutableArray *result = [NSMutableArray array];

    NSString *term = nil;
    @try {
        // 不含搜索栏时恒为 nil；若宿主类恰好提供 searchTerm 属性则顺带支持
        id v = [self valueForKey:@"searchTerm"];
        term = v ? [v description] : nil;
    } @catch (__unused NSException *e) { term = nil; }
    if (term.length) term = [term stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    BOOL first = YES;
    for (ASPAppInfo *app in apps) {
        if (term.length) {
            if (![app.name localizedCaseInsensitiveContainsString:term] &&
                ![app.bundleID localizedCaseInsensitiveContainsString:term]) continue;
        }

        // 首个匹配项前插入组头
        if (first && result.count == 0) {
            Class specClass = NSClassFromString(@"PSSpecifier");
            id group = ((id(*)(id, SEL))objc_msgSend)(specClass, sel_registerName("emptyGroupSpecifier"));
            if (group) [result addObject:group];
            if (term.length) {
                ASPSetProperty(group, @"搜索结果", @"footerText");
            }
            first = NO;
        }

        id spec = ASPNewSpecifier(app.name, self,
                                  sel_registerName("setSwitch:forSpecifier:"),
                                  sel_registerName("getSwitchForSpecifier:"),
                                  6 /* PSCellTypeSwitch */);
        if (!spec) continue;
        ASPSetIdentifier(spec, app.bundleID);
        ASPSetProperty(spec, app.bundleID, @"id");
        ASPSetProperty(spec, @([enabled containsObject:app.bundleID]), @"default");
        if (app.icon) ASPSetProperty(spec, app.icon, @"iconImage");
        [result addObject:spec];
    }

    if (!result.count) {
        Class specClass = NSClassFromString(@"PSSpecifier");
        id group = ((id(*)(id, SEL))objc_msgSend)(specClass, sel_registerName("emptyGroupSpecifier"));
        if (group) {
            ASPSetProperty(group, @"没有匹配的应用，或本机未安装应用", @"footerText");
            [result addObject:group];
        }
    }
    return result;
}

// - (void)setSwitch:forSpecifier:
static void ASP_setSwitch(id self, SEL _cmd, NSNumber *value, id specifier) {
    NSString *bid = nil;
    @try { bid = [specifier valueForKey:@"id"]; } @catch (__unused NSException *e) {}
    if (!bid.length) @try { bid = [specifier valueForKey:@"identifier"]; } @catch (__unused NSException *e) {}
    if (!bid.length) return;
    NSMutableSet *enabled = [ASPEnabledBundleIDs() mutableCopy];
    if ([value boolValue]) [enabled addObject:bid];
    else [enabled removeObject:bid];
    ASPSaveEnabledBundleIDs(enabled);
}

// - (NSNumber *)getSwitchForSpecifier:
static id ASP_getSwitch(id self, SEL _cmd, id specifier) {
    NSString *bid = nil;
    @try { bid = [specifier valueForKey:@"id"]; } @catch (__unused NSException *e) {}
    if (!bid.length) @try { bid = [specifier valueForKey:@"identifier"]; } @catch (__unused NSException *e) {}
    return @(bid.length && [ASPEnabledBundleIDs() containsObject:bid]);
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
        if (objc_getClass("ASPAppListController")) return; // 已注册

        Class cls = objc_allocateClassPair(ps, "ASPAppListController", 0);
        if (!cls) return;

        // 额外成员变量：用于搜索状态（略），PSListController 自身持有 _specifiers/cell

        class_addMethod(cls, sel_registerName("specifiers"),
                        (IMP)ASP_specifiers, "@@:");

        class_addMethod(cls, sel_registerName("setSwitch:forSpecifier:"),
                        (IMP)ASP_setSwitch, "v@:@@");

        class_addMethod(cls, sel_registerName("getSwitchForSpecifier:"),
                        (IMP)ASP_getSwitch, "@@:@");

        class_addMethod(cls, sel_registerName("navigationTitle"),
                        (IMP)ASP_navigationTitle, "@@:");

        objc_registerClassPair(cls);
    });
}
