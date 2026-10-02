#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

@interface FRootListController : PSListController
@end

// 前置声明：诊断区方法会用到定义在后面的 alert/prefs
@interface FRootListController (CPUthermalDiagnosticsForward)
- (void)alert:(NSString *)title message:(NSString *)message;
- (NSMutableDictionary *)prefs;
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

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [controller addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (NSMutableDictionary *)prefs {
    NSMutableDictionary *d = CPUthermalReadMutablePrefs();
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

- (void)runThermalToolCommand:(const char *)command value:(BOOL)value hasValue:(BOOL)hasValue {
    NSString *toolPath = CPUthermalToolPath();
    if (!toolPath.length || !command) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        pid_t pid = 0;
        char valueBuffer[2] = { value ? '1' : '0', '\0' };
        char *argsWithValue[] = {(char *)"CPUthermalTool", (char *)command, valueBuffer, NULL};
        char *argsNoValue[] = {(char *)"CPUthermalTool", (char *)command, NULL};
        char **arguments = hasValue ? argsWithValue : argsNoValue;
        if (posix_spawn(&pid, toolPath.fileSystemRepresentation, NULL, NULL, arguments, NULL) == 0) waitpid(pid, NULL, 0);
    });
}

- (void)restartThermalMonitorImmediately {
    NSString *killall = CPUthermalExistingExecutablePath("/usr/bin/killall", @[
        S("/var/jb/usr/bin/killall"), S("/var/jb/bin/killall"), S("/usr/bin/killall"), S("/bin/killall")]);
    if (!killall.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        pid_t pid = 0;
        char *args[] = {(char *)"killall", (char *)"-q", (char *)"thermalmonitord", NULL};
        posix_spawn(&pid, killall.fileSystemRepresentation, NULL, NULL, args, NULL);
    });
}


// ============================================================================
// 控制中心模块尺寸：改写已安装 bundle 的 Info.plist（CCSModuleSize / ModuleSize）
//   控制中心按该 plist 决定模块占位（1×1 或 2×1）；目录在越狱根内、可写，
//   因此无需 hook 私有 API，改写后注销/重启用户空间即生效。
// ============================================================================
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return;

    NSMutableDictionary *prefs = [self prefs];

    prefs[key] = value;
    if ([key isEqualToString:S("sunlightLockedEnabled")]) {
        [prefs removeObjectForKey:S("sunlightAutomatic")];
        [prefs removeObjectForKey:S("sunlightOverride")];
    }
    CPUthermalWritePrefs(prefs);

    // 「通知不亮锁屏」开关切换后重新加载面板，联动显示/隐藏模式选择
    if ([key isEqualToString:S("lockScreenNoWake")]) {
        _specifiers = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; });
    }

    if ([key isEqualToString:S("force120HzEnable")]) {
        // 刷新率模块直接读取持久偏好，避免 notify state 重启清零。
        notify_post(kCPUthermalSettingsChangedNotifC);
    } else {
        notify_post(kCPUthermalSettingsChangedNotifC);
    }
}


- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return nil;
    
    id val = [self prefs][key];
    if (val) return val;
    if ([key isEqualToString:S("smartChargeStopLevel")]) return [NSNumber numberWithInt:80];
    if ([key isEqualToString:S("smartChargeUseSmartBatteryAPI")]) return [NSNumber numberWithBool:YES];

    // 其余功能开关默认关闭，仅用户主动开启后生效。
    return [NSNumber numberWithBool:NO];
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

- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:S("Root") target:self];
        _specifiers = loaded ? [self CPUthermalFilterDependentSpecifiers:loaded] : nil;
    }
    return _specifiers;
}

// 「通知不亮锁屏」关闭时隐藏其模式选择（低电/静音/始终不亮），与系统设置同款联动
- (NSMutableArray *)CPUthermalFilterDependentSpecifiers:(NSArray *)specifiers {
    if (![specifiers isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *result = [specifiers isKindOfClass:[NSMutableArray class]]
        ? (NSMutableArray *)specifiers : [specifiers mutableCopy];
    NSDictionary *prefs = [self prefs];
    BOOL noWake = [[prefs objectForKey:S("lockScreenNoWake")] boolValue];
    if (noWake) return result;
    for (PSSpecifier *spec in [result copy]) {
        NSString *key = [spec propertyForKey:S("key")];
        if ([key isEqualToString:S("lsBlockMode")]) [result removeObject:spec];
    }
    return result;
}

@end
