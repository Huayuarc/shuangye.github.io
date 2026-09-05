#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <notify.h>
#import <unistd.h>
#import <FaceDownLockPaths.h>

extern char **environ;

@interface FDLRootListController : PSListController
@end

@implementation FDLRootListController

- (NSMutableDictionary *)prefs {
    return FDLReadMutablePrefs() ?: [NSMutableDictionary dictionary];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:FDL_S("设备朝下自动锁屏")];
    [header setProperty:FDL_S("开启后，SpringBoard 检测到设备屏幕朝下或进入口袋态时模拟按下锁屏键。仅注入 SpringBoard；1.5 秒内不会重复触发。") forKey:FDL_S("footerText")];
    [items addObject:header];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:FDL_S("启用设备朝下自动锁屏")
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSwitchCell edit:nil];
    [enabled setProperty:FDL_S("enabled") forKey:FDL_S("key")];
    [items addObject:enabled];

    [items addObject:[PSSpecifier groupSpecifierWithName:FDL_S("操作")]];
    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:FDL_S("注销桌面")
        target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    respring->action = @selector(onRespring);
    [items addObject:respring];

    PSSpecifier *footer = [PSSpecifier emptyGroupSpecifier];
    [footer setProperty:FDL_S("独立提取自 CPUthermal 1.6.2-44 的 FaceDownLock 功能。") forKey:FDL_S("footerText")];
    [items addObject:footer];
    _specifiers = items;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:FDL_S("key")];
    id value = [self prefs][key];
    return value ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:FDL_S("key")];
    if (!key) return;
    NSMutableDictionary *prefs = [self prefs];
    prefs[key] = @([value boolValue]);
    FDLWritePrefs(prefs);
    notify_post(kFDLSettingsChangedNotifC);
}

- (NSString *)jailbreakRoot {
    NSString *executable = [NSBundle bundleForClass:self.class].executablePath;
    NSRange marker = [executable rangeOfString:FDL_S("/Library/PreferenceBundles/")];
    return marker.location == NSNotFound ? FDL_S("") : [executable substringToIndex:marker.location];
}

- (void)onRespring {
    NSString *root = [self jailbreakRoot];
    NSArray<NSString *> *candidates = @[
        [root stringByAppendingPathComponent:FDL_S("usr/bin/sbreload")],
        [root stringByAppendingPathComponent:FDL_S("usr/bin/killall")],
        FDL_S("/usr/bin/sbreload"), FDL_S("/usr/bin/killall")
    ];
    for (NSString *path in candidates) {
        if (access(path.fileSystemRepresentation, X_OK) != 0) continue;
        pid_t pid = 0;
        BOOL killall = [path.lastPathComponent isEqualToString:FDL_S("killall")];
        char *const sbreloadArgs[] = {(char *)path.fileSystemRepresentation, NULL};
        char *const killallArgs[] = {(char *)path.fileSystemRepresentation, "-9", "SpringBoard", NULL};
        posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, killall ? killallArgs : sbreloadArgs, environ);
        return;
    }
}

@end
