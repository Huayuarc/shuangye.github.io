// ============================================================================
// HeavenRootListController.m — 主设置列表控制器实现
// 逆向还原自 HeavenPrefs
// [RE] 标注 = 逆向推测部分
// ============================================================================

#import "HeavenRootListController.h"

#include <substrate.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <notify.h>

// [RE] 推测: 偏好设置路径
static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.huayuarc.xinji.heaven.plist";

@interface HeavenRootListController ()
// [RE] 推测: 内部使用的 ivar (通过 _ivarMap 推断)
@property (nonatomic, strong) UIImageView *headerImageView;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UILabel *headerSubtitleLabel;
@property (nonatomic, strong) NSMutableDictionary *specifierCache;
@end

@implementation HeavenRootListController

// ============================================================================
// 生命周期
// ============================================================================

- (instancetype)init {
    self = [super init];
    if (self) {
        _specifierCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self _setupHeader];
    [self _styleTableView];

    // [RE] 推测: 刷新所有 specifier 的数值显示
    [self reloadSpecifiers];
}

// ============================================================================
// _setupHeader — 设置页面顶部横幅
// [RE] 推测: 显示 Heaven logo + 版本
// ============================================================================
- (void)_setupHeader {
    // [RE] 推测: 先移除旧的 header view (如果有)
    if (self.headerImageView) {
        [self.headerImageView removeFromSuperview];
    }
    if (self.headerTitleLabel) {
        [self.headerTitleLabel removeFromSuperview];
    }
    if (self.headerSubtitleLabel) {
        [self.headerSubtitleLabel removeFromSuperview];
    }

    CGFloat tableWidth = self.view.frame.size.width;
    CGFloat headerHeight = 120.0;

    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableWidth, headerHeight)];
    headerView.backgroundColor = [UIColor clearColor];

    // [RE] 推测: 标题 "Heaven"
    self.headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 25, tableWidth, 40)];
    self.headerTitleLabel.text = @"Heaven";
    self.headerTitleLabel.font = [UIFont boldSystemFontOfSize:34];
    self.headerTitleLabel.textColor = [UIColor systemBlueColor];
    self.headerTitleLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:self.headerTitleLabel];

    NSString *subtitle = @"v1.0";

    self.headerSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 65, tableWidth, 20)];
    self.headerSubtitleLabel.text = subtitle;
    self.headerSubtitleLabel.font = [UIFont systemFontOfSize:14];
    self.headerSubtitleLabel.textColor = [UIColor grayColor];
    self.headerSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:self.headerSubtitleLabel];

    // [RE] 推测: 底部装饰线
    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(20, headerHeight - 1, tableWidth - 40, 1)];
    separator.backgroundColor = [UIColor lightGrayColor];
    separator.alpha = 0.3;
    [headerView addSubview:separator];

    self.tableView.tableHeaderView = headerView;
}

// ============================================================================
// _styleTableView — 设置表格样式
// ============================================================================
- (void)_styleTableView {
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    // [RE] 推测: 设置分隔线样式
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 15, 0, 15);
}

// ============================================================================
// PSListController 协议方法 — Specifier 数据源
// ============================================================================

- (NSArray *)specifiers {
    if (!_specifiers) {
        // [RE] 推测: 从 plist 加载 specifiers
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// ============================================================================
// 读取偏好值
// ============================================================================
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    id value = prefs[[specifier propertyForKey:@"key"]];
    if (!value) {
        value = [specifier propertyForKey:@"default"];
    }
    return value ?: @NO;
}

// ============================================================================
// 写入偏好值
// ============================================================================
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!prefs) prefs = [NSMutableDictionary dictionary];

    if (value) {
        prefs[key] = value;
    } else {
        [prefs removeObjectForKey:key];
    }

    [prefs writeToFile:kPrefsPath atomically:YES];

    // [RE] 推测: 发送 CFNotification 让主插件重新加载设置
    [self _postSettingsChanged];
}

