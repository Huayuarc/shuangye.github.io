#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

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

- (NSString *)powerModeValue {
id value = [self prefs][S("powerMode")];
if ([value isKindOfClass:[NSString class]]) return value;
return S("fullPower");
}

- (NSString *)powerModeTitle:(NSString *)mode {
if ([mode isEqualToString:S("lowPower")]) return S("低功耗");
return S("防温控");
}

- (void)restartThermalmonitord {
CPUthermalRestartThermalmonitordSoon();
}

#pragma mark - CPU频率锁定

- (NSString *)deviceLockValue {
NSString *val = [self prefs][S(kCPUthermalDeviceLockKeyC)];
if ([val isKindOfClass:[NSString class]] && val.length > 0) return val;
return S("");
}

- (NSString *)deviceLockLabel {
NSString *chipKey = [self deviceLockValue];
if (chipKey.length == 0) return S("CPU频率锁定：无");
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
prefs[S("powerMode")] = S("fullPower");
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
message:S("选择芯片代际后，CPU最高频率将被锁定为对应机型原生频率。\n锁定后自动切换为防温控模式。")
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
prefs[S("powerMode")] = mode ?: S("fullPower");
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
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return nil;
// 默认保留系统安全通路，避免异常发热、黑屏和不可恢复降亮度。
id val = [self prefs][key];
if (val) return val;
if ([key isEqualToString:S("suppressThermalNotifications")]) {
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
}
[super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)showPowerModePicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("功率模式")
message:S("低功耗 = 限制 CPU 最高 2016MHz，不抬高待机频率\n防温控 = 减少降频/降亮度，保留系统安全保护")
preferredStyle:UIAlertControllerStyleActionSheet];

NSString *currentMode = [self powerModeValue];
UIAlertAction *low = [UIAlertAction actionWithTitle:S("低功耗")
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[self savePowerMode:S("lowPower")];
}];
UIAlertAction *full = [UIAlertAction actionWithTitle:S("防温控")
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


#pragma mark - 关于我 / 投喂动作

// QQ 测试反馈群
- (void)openQQFeedbackGroup {
[self openURLString:S("https://qm.qq.com/q/JvllAQiEwI") fallback:nil];
}

// 支付宝投喂我
- (void)openAlipayDonate {
[self openURLString:S("alipays://platformapi/startapp?appId=20000067&url=https%3A%2F%2Fqr.alipay.com%2Ffkx16683ylwdrfdo8fiuy01")
fallback:S("https://qr.alipay.com/fkx16683ylwdrfdo8fiuy01")];
}

// 打开Sileo添加源（优先sileo://协议，否则打开网页）
- (void)openRepo {
[self openURLString:S("sileo://source/https://huayuarc.github.io") fallback:S("https://huayuarc.github.io")];
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

// ===================== 第1组: 总开关 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("CPUthermal") forKey:S("label")];
[specs addObject:group];

PSSpecifier *master = [self switchSpecifier:S("启用 CPUthermal") key:S("enabled")];
[specs addObject:master];

// ===================== 第2组: 功率模式 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("功率模式") forKey:S("label")];
[group setProperty:S("低功耗只限制最高频率，不再强制锁 2016MHz；防温控会减少降频/降亮度，但保留系统过热保护。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self powerModeSpecifier]];

// ===================== 第3组: CPU频率锁定 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("CPU频率锁定") forKey:S("label")];
[group setProperty:S("选择芯片代际后，CPU最高频率将被锁定为对应机型原生频率，阻止温控降频。选锁定时自动切换为防温控模式。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self deviceLockSpecifier]];

// ===================== 第4组: 核心保护（整合） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[group setProperty:S("建议保持默认：CPU/亮度保护开启，避免误判温度。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("屏蔽高温通知") key:S("suppressThermalNotifications")]];

// ===================== 第4组: 操作 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("操作") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self buttonSpecifier:S("重启用户空间")
action:@selector(usreboot)
identifier:S("usreboot")]];

// ===================== 第6组: 关于我 （底部） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("关于我 / 投喂") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self buttonSpecifier:S("📮 QQ 交流反馈群")
action:@selector(openQQFeedbackGroup)
identifier:S("qqGroup")]];
[specs addObject:[self buttonSpecifier:S("💰 支付宝🧧打赏")
action:@selector(openAlipayDonate)
identifier:S("alipayDonate")]];
[specs addObject:[self buttonSpecifier:S("📦 Sileo 添加源")
action:@selector(openRepo)
identifier:S("sileoRepo")]];

[self setSpecifiers:specs];
}
return _specifiers;
}

@end
