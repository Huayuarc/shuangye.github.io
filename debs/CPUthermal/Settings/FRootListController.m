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

    if ([key isEqualToString:S("force120HzEnable")]) {
        // 刷新率模块直接读取持久偏好，避免 notify state 重启清零。
        notify_post(kCPUthermalSettingsChangedNotifC);
    } else {
        notify_post(kCPUthermalSettingsChangedNotifC);
    }
}


- (NSString *)currentRunModeTitle {
    NSString *mode = [self prefs][S("powerMode")] ?: [self prefs][S("thermalRunMode")];
    if ([mode isEqualToString:S("lowPower")]) return S("低功耗");
    if ([mode isEqualToString:S("extremeFull")]) return S("极限满频");
    return S("稳定高性能");
}
- (void)showRunModeSheet {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:S("温控运行方式") message:S("切换立即生效，无延迟") preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = [self currentRunModeTitle];
    for (NSString *title in @[S("低功耗"), S("稳定高性能"), S("极限满频")]) {
        NSString *label = [title isEqualToString:current] ? [S("✓ ") stringByAppendingString:title] : title;
        [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){
            NSString *value = [title isEqualToString:S("低功耗")] ? S(kCPUthermalLowPowerModeC) : ([title isEqualToString:S("极限满频")] ? S(kCPUthermalExtremeModeC) : S(kCPUthermalFullPowerModeC));
            NSMutableDictionary *prefs = [self prefs];
            prefs[S("powerMode")] = value;
            CPUthermalWritePrefs(prefs);
            CPUthermalPostPowerMode(value);
                }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// ============================================================================
// 发热与降频诊断：实时状态 + 运行日志（便于定位降频/发热原因）
// ============================================================================
- (NSString *)diagnosticLogPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[S("/usr/local/share/CPUthermal"), S("/var/jb/usr/local/share/CPUthermal"),
                            S("/var/mobile/Library/CPUthermal"), S("/var/tmp"), S("/tmp")]) {
        NSString *path = [dir stringByAppendingPathComponent:S("cputhermal-throttle.log")];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (int)thermalPressureLevel {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) {
        registered = YES;
        if (notify_register_check("com.apple.system.thermalpressurelevel", &token) != NOTIFY_STATUS_OK) return -1;
    }
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return -1;
    return (int)state;
}

- (NSString *)diagnosticsText {
    NSDictionary *prefs = [self prefs];
    NSString *mode = prefs[S("powerMode")] ?: prefs[S("thermalRunMode")] ?: S("fullPower");
    NSString *modeTitle = [mode isEqualToString:S("lowPower")] ? S("低功耗")
                        : ([mode isEqualToString:S("extremeFull")] ? S("极限满频") : S("稳定高性能"));
    BOOL protection = NO; int runMode = 1;
    CPUthermalReadThermalEngineState(&protection, &runMode);
    int tempTenths = -1, milliAmps = 0, soc = -1;
    io_registry_entry_t entry = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (entry != IO_OBJECT_NULL) {
        CFTypeRef t = IORegistryEntryCreateCFProperty(entry, CFSTR("Temperature"), kCFAllocatorDefault, 0);
        CFTypeRef a = IORegistryEntryCreateCFProperty(entry, CFSTR("InstantAmperage"), kCFAllocatorDefault, 0);
        CFTypeRef c = IORegistryEntryCreateCFProperty(entry, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
        if (t) { int raw = [(__bridge NSNumber *)t intValue]; tempTenths = raw > 2000 ? raw / 10 : raw; }
        if (a) { int v = [(__bridge NSNumber *)a intValue]; if (v > 100000) v -= 0x100000000LL; milliAmps = v; }
        if (c) soc = [(__bridge NSNumber *)c intValue];
        if (t) CFRelease(t);
        if (a) CFRelease(a);
        if (c) CFRelease(c);
        IOObjectRelease(entry);
    }
    NSString *source = milliAmps > 1200 ? S("充电电流") : (milliAmps < 0 ? S("放电/CPU 负载") : S("环境积热"));
    NSString *guard = [[prefs objectForKey:S("chargeCurrentLimitEnabled")] ?: @YES boolValue]
        ? S("开") : S("关");
    (void)protection;
    NSInteger stop = [[prefs objectForKey:S("chargeCurrentLimitMA")] ?: @1500 integerValue];
    return [NSString stringWithFormat:
        S("运行方式：%@\n热压等级：%d\n电池 %d.%d℃ / %d%%  电流 %+dmA\n当前主热源：%@\n充电限流：%@（上限 %ldmA，≥38℃降1200、≥42℃降800）"),
        modeTitle, [self thermalPressureLevel],
        tempTenths / 10, tempTenths % 10, soc, milliAmps, source, guard, (long)stop];
}

- (void)updateDiagnostics {
    NSString *text = [self diagnosticsText];
    for (PSSpecifier *sp in self.specifiers) {
        if ([sp.name isEqualToString:S("发热与降频诊断")]) [sp setProperty:text forKey:S("footerText")];
    }
}

- (NSString *)recentLogTail:(NSUInteger)lineCount {
    NSString *path = [self diagnosticLogPath];
    if (!path.length) return S("（暂无日志）");
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: S("");
    NSArray<NSString *> *lines = [content componentsSeparatedByString:S("\n")];
    NSMutableArray *kept = [NSMutableArray array];
    NSUInteger start = lines.count > lineCount ? lines.count - lineCount : 0;
    for (NSUInteger i = start; i < lines.count; i++) {
        if (lines[i].length) [kept addObject:lines[i]];
    }
    return kept.count ? [kept componentsJoinedByString:S("\n")] : S("（日志为空）");
}

- (void)refreshDiagnostics {
    [self updateDiagnostics];
    [self reloadSpecifiers];
    NSString *message = [NSString stringWithFormat:S("%@\n\n最近运行日志：\n%@"),
                         [self diagnosticsText], [self recentLogTail:8]];
    [self alert:S("实时运行状态") message:message];
}

- (void)copyRunLog {
    NSString *path = [self diagnosticLogPath];
    if (!path.length) { [self alert:S("无运行日志") message:S("尚未生成 cputhermal-throttle.log，先让设备运行一会儿再试。")]; return; }
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: S("");
    NSArray<NSString *> *lines = [content componentsSeparatedByString:S("\n")];
    NSUInteger keep = 200;
    if (lines.count > keep) lines = [lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)];
    NSString *tail = [lines componentsJoinedByString:S("\n")];
    [UIPasteboard generalPasteboard].string = tail;
    [self alert:S("已复制运行日志") message:[NSString stringWithFormat:S("已复制最近 %lu 行到剪贴板。\n文件：%@"), (unsigned long)lines.count, path]];
}

- (void)clearRunLog {
    NSString *path = [self diagnosticLogPath];
    if (!path.length) { [self alert:S("无运行日志") message:S("当前没有可清空的日志文件。")]; return; }
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [self alert:S("已清空运行日志") message:path];
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

- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self updateDiagnostics];}
- (NSArray *)specifiers {
    if (!_specifiers) {
        // 直接从 Root.plist 加载配置结构，Preferences 框架会自动正确解析 PSSegmentCell
        _specifiers = [self loadSpecifiersFromPlistName:S("Root") target:self];
    }
    return _specifiers;
}

@end