// ============================================================================
// 清理功能 — Clean All
// ============================================================================
- (void)actionCleanAll {
    // [RE] 推测: 显示确认弹窗
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clean All Data"
                         message:@"This will clear Keychain, Cookies, Caches, and WebKit data. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"Clean" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction * _Nonnull action) {
            [self _performCleanAll];
        }];

    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

// [RE] 推测: 实际执行清理 — 通过 CFNotification 通知主插件
- (void)_performCleanAll {
    // [RE] 推测: 向主插件发送清理通知
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.huayuarc.xinji.heaven/cleanAll"),
        NULL, NULL, YES
    );

    // [RE] 推测: 显示成功信息
    [self _showTemporaryStatus:@"All data cleaned successfully" forDuration:2.0];
}

// ============================================================================
// 清理 Apple ID Keychain
// ============================================================================
- (void)actionCleanAppleID {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clear Apple ID Data"
                         message:@"This will sign you out of iCloud and App Store. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction * _Nonnull action) {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.huayuarc.xinji.heaven/cleanAppleID"),
                NULL, NULL, YES
            );
            [self _showTemporaryStatus:@"Apple ID data cleared" forDuration:2.0];
        }];

    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 清理 App Store 相关 Keychain
// ============================================================================
- (void)actionCleanAppStore {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clear App Store Data"
                         message:@"This will clear App Store login and receipt data. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction * _Nonnull action) {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.huayuarc.xinji.heaven/cleanAppStore"),
                NULL, NULL, YES
            );
            [self _showTemporaryStatus:@"App Store data cleared" forDuration:2.0];
        }];

    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 高级清理
// ============================================================================
- (void)actionAdvancedCleanup {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Advanced Cleanup"
                         message:@"Choose a cleanup task to request from the tweak."
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Clean Cookies" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _postDarwinNotification:@"com.huayuarc.xinji.heaven/cleanCookies"];
        [self _showTemporaryStatus:@"Cookie cleanup requested" forDuration:2.0];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clean WebKit Data" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _postDarwinNotification:@"com.huayuarc.xinji.heaven/cleanWebKit"];
        [self _showTemporaryStatus:@"WebKit cleanup requested" forDuration:2.0];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clean Pasteboard" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _postDarwinNotification:@"com.huayuarc.xinji.heaven/cleanPasteboard"];
        [self _showTemporaryStatus:@"Pasteboard cleanup requested" forDuration:2.0];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 备份管理
// ============================================================================
- (void)actionBackupManager {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *backupPath = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:@"com.huayuarc.xinji.heaven.backup.plist"];
    NSError *error = nil;

    if ([fm fileExistsAtPath:kPrefsPath]) {
        [fm removeItemAtPath:backupPath error:nil];
        if ([fm copyItemAtPath:kPrefsPath toPath:backupPath error:&error]) {
            [self _showTemporaryStatus:@"Settings backup saved" forDuration:2.0];
            return;
        }
    }

    [self _showTemporaryStatus:error.localizedDescription ?: @"No settings to backup" forDuration:2.0];
}

// ============================================================================
// 快照管理
// ============================================================================
- (void)actionSnapshotManager {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    NSArray *keys = @[@"spoofedDeviceName", @"spoofedModel", @"spoofedSystemVersion", @"spoofedIDFA", @"spoofedIDFV"];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *key in keys) {
        NSString *value = prefs[key];
        if (value.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
        }
    }
    [self _presentText:@"Current Snapshot" message:lines.count ? [lines componentsJoinedByString:@"\n"] : @"No spoofing values are configured."];
}

// ============================================================================
// 配置文件管理
// ============================================================================
- (void)actionProfileManager {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Profile Manager"
                         message:@"Generate a new profile or reset current settings from the buttons in this page."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Generate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self actionGenerateNewProfile];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self actionResetToDefault];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 按应用选择设置
