#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>
#import "PowercuffManager.h"

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (NSString *)prefPath {
return CPUthermalCurrentPrefPath();
}

- (NSString *)legacyPrefPath {
NSArray<NSString *> *paths = CPUthermalLegacyPrefPaths();
return paths.count > 0 ? paths[0] : nil;
}

- (void)ensurePrefsDirectory {
NSString *directory = [[self prefPath] stringByDeletingLastPathComponent];
[[NSFileManager defaultManager] createDirectoryAtPath:directory
withIntermediateDirectories:YES
attributes:nil
error:nil];
}

- (void)migrateLegacyPrefsIfNeeded {
CPUthermalReadPrefs();
}

- (NSMutableDictionary *)prefs {
NSMutableDictionary *d = CPUthermalReadMutablePrefs();
if (!d) d = [NSMutableDictionary dictionary];
return d;
}

- (void)savePrefs:(NSMutableDictionary *)prefs {
CPUthermalWritePrefs(prefs);
notify_post(kCPUthermalSettingsChangedNotifC);
}

- (void)applyThermalStatusOverrides {
NSString *toolPath = CPUthermalToolPath();
if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
char *args[] = {"CPUthermalTool", "apply-thermal-overrides", NULL};
CPUthermalSpawnRootDetached(toolPath, args);
}
}

- (NSString *)powerModeValue {
id value = [self prefs][S("powerMode")];
if ([value isKindOfClass:[NSString class]]) return value;
return S("lowPower");
}

- (NSString *)powerModeTitle:(NSString *)mode {
if ([mode isEqualToString:S("lowPower")]) return S("稳帧降温");
return S("极限防温控");
}

- (void)restartThermalmonitord {
CPUthermalRestartThermalmonitordSoon();
}

#pragma mark - Powercuff 热模拟

- (BOOL)powercuffEnabled {
    return [[self prefs][S("powercuffEnabled")] boolValue];
}

- (NSString *)powercuffLevel {
    NSString *level = [self prefs][S("powercuffLevel")];
    if ([level isKindOfClass:[NSString class]] && level.length > 0) return level;
    return S("moderate");
}

- (NSString *)powercuffLevelLabel {
    NSString *level = [self powercuffLevel];
    if ([level isEqualToString:S("light")]) return S("轻度");
    if ([level isEqualToString:S("moderate")]) return S("中度（推荐）");
    if ([level isEqualToString:S("heavy")]) return S("重度");
    return S("中度（推荐）");
}

- (NSString *)powercuffStatusLabel {
    if (![self powercuffEnabled]) return S("热模拟：关闭");
    return [NSString stringWithFormat:S("热模拟：%@ - %@"), [self powercuffLevelLabel], S("已启用")];
}

- (void)savePowercuffEnabled:(BOOL)enabled {
    NSMutableDictionary *prefs = [self prefs];
    prefs[S("powercuffEnabled")] = [NSNumber numberWithBool:enabled];
    if (enabled && ![prefs[S("powercuffLevel")] isKindOfClass:[NSString class]]) {
        prefs[S("powercuffLevel")] = S("moderate");
    }
    [self savePrefs:prefs];
    [self restartThermalmonitord];
}

- (void)savePowercuffLevel:(NSString *)level {
    NSMutableDictionary *prefs = [self prefs];
    prefs[S("powercuffLevel")] = level ?: S("moderate");
    prefs[S("powercuffEnabled")] = [NSNumber numberWithBool:YES];
    [self savePrefs:prefs];
    [self restartThermalmonitord];
    PSSpecifier *spec = [self specifierForID:S("powercuffLevel")];
    if (spec) {
        spec.name = [self powercuffStatusLabel];
        [self reloadSpecifierID:S("powercuffLevel") animated:YES];
    }
}

