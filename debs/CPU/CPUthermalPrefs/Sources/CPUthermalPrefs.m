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
@property (nonatomic, strong) UISegmentedControl *modeSegmentControl;
@end

@implementation CPUthermalPrefs

static NSDictionary *CPUthermalDefaultPrefs(void) {
    return @{
        @"thermalControlMode": @(ThermalControlModeFullPower),
        @"thermalPreventDimmingEnabled": @YES,
        @"thermalBlockNotifPopup": @YES,
    };
}

+ (NSMutableDictionary *)_typedPrefsFromFile {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) return nil;

    id mode = prefs[@"thermalControlMode"];
    if (mode && ![mode isKindOfClass:[NSNumber class]]) {
        prefs[@"thermalControlMode"] = @([mode integerValue]);
    }

    for (NSString *key in @[@"thermalPreventDimmingEnabled", @"thermalBlockNotifPopup"]) {
        id val = prefs[key];
        if (val && ![val isKindOfClass:[NSNumber class]]) {
            prefs[key] = @([val boolValue]);
        }
    }

    return prefs;
}

- (void)_ensureDefaultValues {
    NSDictionary *defaults = CPUthermalDefaultPrefs();
    NSMutableDictionary *filePrefs = [self.class _typedPrefsFromFile];

    if (!filePrefs) {
        filePrefs = [NSMutableDictionary dictionaryWithDictionary:defaults];
        [filePrefs writeToFile:PREFS_PATH atomically:YES];
    }

    // 旧版配置迁移
    if (filePrefs[@"thermalControlMode"] == nil) {
        NSString *oldMode = filePrefs[@"thermalPowerMode"];
        if ([oldMode isEqualToString:@"low"] || [oldMode isEqualToString:@"lowPower"]) {
            filePrefs[@"thermalControlMode"] = @(ThermalControlModeLowPower);
        } else if ([oldMode isEqualToString:@"full"] || [oldMode isEqualToString:@"fullPower"]) {
            filePrefs[@"thermalControlMode"] = @(ThermalControlModeFullPower);
        }

        if (filePrefs[@"thermalControlMode"] == nil && [filePrefs[@"thermalUnlockEnabled"] boolValue]) {
            filePrefs[@"thermalControlMode"] = @(ThermalControlModeFullPower);
        }

        if (filePrefs[@"thermalControlMode"] == nil && [filePrefs[@"requireLowPowerMode"] boolValue]) {
            filePrefs[@"thermalControlMode"] = @(ThermalControlModeLowPower);
        }

        if (filePrefs[@"thermalControlMode"] == nil) {
            filePrefs[@"thermalControlMode"] = @(ThermalControlModeFullPower);
        }

        [filePrefs writeToFile:PREFS_PATH atomically:YES];
    }

    NSString *suiteName = @"com.huayuarc.cputhermal-prefs";
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    BOOL needsSync = NO;

    for (NSString *key in defaults) {
        id existingValue = [suiteDefaults objectForKey:key];
        if (existingValue) {
            NSNumber *expectedDefault = defaults[key];
            if (![existingValue isKindOfClass:[expectedDefault class]]) {
                id fileValue = filePrefs[key];
                [suiteDefaults setObject:fileValue ?: expectedDefault forKey:key];
                needsSync = YES;
            }
            continue;
        }

        id fileValue = filePrefs[key];
        if (fileValue) {
            [suiteDefaults setObject:fileValue forKey:key];
        } else {
            [suiteDefaults setObject:defaults[key] forKey:key];
        }
        needsSync = YES;
    }

    for (NSString *key in filePrefs) {
        if (defaults[key] != nil) continue;
        if (![suiteDefaults objectForKey:key]) {
            [suiteDefaults setObject:filePrefs[key] forKey:key];
            needsSync = YES;
        }
    }

    if (needsSync) {
        [suiteDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [suiteDefaults synchronize];
        });
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
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

    // 关键：不用 PSSegmentCell，代码手动接管运行模式选择器
    [self replaceSegmentCellWithCustomControl];
}

