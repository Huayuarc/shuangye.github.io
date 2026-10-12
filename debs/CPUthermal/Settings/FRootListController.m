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

// Forward declarations for preference and alert actions.
@interface FRootListController (CPUthermalActionsForward)
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

    // 运行方式：写偏好后立即通知主模块应用（分段选择直接写偏好，必须在此联动）
    if ([key isEqualToString:S("powerMode")]) {
        CPUthermalPostPowerMode([value isKindOfClass:[NSString class]] ? value : S("fullPower"));
    }
    notify_post(kCPUthermalSettingsChangedNotifC);
}


- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return nil;
    id val = [self prefs][key];
    if (val != nil) return val;
    id defaultValue = [spec propertyForKey:S("default")];
    return defaultValue ?: [NSNumber numberWithBool:NO];
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
        NSMutableArray *specifiers = [NSMutableArray array];
#define GROUP(label, footer) do { \
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:((label) ? S(label) : nil)]; \
            if (footer) [group setProperty:S(footer) forKey:S("footerText")]; \
            [specifiers addObject:group]; \
        } while (0)
#define ITEM(label, key, cell, def) do { \
            PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:S(label) target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:cell edit:nil]; \
            [item setProperty:S(key) forKey:S("key")]; \
            [item setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")]; \
            [item setProperty:def forKey:S("default")]; \
            [specifiers addObject:item]; \
        } while (0)
        GROUP("温度保护", "运行方式决定用户态预算请求：低功耗仅限制 CPU（2500mW／45%／Level2），清除 GPU/Package 满预算下限，不动亮度；解除温控请求 CPU/GPU/Package Floor/Ceiling=100、CPU Level0。Package 是共享功率预算，不是整个 SoC 硬锁；不保证最大时钟或实际满功率，硬件保护仍可接管。");
        PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:S("运行方式") target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSegmentCell edit:nil];
        [mode setProperty:S("powerMode") forKey:S("key")]; [mode setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")];
        [mode setProperty:S("fullPower") forKey:S("default")]; [mode setProperty:@[S("低功耗"), S("解除温控")] forKey:S("validTitles")]; [mode setProperty:@[S("lowPower"), S("fullPower")] forKey:S("validValues")]; [specifiers addObject:mode];
        GROUP(nil, "开启后，SpringBoard 检测到设备屏幕朝下时模拟按下锁屏键。仅注入 SpringBoard，默认关闭。"); ITEM("设备朝下自动锁屏", "lockWhenFaceDown", PSSwitchCell, [NSNumber numberWithBool:NO]);
        GROUP("阳光暴晒", "强制锁定阳光暴晒 (Sunlight) 模式：屏幕亮度上限与对比度按强光环境提升，不再等待环境光判断；关闭即恢复系统自动检测。"); ITEM("锁定阳光暴晒模式", "sunlightLockedEnabled", PSSwitchCell, [NSNumber numberWithBool:NO]);
        GROUP("高温警告", "开启后在 SpringBoard 进程内把高温热状态与热通知读取伪装为正常，隐藏“需要冷却”界面并避免高温自动锁屏；关闭即恢复系统原生行为。默认开启；抑制警告可能延迟你察觉设备过热。"); ITEM("屏蔽高温温度计警告", "blockThermalPopup", PSSwitchCell, [NSNumber numberWithBool:YES]);
        GROUP("SmartBatteryAPI 智能停充", "移植 ChargeLimiter 电量阈值核心：可优先使用 AppleSmartBattery，达到阈值后通过 PredictiveChargingInhibit 停充；可选同时将 ExternalConnected 置为 false 禁流。电量下降 5% 后先恢复输入再恢复充电。"); ITEM("使用 SmartBatteryAPI", "smartChargeUseSmartBatteryAPI", PSSwitchCell, [NSNumber numberWithBool:YES]); ITEM("智能停充", "smartChargeEnabled", PSSwitchCell, [NSNumber numberWithBool:NO]); ITEM("停充时自动禁流", "smartChargeDisableInflow", PSSwitchCell, [NSNumber numberWithBool:NO]);
        PSSpecifier *level = [PSSpecifier preferenceSpecifierNamed:S("停充电量") target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSegmentCell edit:nil]; [level setProperty:S("smartChargeStopLevel") forKey:S("key")]; [level setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")]; [level setProperty:[NSNumber numberWithInt:80] forKey:S("default")]; [level setProperty:@[S("70%"),S("75%"),S("80%"),S("85%"),S("90%"),S("95%"),S("100%")] forKey:S("validTitles")]; [level setProperty:@[[NSNumber numberWithInt:70],[NSNumber numberWithInt:75],[NSNumber numberWithInt:80],[NSNumber numberWithInt:85],[NSNumber numberWithInt:90],[NSNumber numberWithInt:95],[NSNumber numberWithInt:100]] forKey:S("validValues")]; [specifiers addObject:level];
        GROUP("电流防降频", "依据电池充放电电流保护性能：充电时若仍在较大电流放电，会把适配器输入电流上限只升不降地提高到 3000mA（上限 3000）；大电流放电时不改写入，只通知温控守护重申满预算。默认开启。可能增加发热；无法绕过硬件/固件保护，也不能提升电池本身的放电能力。"); ITEM("启用电流防降频", "currentGuardEnabled", PSSwitchCell, [NSNumber numberWithBool:YES]);
        GROUP(nil, "安装或升级时会自动重启 thermalmonitord 载入插件；此处按钮用于手动重启整个用户空间。");
        PSSpecifier *reboot = [PSSpecifier preferenceSpecifierNamed:S("重启用户空间") target:self set:@selector(usreboot) get:nil detail:nil cell:PSButtonCell edit:nil]; [reboot setProperty:S("usreboot") forKey:S("action")]; [specifiers addObject:reboot];
        GROUP("开源", nil); PSSpecifier *source = [PSSpecifier preferenceSpecifierNamed:S("GitHub be-huge/insulation") target:self set:@selector(openSourceCode) get:nil detail:nil cell:PSButtonCell edit:nil]; [source setProperty:S("openSourceCode") forKey:S("action")]; [specifiers addObject:source];
#undef ITEM
#undef GROUP
        _specifiers = [specifiers copy];
    }
    return _specifiers;
}

@end