- (void)openPowercuffLevelPicker {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:S("热模拟级别")
        message:S("模拟 CPU 热状态来触发系统降频省电。\n\n轻度 = 轻微降频\n中度 = 明显省电，日常使用推荐\n重度 = 大幅度降频，可能影响流畅度\n\n关闭即不启用热模拟，仅用 CPUthermal 的 IOKit 拦截。")
        preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *current = [self powercuffLevel];
    BOOL enabled = [self powercuffEnabled];

    NSArray *levels = @[S("light"), S("moderate"), S("heavy")];
    NSArray *labels = @[S("轻度"), S("中度（推荐）"), S("重度")];
    for (NSUInteger i = 0; i < levels.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:labels[i]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self savePowercuffLevel:levels[i]];
            }];
        if (enabled && [current isEqualToString:levels[i]]) {
            [action setValue:@YES forKey:S("checked")];
        }
        [alert addAction:action];
    }

    UIAlertAction *offAction = [UIAlertAction actionWithTitle:S("关闭")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self savePowercuffEnabled:NO];
        }];
    if (!enabled) [offAction setValue:@YES forKey:S("checked")];
    [alert addAction:offAction];

    [alert addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = self.view.bounds;
        popover.permittedArrowDirections = 0;
    }
    [self presentViewController:alert animated:YES completion:nil];
}


#pragma mark - CPU频率锁定

- (NSString *)deviceLockValue {
NSString *val = [self prefs][S(kCPUthermalDeviceLockKeyC)];
if ([val isKindOfClass:[NSString class]] && val.length > 0) return val;
return S("");
}

- (NSString *)deviceLockLabel {
NSString *chipKey = [self deviceLockValue];
if (chipKey.length == 0) return S("CPU频率锁定：无锁定（自动）");
return [NSString stringWithFormat:S("CPU频率锁定：%@"), CPUthermalChipDisplayName(chipKey)];
}

- (void)openDeviceLockPicker {
[self showDeviceLockPicker];
}

- (void)saveDeviceLock:(NSString *)chipKey {
NSMutableDictionary *prefs = [self prefs];
if (chipKey.length > 0) {
prefs[S(kCPUthermalDeviceLockKeyC)] = chipKey;
} else {
[prefs removeObjectForKey:S(kCPUthermalDeviceLockKeyC)];
}
prefs[S("powerMode")] = S("lowPower");
[self savePrefs:prefs];
notify_post(kCPUthermalPowerModeChangedNotifC);
[self restartThermalmonitord];
PSSpecifier *specifier = [self specifierForID:S("deviceLock")];
specifier.name = [self deviceLockLabel];
[self reloadSpecifierID:S("deviceLock") animated:YES];
}

- (void)showDeviceLockPicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("CPU频率锁定")
message:S("选择芯片代际后，稳帧模式会把 CPU 上限限制在更凉的范围内；极限防温控模式才会尝试维持原生高频。")
preferredStyle:UIAlertControllerStyleActionSheet];

NSString *currentKey = [self deviceLockValue];

// 无锁定
UIAlertAction *noneAction = [UIAlertAction actionWithTitle:S("无锁定（自动）")
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[self saveDeviceLock:S("")];
}];
if (currentKey.length == 0) [noneAction setValue:@YES forKey:S("checked")];
[alert addAction:noneAction];

// A11 ~ A17 Pro
NSArray *chipKeys = @[S("A11"), S("A12"), S("A13"), S("A14"), S("A15"), S("A16"), S("A17Pro")];
for (NSString *key in chipKeys) {
UIAlertAction *action = [UIAlertAction actionWithTitle:CPUthermalChipDisplayName(key)
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[self saveDeviceLock:key];
}];
if ([key isEqualToString:currentKey]) [action setValue:@YES forKey:S("checked")];
[alert addAction:action];
}

[alert addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];

UIPopoverPresentationController *popover = alert.popoverPresentationController;
if (popover) {
popover.sourceView = self.view;
popover.sourceRect = self.view.bounds;
popover.permittedArrowDirections = 0;
}
[self presentViewController:alert animated:YES completion:nil];
}

- (void)savePowerMode:(NSString *)mode {
NSMutableDictionary *prefs = [self prefs];
prefs[S("powerMode")] = mode ?: S("lowPower");
[self savePrefs:prefs];
notify_post(kCPUthermalPowerModeChangedNotifC);
[self restartThermalmonitord];
PSSpecifier *specifier = [self specifierForID:S("powerMode")];
specifier.name = [self powerModeLabel];
[self reloadSpecifierID:S("powerMode") animated:YES];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return;
NSMutableDictionary *prefs = [self prefs];
prefs[key] = value;
[self savePrefs:prefs];
if ([key isEqualToString:S("enabled")] ||
[key isEqualToString:S(kCPUthermalDisableHotInPocketKeyC)] ||
[key isEqualToString:S(kCPUthermalLockSunlightExposureKeyC)]) {
[self applyThermalStatusOverrides];
}
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return nil;
id val = [self prefs][key];
if (val) return val;
if ([key isEqualToString:S("enabled")]) return [NSNumber numberWithBool:NO];
if ([key isEqualToString:S("powercuffEnabled")]) return [NSNumber numberWithBool:NO];
if ([key isEqualToString:S(kCPUthermalDisableHotInPocketKeyC)] ||
[key isEqualToString:S(kCPUthermalLockSunlightExposureKeyC)]) {
return [NSNumber numberWithBool:NO];
}
return [NSNumber numberWithBool:YES];
}

