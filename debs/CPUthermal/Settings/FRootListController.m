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

    // 三种充电策略会写同一电池状态边界，面板侧强制互斥，避免定时器互相覆盖。
    if ([value boolValue] && [key isEqualToString:S("bypassChargeEnabled")]) {
        prefs[S("smartChargeEnabled")] = @NO;
        prefs[S("forceFastChargeIgnoreHeat")] = @NO;
    } else if ([value boolValue] &&
               ([key isEqualToString:S("smartChargeEnabled")] ||
                [key isEqualToString:S("forceFastChargeIgnoreHeat")])) {
        prefs[S("bypassChargeEnabled")] = @NO;
    }
    CPUthermalWritePrefs(prefs);
    if ([key isEqualToString:S("simulateMaximumCapacity")]) {
        CPUthermalPostMaximumCapacityState([value boolValue]);
    }
    if ([key isEqualToString:S("force120Hz")]) {
        CPUthermalPostRefreshRateState([prefs[S("force120Hz")] boolValue]);
    }

    // 功率模式只发专用通知，避免 settingsChanged + powerModeChanged 重复应用。
    if ([key isEqualToString:S("powerMode")]) {
        CPUthermalPostPowerMode(value);
    } else {
        notify_post(kCPUthermalSettingsChangedNotifC);
    }

    // 硬件写边界（MitigationHook.dylib）实时状态：低功耗位 + 拦截暗屏 + 强制满血快充。
    // 在任何相关开关或功率模式变化时同步发布，供热路径零磁盘开销读取。
    if ([key isEqualToString:S("powerMode")] ||
        [key isEqualToString:S("thermalPreventDimmingEnabled")] ||
        [key isEqualToString:S("forceFastChargeIgnoreHeat")] ||
        [key isEqualToString:S("bypassBatteryChargeTemperature")]) {
        NSString *mode = [prefs[S("powerMode")] isKindOfClass:[NSString class]] ? prefs[S("powerMode")] : S("fullPower");
        CPUthermalPostMitigationState([mode isEqualToString:S("lowPower")],
                                      [prefs[S("thermalPreventDimmingEnabled")] boolValue],
                                      [prefs[S("forceFastChargeIgnoreHeat")] boolValue]);
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
    if ([key isEqualToString:S("smartChargeStopLevel")]) return [NSNumber numberWithInt:80];
    if ([key isEqualToString:S("bypassChargeStopLevel")]) return [NSNumber numberWithInt:95];

    // 所有其他功能开关默认关闭，仅用户主动开启后生效。
    return [NSNumber numberWithBool:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSDictionary *prefs = [self prefs];
    CPUthermalPostRefreshRateState([prefs[S("force120Hz")] boolValue]);
    NSString *mode = [prefs[S("powerMode")] isKindOfClass:[NSString class]] ? prefs[S("powerMode")] : S("fullPower");
    CPUthermalPostMitigationState([mode isEqualToString:S("lowPower")],
                                  [prefs[S("thermalPreventDimmingEnabled")] boolValue],
                                  [prefs[S("forceFastChargeIgnoreHeat")] boolValue]);
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
        message:S("安装或升级时只会自动重启 thermalmonitord；此操作将重启 SpringBoard 和其他用户态服务。")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S("取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:S("确定重启")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        pid_t pid = 0;
        NSString *toolPath = CPUthermalToolPath();
        if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
            char *args[] = {(char *)"CPUthermalTool", (char *)"userspace-reboot", NULL};
            if (posix_spawn(&pid, [toolPath fileSystemRepresentation], NULL, NULL, args, NULL) == 0) {
                waitpid(pid, NULL, 0);
                return;
            }
        }

        NSString *launchctlPath = CPUthermalLaunchctlPath();
        if (launchctlPath.length == 0) return;
        char *args[] = {(char *)"launchctl", (char *)"reboot", (char *)"userspace", NULL};
        if (posix_spawn(&pid, [launchctlPath fileSystemRepresentation], NULL, NULL, args, NULL) == 0) {
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
