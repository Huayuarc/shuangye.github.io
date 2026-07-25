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
        @"thermalBlockNotifPopup": @YES,
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
               [key isEqualToString:@"thermalPreventDimmingEnabled"] ||
               [key isEqualToString:@"thermalBlockNotifPopup"]) {
        // 通知 thermalmonitord 重新加载偏好
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kCPUthermalReloadNotification,
            NULL, NULL, YES
        );
    }
}

#pragma mark - CPU 模式选择

// ============================================================
// CPU 模式选择弹窗
// ============================================================
- (void)showPowerModePicker:(PSSpecifier *)specifier {
    NSString *currentValue = [self readPreferenceValue:specifier] ?: @"off";
    NSArray *titles = @[@"解除温控", @"低功耗"];
    NSArray *values  = @[@"off", @"lowPower"];

    // 找到当前模式对应的显示名称
    NSUInteger currentIdx = [values indexOfObject:currentValue];
    NSString *currentLabel = (currentIdx != NSNotFound) ? titles[currentIdx] : titles[0];
    NSString *message = [NSString stringWithFormat:@"当前：%@\n请选择 CPU 模式", currentLabel];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"CPU 模式"
        message:message
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSUInteger i = 0; i < titles.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:titles[i]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *action) {
            [self setPreferenceValue:values[i] specifier:specifier];
        }];
        [alert addAction:action];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad 支持（防止崩溃）
    alert.popoverPresentationController.sourceView = self.view;
    CGFloat h = self.view.bounds.size.height;
    alert.popoverPresentationController.sourceRect = CGRectMake(0, h / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
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
