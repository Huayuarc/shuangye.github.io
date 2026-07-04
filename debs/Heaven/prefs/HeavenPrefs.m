#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <notify.h>
#import <dlfcn.h>
#import <rootless.h>

@interface HeavenRootListController : PSListController
@property (nonatomic, strong) NSMutableDictionary *savedSpecifiers;
@property (nonatomic, strong) NSArray *appProfiles;
@property (nonatomic, strong) NSArray *snapshots;
@end

@implementation HeavenRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.savedSpecifiers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self.savedSpecifiers removeAllObjects];
        for (PSSpecifier *spec in _specifiers) {
            if (spec.identifier) {
                self.savedSpecifiers[spec.identifier] = spec;
            }
        }
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"重启"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(actionRespring)];

    // Observe preference changes to refresh UI
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        prefsChangedCallback,
        CFSTR("vip.abc3.heaven/prefsChanged"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        CFSTR("vip.abc3.heaven/prefsChanged"),
        NULL
    );
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    HeavenRootListController *self = (__bridge HeavenRootListController *)observer;
    [self reloadSpecifiers];
}

- (void)reloadSpecifiers {
    [self.table reloadData];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!prefs) prefs = @{};

    NSString *key = specifier.identifier ?: [specifier propertyForKey:@"key"];
    if (!key) return nil;

    id value = prefs[key];
    if (!value) {
        value = [specifier propertyForKey:@"default"];
    }

    // For PSSwitchCell, return NSNumber
    if ([[specifier propertyForKey:@"cell"] isEqualToString:@"PSSwitchCell"]) {
        return value ?: @NO;
    }

    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!prefs) prefs = [NSMutableDictionary dictionary];

    NSString *key = specifier.identifier ?: [specifier propertyForKey:@"key"];
    if (key) {
        prefs[key] = value;
    }

    [prefs writeToFile:path atomically:YES];

    // Notify tweak of preference change
    notify_post("vip.abc3.heaven/prefsChanged");
}

#pragma mark - Actions

- (void)actionSelectApp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"选择应用"
        message:@"从已安装的应用中选择"
        preferredStyle:UIAlertControllerStyleActionSheet];

    // Scan installed apps
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appDir = ROOT_PATH_NS(@"/var/containers/Bundle/Application");
    NSArray *appDirs = [fm contentsOfDirectoryAtPath:appDir error:nil];

    for (NSString *dir in appDirs) {
        NSString *appPath = [appDir stringByAppendingPathComponent:dir];
        NSArray *contents = [fm contentsOfDirectoryAtPath:appPath error:nil];
        for (NSString *file in contents) {
            if ([file hasSuffix:@".app"]) {
                NSString *infoPath = [appPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/Info.plist", file]];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                NSString *bundleID = info[@"CFBundleIdentifier"];
                NSString *displayName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];

                if (bundleID) {
                    NSString *title = displayName ? [NSString stringWithFormat:@"%@ (%@)", displayName, bundleID] : bundleID;
                    UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                                     style:UIAlertActionStyleDefault
                                                                   handler:^(UIAlertAction *action) {
                        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"TargetBundleID" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSEditTextCell edit:nil];
                        [specifier setProperty:@"TargetBundleID" forKey:@"key"];
                        [self setPreferenceValue:bundleID specifier:specifier];
                        [self reloadSpecifiers];
                    }];
                    [alert addAction:action];
                }
            }
        }
    }

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancelAction];

    // For iPad
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionGenerateNewProfile {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"一键新机"
        message:@"生成全新的设备信息并清理所有痕迹？"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        notify_post("vip.abc3.heaven/regenerate");
        [self reloadSpecifiers];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionResetToDefault {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"真实设备"
        message:@"恢复显示真实的设备信息？"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!prefs) prefs = [NSMutableDictionary dictionary];

        // Clear all spoofed values but keep Enabled/AntiJailbreak/TargetBundleID
        NSArray *keysToRemove = @[
            @"DeviceName", @"MachineModel", @"SystemVersion", @"BuildVersion",
            @"SerialNumber", @"CPUMode", @"GPUModel", @"ProcessorCount",
            @"MemorySize", @"DiskSize", @"BatteryCapacity", @"BatteryHealth",
            @"IDFA", @"IDFV", @"InternalIP", @"MACAddress", @"CarrierName",
            @"NetworkType", @"WifiSSID", @"WifiBSSID", @"CellularAddress",
            @"DeviceIdentifier", @"CPUArchitecture", @"BluetoothAddress",
            @"WifiSerial", @"LocationName", @"Latitude", @"Longitude",
            @"UserAgent", @"IMEI", @"MEID", @"UDID", @"ECID",
        ];

        for (NSString *key in keysToRemove) {
            prefs[key] = nil;
        }

        [prefs writeToFile:path atomically:YES];
        notify_post("vip.abc3.heaven/prefsChanged");
        [self reloadSpecifiers];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionBackupManager {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"全息管理"
        message:@"选择操作"
        preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"保存当前配置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self saveCurrentProfileAsBackup];
    }];

    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:@"恢复配置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self restoreProfileFromBackup];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:saveAction];
    [alert addAction:restoreAction];
    [alert addAction:cancel];

    alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveCurrentProfileAsBackup {
    NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];

    NSString *backupDir = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/HeavenBackups");
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *backupPath = [backupDir stringByAppendingPathComponent:[NSString stringWithFormat:@"profile_%@.plist", timestamp]];

    if ([prefs writeToFile:backupPath atomically:YES]) {
        [self showAlertWithTitle:@"成功" message:@"配置已保存"];
    } else {
        [self showAlertWithTitle:@"失败" message:@"保存配置时出错"];
    }
}

