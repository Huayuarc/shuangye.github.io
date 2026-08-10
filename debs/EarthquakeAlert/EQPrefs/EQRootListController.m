#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <sys/wait.h>
#import "EQPrefs.h"

@interface EQRootListController : PSListController
@end

@implementation EQRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"EQPrefs" target:self];
    }
    return _specifiers;
}

// ============================================================
// CFPreferences 读写（与 EQPrefs 共享同一 plist）
// ============================================================
- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return [super readPreferenceValue:spec];

    CFPropertyListRef val = CFPreferencesCopyValue(
        (__bridge CFStringRef)key,
        CFSTR("com.shuangye.earthquake"),
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    if (val) {
        // Copy 规则返回的 CF 对象必须将所有权安全移交 ARC；
        // 先 CFRelease 再返回 __bridge 指针会造成设置面板加载时 use-after-free。
        return CFBridgingRelease(val);
    }
    return [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return;

    CFPreferencesSetValue(
        (__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value,
        CFSTR("com.shuangye.earthquake"),
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    CFPreferencesSynchronize(
        CFSTR("com.shuangye.earthquake"),
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
}

// ============================================================
// 按钮动作
// ============================================================

/// 发送测试警报
- (void)testAlert {
    NSLog(@"[EQPrefs] 发送测试地震警报");

    NSDictionary *testEvent = @{
        @"eventId":   [NSString stringWithFormat:@"test_%.0f", [[NSDate date] timeIntervalSince1970]],
        @"magnitude": @6.8,
        @"place":     @"测试位置 - 模拟地震",
        @"latitude":  @30.5,
        @"longitude": @104.0,
        @"depth":     @10.0,
        @"time":      @([[NSDate date] timeIntervalSince1970]),
        @"source":    @"TEST",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
    [testEvent writeToFile:@"/var/mobile/Library/Preferences/com.shuangye.earthquake.latest.plist"
               atomically:YES];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.shuangye.earthquake.alert"),
        NULL, NULL, YES);

    [self showAlert:@"测试警报已发送" message:@"SpringBoard 将显示测试地震警报"];
}

/// 重置已处理事件
- (void)resetEvents {
    [[NSFileManager defaultManager] removeItemAtPath:
        @"/var/mobile/Library/Preferences/com.shuangye.earthquake.processed.plist" error:nil];
    [self showAlert:@"已重置" message:@"地震事件记录已清除，将重新处理所有事件"];
}

/// 重启守护进程
- (void)restartDaemon {
    const char *args[] = {
        "/var/jb/usr/bin/launchctl", "unload",
        "/var/jb/Library/LaunchDaemons/com.shuangye.earthquake.plist", NULL};
    pid_t pid;
    posix_spawn(&pid, args[0], NULL, NULL, (char *const *)args, NULL);
    waitpid(pid, NULL, 0);

    const char *args2[] = {
        "/var/jb/usr/bin/launchctl", "load",
        "/var/jb/Library/LaunchDaemons/com.shuangye.earthquake.plist", NULL};
    posix_spawn(&pid, args2[0], NULL, NULL, (char *const *)args2, NULL);

    [self showAlert:@"已重启" message:@"地震预警后台服务已重启"];
}

/// 查看运行状态
- (void)showStatus {
    BOOL enabled = [EQPrefs boolForKey:@"enabled" defaultValue:YES];
    double minMag = [EQPrefs doubleForKey:@"minMagnitude" defaultValue:2.5];

    NSString *status = [NSString stringWithFormat:@"状态: %@", enabled ? @"✅ 运行中" : @"⏹ 已暂停"];
    status = [status stringByAppendingFormat:@"\n震级阈值: M%.1f", minMag];
    status = [status stringByAppendingString:@"\n数据源: USGS(主) / EMSC+USGS-CN(备)"];
    status = [status stringByAppendingString:@"\n类型: 震后目录提醒（非官方秒级EEW）"];

    NSDictionary *event = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.shuangye.earthquake.latest.plist"];
    if (event) {
        status = [status stringByAppendingFormat:@"\n\n最近事件: M%@ %@",
                  event[@"magnitude"], event[@"place"]];
    }

    [self showAlert:@"地震预警状态" message:status];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