- (void)replaceSegmentCellWithCustomControl {
    for (NSInteger i = 0; i < _specifiers.count; i++) {
        PSSpecifier *spec = _specifiers[i];

        if ([spec.properties[@"key"] isEqualToString:@"thermalControlMode"]) {
            // 先删掉系统自带的 PSSegmentCell
            NSMutableArray *items = [_specifiers mutableCopy];
            [items removeObjectAtIndex:i];
            _specifiers = items;

            // 再插入一个自定义单元格，用来放我们自己的 UISegmentedControl
            PSSpecifier *customSpec = [PSSpecifier preferenceSpecifierNamed:@"运行模式"
                                                                     target:self
                                                                     set:@selector(setPreferenceValue:specifier:)
                                                                     get:@selector(readPreferenceValue:)
                                                                     detail:nil
                                                                     cell:PSGroupCell
                                                                     edit:nil];

            customSpec.properties[@"key"] = @"thermalControlMode";
            customSpec.properties[@"defaults"] = @"com.huayuarc.cputhermal-prefs";
            customSpec.properties[@"label"] = @"运行模式";
            customSpec.properties[@"footerText"] = @"低功耗：限制性能峰值，减缓发热，延长续航。解除温控：关闭降频策略，释放全部性能。";

            [items insertObject:customSpec atIndex:i];

            // 等页面渲染后，手动创建并插入 UISegmentedControl
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setupCustomModeSegment];
            });

            break;
        }
    }
}

- (void)setupCustomModeSegment {
    CGFloat segmentWidth = 260;
    CGFloat segmentHeight = 32;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;

    self.modeSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"低功耗", @"解除温控"]];
    self.modeSegmentControl.frame = CGRectMake((screenWidth - segmentWidth) / 2, 12, segmentWidth, segmentHeight);
    self.modeSegmentControl.selectedSegmentIndex = [self currentModeIndex];

    if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 16.0) {
        self.modeSegmentControl.selectedSegmentTintColor = [UIColor systemBlueColor];
    } else {
        self.modeSegmentControl.tintColor = [UIColor systemBlueColor];
    }

    [self.modeSegmentControl addTarget:self
                                 action:@selector(modeSegmentChanged:)
                       forControlEvents:UIControlEventValueChanged];

    // 直接插到 tableHeaderView，避免依赖 PSSegmentCell 的内部读取逻辑
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 56)];
    headerView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [headerView addSubview:self.modeSegmentControl];

    self.table.tableHeaderView = headerView;
}

- (NSInteger)currentModeIndex {
    NSString *suiteName = @"com.huayuarc.cputhermal-prefs";
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    NSInteger mode = [suiteDefaults integerForKey:@"thermalControlMode"];

    if (mode == ThermalControlModeLowPower) {
        return 0;
    }

    return 1;
}

- (void)modeSegmentChanged:(UISegmentedControl *)sender {
    NSInteger index = sender.selectedSegmentIndex;
    NSInteger mode = (index == 0) ? ThermalControlModeLowPower : ThermalControlModeFullPower;

    NSString *suiteName = @"com.huayuarc.cputhermal-prefs";
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    [suiteDefaults setInteger:mode forKey:@"thermalControlMode"];
    [suiteDefaults synchronize];

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[@"thermalControlMode"] = @(mode);
    [prefs writeToFile:PREFS_PATH atomically:YES];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kCPUthermalReloadNotification,
        NULL, NULL, YES
    );
    notify_post(kCPUthermalReloadNotifyName);

    NSLog(@"[CPUthermalPrefs] 运行模式已切换为：%ld", (long)mode);
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier.properties objectForKey:@"key"];
    id defaultValue = [specifier.properties objectForKey:@"default"];

    NSString *defaultsSuite = [specifier.properties objectForKey:@"defaults"];
    if (defaultsSuite && key) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
        id value = [defaults objectForKey:key];
        if (value) return value;
    }

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    id value = [prefs objectForKey:key];
    if (value) return value;

    return defaultValue;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier.properties objectForKey:@"key"];
    if (!key) return;

    NSString *defaultsSuite = [specifier.properties objectForKey:@"defaults"];
    if (defaultsSuite) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
        [defaults setObject:value forKey:key];
        [defaults synchronize];
    }

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    [prefs setObject:value forKey:key];
    [prefs writeToFile:PREFS_PATH atomically:YES];

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

static BOOL _userspaceReboot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *launchctlPath = nil;
    for (NSString *candidate in @[@"/usr/bin/launchctl", @"/bin/launchctl"]) {
        NSString *resolved = [NSString stringWithUTF8String:jbroot([candidate UTF8String])];
        if ([fm isExecutableFileAtPath:resolved]) {
            launchctlPath = resolved;
            break;
        }

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