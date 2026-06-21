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
    return [self prefs][key] ?: [NSNumber numberWithBool:NO];
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

- (void)notifyReload {
    notify_post(kNotifNameC);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:S("已发送通知")
        message:S("Darwin 通知已发出，thermalmonitord 收到后会重载配置。\n完整生效需重启 thermalmonitord。")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S("好") style:UIAlertActionStyleDefault handler:nil]];
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

        // ===================== 第2组: IOKit 层 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("IOKit 层防护") forKey:S("label")];
        [group setProperty:S("拦截传感器读写、降频操作、属性写入") forKey:S("footerText")];
        [specs addObject:group];

        [specs addObject:[self switchSpecifier:S("阻止 CPU 降频") key:S("blockCPUMitigation")]];
        [specs addObject:[self switchSpecifier:S("阻止亮度降低") key:S("blockBrightness")]];
        [specs addObject:[self switchSpecifier:S("强制 Nominal 热状态") key:S("forceNominalState")]];
        [specs addObject:[self switchSpecifier:S("阻止 HID 温度事件") key:S("blockHidEvents")]];

        // ===================== 第3组: ObjC 层 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("ObjC 层防护") forKey:S("label")];
        [group setProperty:S("钩住 thermalmonitord 内部类决策方法") forKey:S("footerText")];
        [specs addObject:group];

        [specs addObject:[self switchSpecifier:S("阻止 ObjC 热缓解动作") key:S("blockObjCHooks")]];
        [specs addObject:[self switchSpecifier:S("阻止决策树评估") key:S("blockDecisionTree")]];
        [specs addObject:[self switchSpecifier:S("阻止热压力升级") key:S("blockThermalPressure")]];
        [specs addObject:[self switchSpecifier:S("覆盖强制热级别") key:S("overrideForceLevel")]];

        // ===================== 第4组: 精细控制 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("精细控制") forKey:S("label")];
        [group setProperty:S("控制力度、配置表等高级选项") forKey:S("footerText")];
        [specs addObject:group];

        [specs addObject:[self switchSpecifier:S("软化控制力度（减半）") key:S("softenControlEffort")]];
        [specs addObject:[self switchSpecifier:S("修改热配置表（+5°C）") key:S("modifyConfig")]];
        [specs addObject:[self switchSpecifier:S("修补热配置 plist") key:S("patchThermalPlist")]];
        [specs addObject:[self switchSpecifier:S("保留 CPMS 紧急保护") key:S("keepCPMSAlive")]];

        // ===================== 第5组: 操作 =====================
        group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:S("操作") forKey:S("label")];
        [specs addObject:group];

        PSSpecifier *reloadBtn = [PSSpecifier
            preferenceSpecifierNamed:S("发送通知重载设置")
            target:self set:NULL get:NULL detail:NULL cell:PSButtonCell edit:NULL];
        [reloadBtn setButtonAction:@selector(notifyReload)];
        [reloadBtn setIdentifier:S("reload")];
        [specs addObject:reloadBtn];

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