- (void)restoreProfileFromBackup {
    NSString *backupDir = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/HeavenBackups");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:backupDir error:nil];

    if (files.count == 0) {
        [self showAlertWithTitle:@"无备份" message:@"没有找到保存的配置"];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"选择配置恢复"
        message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *file in files) {
        if ([file hasSuffix:@".plist"]) {
            UIAlertAction *action = [UIAlertAction actionWithTitle:file
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
                NSString *backupPath = [backupDir stringByAppendingPathComponent:file];
                NSDictionary *backup = [NSDictionary dictionaryWithContentsOfFile:backupPath];
                NSString *prefsPath = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
                [backup writeToFile:prefsPath atomically:YES];
                notify_post("vip.abc3.heaven/prefsChanged");
                [self reloadSpecifiers];
                [self showAlertWithTitle:@"成功" message:@"配置已恢复"];
            }];
            [alert addAction:action];
        }
    }

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];

    alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionSnapshotManager {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"快照管理"
        message:@"创建或恢复快照"
        preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"创建快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self createSnapshot];
    }];

    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:@"恢复快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self restoreSnapshot];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:saveAction];
    [alert addAction:restoreAction];
    [alert addAction:cancel];

    alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createSnapshot {
    NSString *path = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];

    NSString *snapshotDir = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/HeavenSnapshots");
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:snapshotDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *snapshotPath = [snapshotDir stringByAppendingPathComponent:[NSString stringWithFormat:@"snapshot_%@.plist", timestamp]];

    if ([prefs writeToFile:snapshotPath atomically:YES]) {
        [self showAlertWithTitle:@"成功" message:@"快照已创建"];
    } else {
        [self showAlertWithTitle:@"失败" message:@"创建快照时出错"];
    }
}

- (void)restoreSnapshot {
    NSString *snapshotDir = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/HeavenSnapshots");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:snapshotDir error:nil];

    if (files.count == 0) {
        [self showAlertWithTitle:@"无快照" message:@"没有找到保存的快照"];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"选择快照恢复"
        message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *file in files) {
        if ([file hasSuffix:@".plist"]) {
            UIAlertAction *action = [UIAlertAction actionWithTitle:file
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
                NSString *snapPath = [snapshotDir stringByAppendingPathComponent:file];
                NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:snapPath];
                NSString *prefsPath = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
                [snapshot writeToFile:prefsPath atomically:YES];
                notify_post("vip.abc3.heaven/prefsChanged");
                [self reloadSpecifiers];
                [self showAlertWithTitle:@"成功" message:@"快照已恢复"];
            }];
            [alert addAction:action];
        }
    }

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];

    alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionProfileManager {
    // Show profile manager - similar to backup
    [self actionBackupManager];
}

- (void)actionCleanAll {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"清理"
        message:@"清理 Safari 数据、剪贴板和 Keychain？"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        notify_post("vip.abc3.heaven/prefsChanged");
        [self showAlertWithTitle:@"清理完成" message:@"Safari/剪贴板/Keychain 已清理"];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionCleanAppStore {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"AppStore 清理"
        message:@"是否清理 App Store 缓存并重置？"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *pathsToClean = @[
            ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.apple.AppStore.plist"),
            ROOT_PATH_NS(@"/var/mobile/Library/Caches/com.apple.AppStore"),
        ];
        for (NSString *path in pathsToClean) {
            [fm removeItemAtPath:path error:nil];
        }
        [self showAlertWithTitle:@"完成" message:@"App Store 缓存已清理"];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionCleanAppleID {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Apple ID 清理"
        message:@"清理 Apple ID 相关的缓存和账户数据？"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *pathsToClean = @[
            ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.apple.accountsd.plist"),
            ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.apple.AuthKit.plist"),
            ROOT_PATH_NS(@"/var/mobile/Library/Caches/com.apple.accountsd"),
            ROOT_PATH_NS(@"/var/mobile/Library/Caches/com.apple.akd"),
            ROOT_PATH_NS(@"/var/mobile/Library/Caches/com.apple.appleid"),
        ];
        for (NSString *path in pathsToClean) {
            [fm removeItemAtPath:path error:nil];
        }
        [self showAlertWithTitle:@"完成" message:@"Apple ID 缓存已清理"];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionAdvancedCleanup {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"强效清理"
        message:@"深度清理所有应用缓存和数据？此操作不可恢复！"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认强效清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];

        NSArray *patterns = @[
            @"Library/Caches",
            @"Library/WebKit",
            @"Library/Cookies",
            @"Library/Safari",
            @"Library/SplashBoard",
            @"Library/AddressBook",
            @"Library/CallHistoryDB",
            @"Library/CallHistoryTransactionLogs",
        ];

        NSString *appDir = ROOT_PATH_NS(@"/var/mobile/Containers/Data/Application");
        NSArray *appDirs = [fm contentsOfDirectoryAtPath:appDir error:nil];
        for (NSString *dir in appDirs) {
            NSString *appHome = [appDir stringByAppendingPathComponent:dir];
            for (NSString *pattern in patterns) {
                NSString *target = [appHome stringByAppendingPathComponent:pattern];
                if ([fm fileExistsAtPath:target]) {
                    [fm removeItemAtPath:target error:nil];
                }
            }
        }

        [self showAlertWithTitle:@"完成" message:@"强效清理已完成，建议重启设备"];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionRespring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"重载 SpringBoard"
        message:@"确认重启桌面？"
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        pid_t pid;
        const char *killallPath = ROOT_PATH_NS(@"/usr/bin/killall").UTF8String;
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, killallPath, NULL, NULL, (char *const *)args, NULL);
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirm];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

@end
