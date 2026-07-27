#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <notify.h>
#import <crt_externs.h>
#include <roothide.h>
#import "Tweak.h"
#import "CPUthermalHelper.h"

#define PREFS_PATH rootlessPath(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist")

#define kCPUthermalReloadNotification CFSTR("com.huayuarc.cputhermal.reloadPrefs")
#define kCPUthermalReloadNotifyName  "com.huayuarc.cputhermal.reloadPrefs"

@interface CPUthermalPrefs : PSListController
@end

@implementation CPUthermalPrefs

- (NSArray *)specifiers {
    if (![self valueForKey:@"_specifiers"]) {
        NSArray *specs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self setValue:specs forKey:@"_specifiers"];
    }
    return [self valueForKey:@"_specifiers"];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 注册默认偏好值（用于 NSUserDefaults 读回退）
    NSDictionary *defaults = @{
        @"thermalControlMode": @2,
        @"thermalPreventDimmingEnabled": @YES,
        @"thermalBlockNotifPopup": @YES,
    };

    // ── 显式写入 NSUserDefaults suite 初始值 ──
    // PSSegmentCell 在 iOS 16 上依赖 NSUserDefaults 显式值初始化分段控件，
    // registerDefaults 仅设置内存回退值，不写入 plist 文件。
    // 此处用 setObject:forKey: 确保 plist 文件真实存在且有值。
    NSString *suiteName = @"com.huayuarc.cputhermal-prefs";
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    [suiteDefaults registerDefaults:defaults];
    BOOL needsSync = NO;
    for (NSString *key in defaults) {
        if ([suiteDefaults objectForKey:key] == nil) {
            [suiteDefaults setObject:defaults[key] forKey:key];
            needsSync = YES;
        }
    }
    if (needsSync) {
        [suiteDefaults synchronize];
    }

    // 确保 rootless 路径的 plist 文件也存在，供 tweak 代码直接读取
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:PREFS_PATH]) {
        NSMutableDictionary *initialPrefs = [NSMutableDictionary dictionary];
        for (NSString *key in defaults) {
            initialPrefs[key] = defaults[key];
        }
        [initialPrefs writeToFile:PREFS_PATH atomically:YES];
    }

    // ── 旧版配置迁移：将旧键名映射到新版 thermalControlMode ──
    NSMutableDictionary *existingPrefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (existingPrefs && existingPrefs[@"thermalControlMode"] == nil) {
        // 旧版使用 thermalPowerMode (string: "off"/"low"/"full")
        NSString *oldMode = existingPrefs[@"thermalPowerMode"];
        if ([oldMode isEqualToString:@"low"] || [oldMode isEqualToString:@"lowPower"]) {
            existingPrefs[@"thermalControlMode"] = @1;  // 低功耗
        } else if ([oldMode isEqualToString:@"full"] || [oldMode isEqualToString:@"fullPower"]) {
            existingPrefs[@"thermalControlMode"] = @2;  // 解除温控
        }
        // thermalUnlockEnabled=YES 旧版等同于解除温控
        if (existingPrefs[@"thermalControlMode"] == nil && [existingPrefs[@"thermalUnlockEnabled"] boolValue]) {
            existingPrefs[@"thermalControlMode"] = @2;
        }
        // requireLowPowerMode=YES 旧版等同于低功耗
        if (existingPrefs[@"thermalControlMode"] == nil && [existingPrefs[@"requireLowPowerMode"] boolValue]) {
            existingPrefs[@"thermalControlMode"] = @1;
        }
        // 兜底默认
        if (existingPrefs[@"thermalControlMode"] == nil) {
            existingPrefs[@"thermalControlMode"] = @2;
        }
        [existingPrefs writeToFile:PREFS_PATH atomically:YES];
    }
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *key = [specifier.properties objectForKey:@"key"];
    id defaultValue = [specifier.properties objectForKey:@"default"];
    id value = [prefs objectForKey:key];
    return value ?: defaultValue;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) prefs = [NSMutableDictionary dictionary];

    NSString *key = [specifier.properties objectForKey:@"key"];
    if (key) {
        [prefs setObject:value forKey:key];
        [prefs writeToFile:PREFS_PATH atomically:YES];
    }

    // 同步写入 NSUserDefaults suite，确保 PSSegmentCell 等系统 cell 能读取最新值
    NSString *defaultsSuite = [specifier.properties objectForKey:@"defaults"];
    if (defaultsSuite && key) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
        [defaults setObject:value forKey:key];
        [defaults synchronize];
    }

    if ([key isEqualToString:@"thermalControlMode"] ||
        [key isEqualToString:@"thermalPreventDimmingEnabled"] ||
        [key isEqualToString:@"thermalBlockNotifPopup"]) {
        // 通知 thermalmonitord 重新加载偏好（双通道）
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kCPUthermalReloadNotification,
            NULL, NULL, YES
        );
        notify_post(kCPUthermalReloadNotifyName);
    }
}

