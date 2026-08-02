#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (NSString *)prefPath {
    return CPUthermalCurrentPrefPath();
}

- (NSString *)legacyPrefPath {
    NSArray<NSString *> *paths = CPUthermalLegacyPrefPaths();
    return paths.count > 0 ? paths[0] : nil;
}

- (void)ensurePrefsDirectory {
    NSString *directory = [[self prefPath] stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
}

- (void)migrateLegacyPrefsIfNeeded {
    CPUthermalReadPrefs();
}

- (NSMutableDictionary *)prefs {
    NSMutableDictionary *d = CPUthermalReadMutablePrefs();
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

- (void)savePrefs:(NSMutableDictionary *)prefs {
    CPUthermalWritePrefs(prefs);
    notify_post(kCPUthermalSettingsChangedNotifC);
}

- (void)restartThermalmonitord {
    CPUthermalRestartThermalmonitordSoon();
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return;
    
    NSMutableDictionary *prefs = [self prefs];
    
    // 功率模式统一规范为字符串，防止框架传入 NSNumber 索引
    if ([key isEqualToString:S("powerMode")]) {
        if ([value isKindOfClass:[NSNumber class]]) {
            value = ([value intValue] == 0) ? S("lowPower") : S("fullPower");
        } else if (![value isKindOfClass:[NSString class]]) {
            value = S("fullPower");
        }
    }
    
    prefs[key] = value;
    [self savePrefs:prefs];

    // HIP(口袋过热)开关变更后重启 thermalmonitord
    if ([key isEqualToString:S("hipEnabled")]) {
        [self restartThermalmonitord];
    }
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return nil;
    
    // 功率模式为字符串值，默认满血(解除温控)
    if ([key isEqualToString:S("powerMode")]) {
        id mode = [self prefs][key];
        if (mode && [mode isKindOfClass:[NSString class]]) return mode;
        return S("fullPower");
    }
    
    id val = [self prefs][key];
    if (val) return val;
    
    // 特定防护功能默认开启（开箱即用免配置）
    if ([key isEqualToString:S("thermalBlockNotifPopup")] ||
        [key isEqualToString:S("thermalPreventDimmingEnabled")]) {
        return [NSNumber numberWithBool:YES];
    }
    return [NSNumber numberWithBool:NO]; // 全部默认关闭
}

#pragma mark - 工具方法

- (void)openURLString:(NSString *)urlString fallback:(NSString *)fallbackURL failureMessage:(NSString *)failureMessage {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;

    [[UIApplication sharedApplication] openURL:url
                                       options:[NSDictionary dictionary]
                             completionHandler:^(BOOL success) {
        if (success) return;
        if (fallbackURL) {
            NSURL *fallback = [NSURL URLWithString:fallbackURL];
            if (fallback) {
                [[UIApplication sharedApplication] openURL:fallback options:[NSDictionary dictionary] completionHandler:nil];
                return;
            }
        }
        if (failureMessage) {
            [self showSimpleAlertWithTitle:S("提示") message:failureMessage];
        }
    }];
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 重启用户空间

- (void)usreboot {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:S("重启用户空间")
        message:S("重启 SpringBoard 和所有用户态进程？")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S("取消")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:S("确定重启")
                                              style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        pid_t pid = 0;
        NSString *toolPath = CPUthermalToolPath();
        if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
            char *args[] = {"CPUthermalTool", "userspace-reboot", NULL};
            if (posix_spawn(&pid, [toolPath fileSystemRepresentation], NULL, NULL, args, NULL) == 0) {
                waitpid(pid, NULL, 0);
                return;
            }
        }

        NSString *launchctlPath = CPUthermalLaunchctlPath();
        if (launchctlPath.length > 0) {
            char *args[] = {"launchctl", "reboot", "userspace", NULL};
            posix_spawn(&pid, [launchctlPath fileSystemRepresentation], NULL, NULL, args, NULL);
            waitpid(pid, NULL, 0);
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 开源代码

- (void)openSourceCode {
    [self openURLString:S("https://github.com/be-huge/insulation") fallback:nil failureMessage:S("无法打开 GitHub，请手动访问 https://github.com/be-huge/insulation")];
}

#pragma mark - Specifier 加载

- (NSArray *)specifiers {
    if (!_specifiers) {
        // 直接从 Root.plist 加载配置结构，Preferences 框架会自动正确解析 PSSegmentCell
        _specifiers = [self loadSpecifiersFromPlistName:S("Root") target:self];
    }
    return _specifiers;
}

@end
