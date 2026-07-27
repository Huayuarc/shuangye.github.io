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

// 默认偏好值
static NSDictionary *CPUthermalDefaultPrefs(void) {
    return @{
        @"thermalControlMode": @(ThermalControlModeFullPower),  // 2
        @"thermalPreventDimmingEnabled": @YES,
        @"thermalBlockNotifPopup": @YES,
    };
}

// ── 从 plist 文件读取并修正值类型 ──
// 确保返回的 thermalControlMode 是 NSNumber integer，
// thermalPreventDimmingEnabled / thermalBlockNotifPopup 是 NSNumber bool，
// 避免因旧版本遗留的错误类型导致 PSSegmentCell 显示空白。
+ (NSMutableDictionary *)_typedPrefsFromFile {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) return nil;

    // thermalControlMode 必须为 NSNumber integer
    id mode = prefs[@"thermalControlMode"];
    if (mode && ![mode isKindOfClass:[NSNumber class]]) {
        prefs[@"thermalControlMode"] = @([mode integerValue]);
    }

    // 布尔值确保为 NSNumber bool
    for (NSString *key in @[@"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"]) {
        id val = prefs[key];
        if (val && ![val isKindOfClass:[NSNumber class]]) {
            prefs[key] = @([val boolValue]);
        }
    }

    return prefs;
}

// ── 初始化默认值（在 specifiers 加载前执行） ──
// PSSegmentCell 在 iOS 16 上直接从 NSUserDefaults suite 读取值用于显示。
// registerDefaults 仅设置内存回退值，不写入 plist 文件，导致首次加载时
// segment 控件因找不到持久化值而显示空白。
// 此方法确保 NSUserDefaults suite 和文件都真实存在值。
- (void)_ensureDefaultValues {
    NSDictionary *defaults = CPUthermalDefaultPrefs();

    // 1) 检查并写入 rootless 路径 plist 文件（供 tweak 代码直接读取）
    NSMutableDictionary *filePrefs = [self.class _typedPrefsFromFile];
    if (!filePrefs) {
        filePrefs = [NSMutableDictionary dictionaryWithDictionary:defaults];
        [filePrefs writeToFile:PREFS_PATH atomically:YES];
    }

    // 2) 确保 NSUserDefaults suite 有持久化值（供 PSSegmentCell 读取）
    //    注意：不使用 registerDefaults，因为它只设内存值，不让 nil-check 通过。
    NSString *suiteName = @"com.huayuarc.cputhermal-prefs";
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    BOOL needsSync = NO;

    for (NSString *key in defaults) {
        // 先尝试从 NSUserDefaults 读取（保留用户已设值）
        id existingValue = [suiteDefaults objectForKey:key];
        if (existingValue) {
            // 检查类型是否正确
            NSNumber *expectedDefault = defaults[key];
            if (![existingValue isKindOfClass:[expectedDefault class]]) {
                // 类型不匹配，从文件取修正后的值
                id fileValue = filePrefs[key];
                [suiteDefaults setObject:fileValue ?: expectedDefault forKey:key];
                needsSync = YES;
            }
            // 类型正确，保留 NSUserDefaults 的值，不做任何写入
            continue;
        }

        // NSUserDefaults 无值，从文件同步
        id fileValue = filePrefs[key];
        if (fileValue) {
            [suiteDefaults setObject:fileValue forKey:key];
        } else {
            [suiteDefaults setObject:defaults[key] forKey:key];
        }
        needsSync = YES;
    }

    // 同时确保文件中有值的键也同步到 NSUserDefaults
    for (NSString *key in filePrefs) {
        if ([defaults objectForKey:key] != nil) continue; // 已在上面处理
        id existingValue = [suiteDefaults objectForKey:key];
        if (!existingValue) {
            [suiteDefaults setObject:filePrefs[key] forKey:key];
            needsSync = YES;
        }
    }

    if (needsSync) {
        [suiteDefaults synchronize];
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 尽早确保默认值存在，比 specifiers 调用更早
        // 防止 PSSegmentCell 在 specifiers 加载之前读取 NSUserDefaults 得到 nil
        [self _ensureDefaultValues];
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        [self _ensureDefaultValues];
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 清空，不要任何代码
}

// ── 读取偏好值 ──
// 优先从 NSUserDefaults 读取（PSSegmentCell 的读取路径），
// 再从文件 plist 兜底，最后用 specifier 的 default 值。
// 这样确保 PSSegmentCell 和 readPreferenceValue: 返回一致的值。
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier.properties objectForKey:@"key"];
    id defaultValue = [specifier.properties objectForKey:@"default"];

    // 优先从 NSUserDefaults suite 读取（PSSegmentCell 也是走这条路）
    NSString *defaultsSuite = [specifier.properties objectForKey:@"defaults"];
    if (defaultsSuite && key) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
        id value = [defaults objectForKey:key];
        if (value) return value;
    }

    // 兜底从文件 plist 读取
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    id value = [prefs objectForKey:key];
    if (value) return value;

    // 最终兜底用 specifier default
    return defaultValue;
}

// ── 写入偏好值 ──
// 同时写入 NSUserDefaults suite（供 PSSegmentCell 等系统 cell 读取）
// 和文件 plist（供 thermalmonitord 中的 tweak 读取），然后发送通知。
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier.properties objectForKey:@"key"];
    if (!key) return;

    // 写入 NSUserDefaults suite（PSSegmentCell/PSSwitchCell 读取路径）
    NSString *defaultsSuite = [specifier.properties objectForKey:@"defaults"];
    if (defaultsSuite) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
        [defaults setObject:value forKey:key];
        [defaults synchronize];
    }

    // 写入文件 plist（thermalmonitord 中 tweak 的读取路径）
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    [prefs setObject:value forKey:key];
    [prefs writeToFile:PREFS_PATH atomically:YES];

    // 通知 thermalmonitord 重新加载偏好（双通道）
    if ([key isEqualToString:@"thermalControlMode"] ||
        [key isEqualToString:@"thermalPreventDimmingEnabled"] ||
        [key isEqualToString:@"thermalBlockNotifPopup"]) {
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
