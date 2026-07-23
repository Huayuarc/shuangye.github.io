#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

static const char *kPrefPathC  = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kNotifNameC = "com.huayuarc.CPUthermal/settingsChanged";

// 动态创建 NSString 的辅助宏 — 避免编译期 __cfstring
#define S(str) [NSString stringWithUTF8String:(str)]

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (NSMutableDictionary *)prefs {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:S(kPrefPathC)];
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

- (void)savePrefs:(NSMutableDictionary *)prefs {
    [prefs writeToFile:S(kPrefPathC) atomically:YES];
    notify_post(kNotifNameC);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return;
    NSMutableDictionary *prefs = [self prefs];
    prefs[key] = value;
    [self savePrefs:prefs];
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return nil;
    id val = [self prefs][key];
    if (val) return val;
    if ([key isEqualToString:S("keepCPMSAlive")]) {
        return [NSNumber numberWithBool:NO]; // CPMS 默认关闭
    }
    if ([key isEqualToString:S("powerMode")]) {
        return @0; // 功率模式默认: 正常(0)
    }
    return [NSNumber numberWithBool:YES]; // 其余保护默认开启
}

- (void)usreboot {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:S("重启用户空间")
        message:S("重启 SpringBoard 和所有用户态进程？")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S("取消")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:S("确定重启")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            pid_t pid;
            char *args[] = {"launchctl", "reboot", "userspace", NULL};
            posix_spawn(&pid, "/var/jb/usr/bin/launchctl", NULL, NULL, args, NULL);
            waitpid(pid, NULL, 0);
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (PSSpecifier *)switchSpecifier:(NSString *)label key:(NSString *)key {
    PSSpecifier *spec = [PSSpecifier
        preferenceSpecifierNamed:label
        target:self
        set:@selector(setPreferenceValue:specifier:)
        get:@selector(readPreferenceValue:)
        detail:nil
        cell:PSSwitchCell
        edit:nil];
    [spec setIdentifier:key];
    [spec setProperty:key forKey:S("key")];
    return spec;
}

- (PSSpecifier *)segmentSpecifier:(NSString *)label key:(NSString *)key
                         titles:(NSArray *)titles values:(NSArray *)values {
    PSSpecifier *spec = [PSSpecifier
        preferenceSpecifierNamed:(label ?: S(""))
        target:self
        set:@selector(setPreferenceValue:specifier:)
        get:@selector(readPreferenceValue:)
        detail:nil
        cell:PSSegmentCell
        edit:nil];
    [spec setIdentifier:key];
    [spec setProperty:key forKey:S("key")];
    [spec setProperty:titles forKey:S("segmentTitles")];
    [spec setProperty:values forKey:S("segmentValues")];
    // 设置 segment 宽度
    [spec setProperty:@(0) forKey:S("alternateBackgroundColor")];
    return spec;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = nil;

        // ===================== 第1组: 总开关 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("CPUthermal") forKey:S("label")];
        [specs addObject:group];

        PSSpecifier *master = [self switchSpecifier:S("启用 CPUthermal") key:S("enabled")];
        [specs addObject:master];

        // ===================== 第2组: 功率模式 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("功率模式") forKey:S("label")];
        [group setProperty:S("正常: 使用下方独立开关\n解除温控: 强制开启所有保护，完全阻止降频降亮度\n低功耗: 模拟低电量，限制 CPU 频率约 70%") forKey:S("footerText")];
        [specs addObject:group];

        PSSpecifier *powerMode = [self segmentSpecifier:nil key:S("powerMode")
            titles:@[S("正常"), S("解除温控"), S("低功耗")]
            values:@[@0, @1, @2]];
        [specs addObject:powerMode];

        // ===================== 第3组: 核心保护（整合） =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("核心保护") forKey:S("label")];
        [group setProperty:S("功率模式设为「正常」时，以下开关独立控制\n功率模式为非正常时，以下开关被模式覆盖") forKey:S("footerText")];
        [specs addObject:group];

        [specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
        [specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
        [specs addObject:[self switchSpecifier:S("热状态封锁") key:S("thermalStateProtection")]];
        [specs addObject:[self switchSpecifier:S("阻止 HID 温度事件") key:S("blockHidEvents")]];

        // ===================== 第4组: 高级 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("高级") forKey:S("label")];
        [group setProperty:S("保留 CPMS 紧急保护安全阀，温度超过 100°C 时放行所有保护") forKey:S("footerText")];
        [specs addObject:group];

        [specs addObject:[self switchSpecifier:S("保留 CPMS 紧急保护") key:S("keepCPMSAlive")]];

        // ===================== 第5组: 操作 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("操作") forKey:S("label")];
        [specs addObject:group];

        PSSpecifier *rebootBtn = [PSSpecifier
            preferenceSpecifierNamed:S("重启用户空间")
            target:self set:NULL get:NULL detail:NULL cell:PSButtonCell edit:NULL];
        [rebootBtn setButtonAction:@selector(usreboot)];
        [rebootBtn setIdentifier:S("usreboot")];
        [specs addObject:rebootBtn];

        [self setSpecifiers:specs];
    }
    return _specifiers;
}

@end