// ============================================================================
- (void)actionSelectApp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Select App"
                         message:@"Enter a bundle identifier to remember as the target app."
                  preferredStyle:UIAlertControllerStyleAlert];

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"com.example.app";
        textField.text = prefs[@"selectedBundleID"] ?: @"";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *bundleID = alert.textFields.firstObject.text;
        NSMutableDictionary *updatedPrefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary dictionary];
        if (bundleID.length > 0) {
            updatedPrefs[@"selectedBundleID"] = bundleID;
        } else {
            [updatedPrefs removeObjectForKey:@"selectedBundleID"];
        }
        [updatedPrefs writeToFile:kPrefsPath atomically:YES];
        [self _postSettingsChanged];
        [self _showTemporaryStatus:@"Target app saved" forDuration:2.0];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 生成新配置文件
// ============================================================================
- (void)actionGenerateNewProfile {
    // [RE] 推测: 随机生成一组设备信息
    // 从设备型号映射表中随机选取一个型号
    NSArray *models = @[
        @"iPhone15,4", @"iPhone15,5",
        @"iPhone16,1", @"iPhone16,2",
        @"iPhone17,1", @"iPhone17,3",
    ];
    NSString *randomModel = models[arc4random_uniform((uint32_t)models.count)];

    // 生成随机的 UDID/ECID 等
    NSString *randomUDID = [self _generateRandomHexString:40];
    NSString *randomECID = [self _generateRandomHexString:16];

    // [RE] 推测: 写入偏好设置
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[@"spoofedModel"] = randomModel;
    prefs[@"spoofedUDID"] = randomUDID;
    prefs[@"spoofedECID"] = randomECID;
    [prefs writeToFile:kPrefsPath atomically:YES];

    [self _showTemporaryStatus:[NSString stringWithFormat:@"Generated profile for %@", randomModel]
                    forDuration:3.0];
}

- (NSString *)_generateRandomHexString:(NSUInteger)length {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [hex appendFormat:@"%x", arc4random_uniform(16)];
    }
    return [hex copy];
}

// ============================================================================
// 查看当前配置文件
// ============================================================================
- (void)actionViewCurrentProfile {
    // [RE] 推测: 显示当前生效的欺骗配置
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];

    NSMutableString *info = [NSMutableString string];
    [info appendString:@"Current Spoof Profile:\n\n"];
    [info appendFormat:@"Model: %@\n", prefs[@"spoofedModel"] ?: @"Not set"];
    [info appendFormat:@"Device Name: %@\n", prefs[@"spoofedDeviceName"] ?: @"Not set"];
    [info appendFormat:@"iOS Version: %@\n", prefs[@"spoofedSystemVersion"] ?: @"Not set"];
    [info appendFormat:@"IDFA: %@\n", prefs[@"spoofedIDFA"] ?: @"Not set"];
    [info appendFormat:@"IDFV: %@\n", prefs[@"spoofedIDFV"] ?: @"Not set"];
    [info appendFormat:@"Carrier: %@\n", prefs[@"spoofedCarrier"] ?: @"Not set"];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Current Profile"
                         message:info
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 显示实际设备信息
// ============================================================================
- (void)actionShowDeviceInfo {
    // [RE] 推测: 显示设备的真实信息 (不经过欺骗)
    UIDevice *device = [UIDevice currentDevice];

    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    NSString *model = @"Unknown";
    if (machine) {
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        model = [NSString stringWithCString:machine encoding:NSUTF8StringEncoding];
        free(machine);
    }

    NSString *info = [NSString stringWithFormat:
        @"Device: %@\n"
        @"Model: %@\n"
        @"System: %@\n"
        @"Name: %@\n"
        @"IDFV: %@\n"
        @"Language: %@\n",
        device.model,
        model,
        device.systemVersion,
        device.name,
        [[device identifierForVendor] UUIDString] ?: @"N/A",
        [[NSLocale currentLocale] localeIdentifier]
    ];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Real Device Info"
                         message:info
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 重置为默认值
// ============================================================================
- (void)actionResetToDefault {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset to Default"
                         message:@"This will reset all settings to default values. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction * _Nonnull action) {
            // [RE] 推测: 删除偏好文件
            [[NSFileManager defaultManager] removeItemAtPath:kPrefsPath error:nil];
            [self _postSettingsChanged];
            [self reloadSpecifiers];
            [self _setupHeader];
            [self _showTemporaryStatus:@"Settings reset to default" forDuration:2.0];
        }];

    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// Respring
