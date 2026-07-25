#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import "Tweak.h"

#define PREFS_PATH rootlessPath(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal-prefs.plist")

#define kCPUthermalReloadNotification CFSTR("com.huayuarc.cputhermal-reloadPrefs")

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

    // 注册默认偏好值
    NSDictionary *defaults = @{
        @"thermalPowerMode": @"off",
        @"thermalPreventDimmingEnabled": @YES,
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
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

    if ([key isEqualToString:@"thermalPuppetValue"]) {
        // Puppet 事件通知
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.huayuarc.cputhermal-executePuppetEvent"),
            NULL, NULL, YES
        );
    } else if ([key isEqualToString:@"thermalPowerMode"] ||
               [key isEqualToString:@"thermalPreventDimmingEnabled"]) {
        // 通知 thermalmonitord 重新加载偏好
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kCPUthermalReloadNotification,
            NULL, NULL, YES
        );
    }
}

#pragma mark - 重启用户空间

// ============================================================
// 重启用户空间
// ============================================================
static BOOL _userspaceReboot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *launchctlPath = nil;
    for (NSString *candidate in @[@"/sbin/launchctl", @"/bin/launchctl"]) {
        NSString *resolved = rootlessPath(candidate);
        if ([fm fileExistsAtPath:resolved]) {
            launchctlPath = resolved;
            break;
        }
    }
    if (!launchctlPath) return NO;

    const char *argv[] = {
        [launchctlPath UTF8String],
        "reboot",
        "userspace",
        NULL
    };
    pid_t pid;
    int ret = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
    if (ret != 0) return NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int status;
        waitpid(pid, &status, 0);
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
        _userspaceReboot();
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
