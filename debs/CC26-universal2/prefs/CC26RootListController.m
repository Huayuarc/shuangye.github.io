#import "CC26RootListController.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

extern char **environ;

static NSString *const CC26Domain = @"com.cureux.cc26";
static CFStringRef const CC26Changed = CFSTR("com.cureux.cc26.prefschanged");

static id CC26Read(NSString *key, id fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)CC26Domain);
    return CFBridgingRelease(value) ?: fallback;
}

static void CC26Write(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)CC26Domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC26Domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CC26Changed, NULL, NULL, YES);
}

@implementation CC26RootListController

- (PSSpecifier *)preferenceNamed:(NSString *)name key:(NSString *)key defaultValue:(id)defaultValue {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:Nil cell:PSSwitchCell edit:Nil];
    [specifier setProperty:key forKey:PSKeyNameKey];
    [specifier setProperty:CC26Domain forKey:PSDefaultsKey];
    [specifier setProperty:defaultValue forKey:PSDefaultValueKey];
    [specifier setProperty:(__bridge NSString *)CC26Changed forKey:PSValueChangedNotificationKey];
    return specifier;
}

- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
    specifier.buttonAction = action;
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"CC26 universal2"];
    [header setProperty:@"以 0.6.0.0-universal1 修改版为核心；Loader 仅在 iOS 15/16 且关键私有类与 selector 实际存在时装载，iOS 17+ 默认隔离。" forKey:PSFooterTextGroupKey];
    [items addObject:header];
    [items addObject:[self preferenceNamed:@"启用 CC26" key:@"Enabled" defaultValue:@YES]];

    PSSpecifier *strategy = [PSSpecifier groupSpecifierWithName:@"跨版本稳定策略"];
    [strategy setProperty:@"System Aperture 安全补丁、原生媒体控制中心与音量 HUD 兼容均已固定写入上传版核心，不提供无效的伪开关。修改启用状态后请注销桌面。" forKey:PSFooterTextGroupKey];
    [items addObject:strategy];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"操作"]];
    [items addObject:[self buttonNamed:@"注销桌面" action:@selector(onRespring)]];
    [items addObject:[self buttonNamed:@"恢复推荐设置" action:@selector(onResetSettings)]];

    PSSpecifier *footer = [PSSpecifier emptyGroupSpecifier];
    [footer setProperty:@"支持范围：iOS 15.0–16.7.x；iOS 17+ 不加载核心。核心补丁由精确 SHA-256 基线复现。" forKey:PSFooterTextGroupKey];
    [items addObject:footer];
    _specifiers = items;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return CC26Read([specifier propertyForKey:PSKeyNameKey], [specifier propertyForKey:PSDefaultValueKey]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    CC26Write([specifier propertyForKey:PSKeyNameKey], value);
}

- (void)onResetSettings {
    for (NSString *key in @[@"Enabled"])
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)CC26Domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC26Domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CC26Changed, NULL, NULL, YES);
    [self reloadSpecifiers];
}

- (NSString *)jailbreakRoot {
    NSString *executable = [NSBundle bundleForClass:self.class].executablePath;
    NSRange marker = [executable rangeOfString:@"/Library/PreferenceBundles/"];
    return marker.location == NSNotFound ? @"" : [executable substringToIndex:marker.location];
}

- (void)onRespring {
    NSString *root = [self jailbreakRoot];
    NSArray<NSString *> *candidates = @[
        [root stringByAppendingPathComponent:@"usr/bin/sbreload"],
        [root stringByAppendingPathComponent:@"usr/bin/killall"],
        @"/usr/bin/sbreload", @"/usr/bin/killall"
    ];
    for (NSString *path in candidates) {
        if (access(path.fileSystemRepresentation, X_OK) != 0) continue;
        pid_t pid = 0;
        BOOL killall = [path.lastPathComponent isEqualToString:@"killall"];
        char *const sbreloadArgs[] = {(char *)path.fileSystemRepresentation, NULL};
        char *const killallArgs[] = {(char *)path.fileSystemRepresentation, "-9", "SpringBoard", NULL};
        posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, killall ? killallArgs : sbreloadArgs, environ);
        return;
    }
}

@end