- (id)readPowerModeValue:(PSSpecifier *)spec {
return [self powerModeLabel];
}

- (NSString *)powerModeLabel {
return [NSString stringWithFormat:S("功率模式：%@"), [self powerModeTitle:[self powerModeValue]]];
}

- (void)openPowerModePicker {
[self showPowerModePicker];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
NSInteger index = [self indexForIndexPath:indexPath];
if (index >= 0 && index < (NSInteger)self.specifiers.count) {
PSSpecifier *specifier = self.specifiers[index];
NSString *key = [specifier propertyForKey:S("key")];
if ([key isEqualToString:S("powerMode")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self showPowerModePicker];
return;
}
if ([key isEqualToString:S("deviceLock")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self showDeviceLockPicker];
return;
}
if ([key isEqualToString:S("powercuffLevel")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self openPowercuffLevelPicker];
return;
}
}
[super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)showPowerModePicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("功率模式")
message:S("稳帧降温 = 限制 CPU 最高 1800MHz 并限制 GPU 峰值，减少发热后卡顿\n极限防温控 = 性能优先，可能明显发热，仅短时间使用")
preferredStyle:UIAlertControllerStyleActionSheet];

NSString *currentMode = [self powerModeValue];
UIAlertAction *low = [UIAlertAction actionWithTitle:S("稳帧降温")
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[self savePowerMode:S("lowPower")];
}];
UIAlertAction *full = [UIAlertAction actionWithTitle:S("极限防温控")
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[self savePowerMode:S("fullPower")];
}];
if ([currentMode isEqualToString:S("lowPower")]) {
[low setValue:@YES forKey:S("checked")];
} else {
[full setValue:@YES forKey:S("checked")];
}

[alert addAction:low];
[alert addAction:full];
[alert addAction:[UIAlertAction actionWithTitle:S("取消") style:UIAlertActionStyleCancel handler:nil]];

UIPopoverPresentationController *popover = alert.popoverPresentationController;
if (popover) {
popover.sourceView = self.view;
popover.sourceRect = self.view.bounds;
popover.permittedArrowDirections = 0;
}
[self presentViewController:alert animated:YES completion:nil];
}


#pragma mark - 工具方法

- (void)openURLString:(NSString *)urlString fallback:(NSString *)fallbackURL {
[self openURLString:urlString fallback:fallbackURL failureMessage:nil];
}

- (void)openURLString:(NSString *)urlString fallback:(NSString *)fallbackURL failureMessage:(NSString *)failureMessage {
NSURL *url = [NSURL URLWithString:urlString];
if (!url) return;

[[UIApplication sharedApplication] openURL:url
options:[NSDictionary dictionary]
completionHandler:^(BOOL success) {
if (success) return;
if (fallbackURL) {
NSURL *fallback = [NSURL URLWithString:fallbackURL];
if (fallback) {
[[UIApplication sharedApplication] openURL:fallback options:[NSDictionary dictionary] completionHandler:nil];
return;
}
}
if (failureMessage) {
[self showSimpleAlertWithTitle:S("提示") message:failureMessage];
}
}];
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:title
message:message
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
}


#pragma mark - 重启用户空间