// ============================================================================
- (void)actionRespring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Respring"
                         message:@"Are you sure you want to respring SpringBoard?"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction * _Nonnull action) {
            [self _performRespring];
        }];

    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

// [RE] 推测: 执行 respring — 重启 backboardd 或 SpringBoard
- (void)_performRespring {
    // [RE] 推测: 使用 notify 或 posix_spawn 调用 killall
    pid_t pid;
    const char *argv[] = {"killall", "-9", "SpringBoard", NULL};

    // [RE] 推测: 在 rootless 环境中使用 /var/jb/usr/bin/killall
    posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL,
                (char *const *)argv, NULL);

    // Fallback: 使用 notify
    notify_post("com.apple.springboard.respring");
}

// ============================================================================
// 打开反馈
// ============================================================================
- (void)actionOpenFeedback {
    NSURL *mailURL = [NSURL URLWithString:@"mailto:support@huayuarc.com?subject=Heaven%20Feedback"];
    if ([[UIApplication sharedApplication] canOpenURL:mailURL]) {
        [[UIApplication sharedApplication] openURL:mailURL options:@{} completionHandler:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Feedback"
                         message:@"Please send feedback to support@huayuarc.com."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 辅助: Darwin 通知
// ============================================================================
- (void)_postSettingsChanged {
    [self _postDarwinNotification:@"com.huayuarc.xinji.heaven/settingschanged"];
}

- (void)_postDarwinNotification:(NSString *)name {
    if (!name.length) return;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name,
        NULL, NULL, YES
    );
}

// ============================================================================
// 辅助: 文本弹窗
// ============================================================================
- (void)_presentText:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 辅助: 临时状态提示 (HUD)
// ============================================================================
- (void)_showTemporaryStatus:(NSString *)status forDuration:(NSTimeInterval)duration {
    // [RE] 推测: 在屏幕中央显示临时文字提示
    UILabel *toast = [[UILabel alloc] init];
    toast.text = status;
    toast.font = [UIFont systemFontOfSize:14];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.numberOfLines = 0;
    toast.layer.cornerRadius = 10;
    toast.clipsToBounds = YES;

    CGSize textSize = [status boundingRectWithSize:CGSizeMake(260, 100)
                                           options:NSStringDrawingUsesLineFragmentOrigin
                                        attributes:@{NSFontAttributeName: toast.font}
                                           context:nil].size;
    CGFloat toastW = textSize.width + 30;
    CGFloat toastH = textSize.height + 20;
    toast.frame = CGRectMake(
        (self.view.frame.size.width - toastW) / 2,
        self.view.frame.size.height / 2 - 50,
        toastW, toastH
    );

    [self.view addSubview:toast];

    [UIView animateWithDuration:0.3 animations:^{
        toast.alpha = 1.0;
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            toast.alpha = 0.0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// ============================================================================
// UITableView Delegate — 样式设置
// ============================================================================
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    // [RE] 推测: 统一设置 header 文字样式
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.textColor = [UIColor systemBlueColor];
        header.textLabel.font = [UIFont boldSystemFontOfSize:13];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // [RE] 推测: 统一设置 cell 样式
    cell.backgroundColor = [UIColor whiteColor];
    cell.textLabel.textColor = [UIColor darkTextColor];
    cell.detailTextLabel.textColor = [UIColor grayColor];
}

@end