// ============================================================
// 开源代码 - 跳转 Safari
// ============================================================
- (void)openSourceCode {
    NSURL *url = [NSURL URLWithString:@"https://github.com/be-huge/insulation"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)openBattman {
    NSURL *url = [NSURL URLWithString:@"https://github.com/Torrekie/Battman"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - 重启用户空间

// ============================================================
// 重启用户空间（参考 CPUthermalPaths.h CPUthermalLaunchctlPath）
// ============================================================
static BOOL _userspaceReboot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 按优先级查找 launchctl（使用 jbroot 在 rootless 下正确解析路径）
    NSString *launchctlPath = nil;
    for (NSString *candidate in @[@"/usr/bin/launchctl", @"/bin/launchctl"]) {
        // jbroot 将路径映射到 Dopamine 实际位置
        NSString *resolved = [NSString stringWithUTF8String:jbroot([candidate UTF8String])];
        if ([fm isExecutableFileAtPath:resolved]) {
            launchctlPath = resolved;
            break;
        }
        // /var/jb 直接路径兜底
        NSString *varJBPath = [@"/var/jb" stringByAppendingString:candidate];
        if ([fm isExecutableFileAtPath:varJBPath]) {
            launchctlPath = varJBPath;
            break;
        }
    }

    if (!launchctlPath) {
        NSLog(@"[CPUthermalPrefs] launchctl not found");
        return NO;
    }

    const char *argv[] = {
        [launchctlPath UTF8String],
        "reboot",
        "userspace",
        NULL
    };

    // 传入当前环境变量（PATH 等），launchctl 依赖环境才能正常运行
    char **envp = *_NSGetEnviron();

    pid_t pid;
    int ret = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, envp);
    if (ret != 0) {
        NSLog(@"[CPUthermalPrefs] posix_spawn(%s) failed: %d (%s)",
              argv[0], ret, strerror(ret));
        return NO;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int status;
        waitpid(pid, &status, 0);
        NSLog(@"[CPUthermalPrefs] launchctl exited: %d", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    });

    return YES;
}

// ============================================================
// 按钮动作：重启用户空间
// ============================================================
- (void)userspaceRebootTapped:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"重启用户空间"
        message:@"重启用户空间将继续使用当前系统版本，无需重新越狱。\n\n此操作会强制关闭所有应用并重新加载系统环境。确定继续？"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        if (!_userspaceReboot()) {
            UIAlertController *errAlert = [UIAlertController
                alertControllerWithTitle:@"操作失败"
                message:@"无法执行重启用户空间，请检查 launchctl 是否存在或尝试手动重启。"
                preferredStyle:UIAlertControllerStyleAlert];
            [errAlert addAction:[UIAlertAction actionWithTitle:@"好"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
            [self presentViewController:errAlert animated:YES completion:nil];
        }
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