- (void)usreboot {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("重启用户空间")
message:S("重启 SpringBoard 和所有用户态进程？")
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("取消")
style:UIAlertActionStyleCancel handler:nil]];
[alert addAction:[UIAlertAction actionWithTitle:S("确定重启")
style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
pid_t pid = 0;
NSString *toolPath = CPUthermalToolPath();
if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
char *args[] = {"CPUthermalTool", "userspace-reboot", NULL};
if (posix_spawn(&pid, [toolPath fileSystemRepresentation], NULL, NULL, args, NULL) == 0) {
waitpid(pid, NULL, 0);
return;
}
}

NSString *launchctlPath = CPUthermalLaunchctlPath();
if (launchctlPath.length > 0) {
char *args[] = {"launchctl", "reboot", "userspace", NULL};
posix_spawn(&pid, [launchctlPath fileSystemRepresentation], NULL, NULL, args, NULL);
waitpid(pid, NULL, 0);
}
}]];
[self presentViewController:alert animated:YES completion:nil];
}


#pragma mark - Specifier 构建

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

- (PSSpecifier *)powerModeSpecifier {
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:[self powerModeLabel]
target:self
set:NULL
get:NULL
detail:nil
cell:PSButtonCell
edit:nil];
[spec setIdentifier:S("powerMode")];
[spec setProperty:S("powerMode") forKey:S("key")];
[spec setButtonAction:@selector(openPowerModePicker)];
return spec;
}

- (PSSpecifier *)deviceLockSpecifier {
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:[self deviceLockLabel]
target:self
set:NULL
get:NULL
detail:nil
cell:PSButtonCell
edit:nil];
[spec setIdentifier:S("deviceLock")];
[spec setProperty:S("deviceLock") forKey:S("key")];
[spec setButtonAction:@selector(openDeviceLockPicker)];
return spec;
}

- (PSSpecifier *)powercuffLevelSpecifier {
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:[self powercuffStatusLabel]
target:self
set:NULL
get:NULL
detail:nil
cell:PSButtonCell
edit:nil];
[spec setIdentifier:S("powercuffLevel")];
[spec setProperty:S("powercuffLevel") forKey:S("key")];
[spec setButtonAction:@selector(openPowercuffLevelPicker)];
return spec;
}

- (PSSpecifier *)buttonSpecifier:(NSString *)label action:(SEL)action identifier:(NSString *)identifier {
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:label
target:self set:NULL get:NULL detail:NULL cell:PSButtonCell edit:NULL];
[spec setButtonAction:action];
[spec setIdentifier:identifier];
return spec;
}

- (NSArray *)specifiers {
if (!_specifiers) {
NSMutableArray *specs = [NSMutableArray array];
PSSpecifier *group = nil;

group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("CPU 去温控") forKey:S("label")];
[specs addObject:group];

PSSpecifier *master = [self switchSpecifier:S("启用 CPU 去温控") key:S("enabled")];
[specs addObject:master];

// ===================== 第2组: 功率模式 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("功率模式") forKey:S("label")];
[group setProperty:S("默认稳帧降温，优先降低发热和长期卡顿；极限防温控会提高功耗和温度，仅建议短时间测试。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self powerModeSpecifier]];

// ===================== Powercuff: 热模拟 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("Powercuff 热模拟") forKey:S("label")];
[group setProperty:S("模拟 CPU 热状态来触发系统降频省电。配合低功耗模式使用效果更佳。需要依赖 thermalmonitord。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("启用热模拟") key:S("powercuffEnabled")]];
[specs addObject:[self powercuffLevelSpecifier]];

// ===================== 第3组: CPU频率锁定 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("CPU频率锁定") forKey:S("label")];
[group setProperty:S("默认无锁定（自动）。选择芯片代际仅作为频率参考；稳帧降温模式仍会限制上限，避免游戏持续发热后掉帧。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self deviceLockSpecifier]];

// ===================== 第4组: 环境状态 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("环境状态") forKey:S("label")];
[group setProperty:S("口袋过热 (Hot-in-Pocket) 保护在屏幕关闭且不播放任何媒体时自动降低 CPU 与 GPU活动，避免设备在口袋中积热。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("禁用口袋高温") key:S(kCPUthermalDisableHotInPocketKeyC)]];
[specs addObject:[self switchSpecifier:S("锁定阳光暴晒") key:S(kCPUthermalLockSunlightExposureKeyC)]];

// ===================== 第5组: 核心保护（整合） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("屏蔽温度计通知") key:S("suppressThermalNotifications")]];

// ===================== 第6组: 操作 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("操作") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self buttonSpecifier:S("重启用户空间")
action:@selector(usreboot)
identifier:S("usreboot")]];

[self setSpecifiers:specs];
}
return _specifiers;
}

@end
