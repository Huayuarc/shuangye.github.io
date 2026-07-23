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

#pragma mark - 温控等级调校

- (NSString *)thermalPressureValue {
id val = [self prefs][S(kCPUthermalManualThermalPressureC)];
if (val) return [NSString stringWithFormat:S("%ld"), (long)[val integerValue]];
return [NSString stringWithFormat:S("%d"), kBattmanThermalPressureLevelNominal];
}

- (NSString *)thermalPressureLabel {
CPUthermalThermalPressure pressure = (CPUthermalThermalPressure)[[self thermalPressureValue] integerValue];
return [NSString stringWithFormat:S("热压力等级：%@"), CPUthermalPressureDisplayString(pressure)];
}

- (void)openThermalPressurePicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("热压力等级")
message:S("手动设置系统热压力级别，影响 CPU/GPU 降频策略、背光和无线充电行为。\n选择后立即生效，daemon 定时器保持该级别。")
preferredStyle:UIAlertControllerStyleActionSheet];

NSInteger currentPressure = [[self thermalPressureValue] integerValue];

for (NSInteger i = kBattmanThermalPressureLevelNominal; i <= kBattmanThermalPressureLevelSleeping; i++) {
NSString *title = S(CPUthermalPressureDisplayNames[i]);
UIAlertAction *action = [UIAlertAction actionWithTitle:title
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
// 保存偏好设置
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalPressureC)] = [NSNumber numberWithInteger:i];
// 选择热压力时，通知级别自动设为 Normal
prefs[S(kCPUthermalManualThermalNotifLevelC)] = [NSNumber numberWithInt:kBattmanThermalNotificationLevelNormal];
[self savePrefs:prefs];

// 立即生效 — 直接调用 notify API 设置热压力
CPUthermalSetThermalPressure((CPUthermalThermalPressure)i);
// 通知级别同步设为 Normal
CPUthermalSetThermalNotifLevel(kBattmanThermalNotificationLevelNormal);

// 刷新 UI
PSSpecifier *spec = [self specifierForID:S("thermalPressure")];
spec.name = [self thermalPressureLabel];
[self reloadSpecifierID:S("thermalPressure") animated:YES];
PSSpecifier *notifSpec = [self specifierForID:S("resetNotifLevel")];
notifSpec.name = [self detailedThermalNotifLevelLabel];
[self reloadSpecifierID:S("resetNotifLevel") animated:YES];
}];
if (i == currentPressure) [action setValue:@YES forKey:S("checked")];
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

#pragma mark - 通知级别显示（Battman 原版风格：显示原始数值）

- (NSString *)detailedThermalNotifLevelLabel {
CPUthermalEnsureThermalTokens();
CPUthermalThermalNotifLevel level = CPUthermalReadThermalNotifLevel();
NSString *displayName = CPUthermalNotifLevelDisplayString(level);

// 获取 OSThermalNotificationCurrentLevel 原始数值（如 Battman 原版显示 "Normal (0)"）
int rawValue = -1;
int (*currentLevel)(void) = CPUthermalSafeOSThermalNotificationCurrentLevel();
if (currentLevel) {
rawValue = currentLevel();
}

if (rawValue >= 0) {
return [NSString stringWithFormat:S("通知级别：%@ (%d)"), displayName, rawValue];
}
return [NSString stringWithFormat:S("通知级别：%@"), displayName];
}

#pragma mark - 重置通知级别（Battman 原版风格）

- (void)resetNotificationLevel {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("重置通知级别")
message:S("将热通知级别重置为 Normal，恢复系统默认背光/闪光灯限制？")
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("取消")
style:UIAlertActionStyleCancel handler:nil]];
[alert addAction:[UIAlertAction actionWithTitle:S("确定重置")
style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
// 保存 prefs
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalNotifLevelC)] = [NSNumber numberWithInt:kBattmanThermalNotificationLevelNormal];
[self savePrefs:prefs];

// 立即写入系统热通知级别（Battman 原版方式）
CPUthermalSetThermalNotifLevel(kBattmanThermalNotificationLevelNormal);

// 刷新 UI
PSSpecifier *spec = [self specifierForID:S("resetNotifLevel")];
spec.name = [self detailedThermalNotifLevelLabel];
[self reloadSpecifierID:S("resetNotifLevel") animated:YES];

[self showSimpleAlertWithTitle:S("已重置") message:S("通知级别已重置为 Normal。")];
}]];
[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 查看当前热状态（从 Battman 完整移植，仅保留热压力 + 通知级别）

- (NSString *)thermalStatusString {
CPUthermalEnsureThermalTokens();

// 读取热压力级别
CPUthermalThermalPressure pressure = CPUthermalReadThermalPressure();
NSString *pressureStr = CPUthermalPressureDisplayString(pressure);

// 读取热通知级别（使用 Battman 的 OSThermalNotificationCurrentLevel）
CPUthermalThermalNotifLevel notifLevel = CPUthermalReadThermalNotifLevel();

int rawValue = -1;
int (*currentLevel)(void) = CPUthermalSafeOSThermalNotificationCurrentLevel();
if (currentLevel) {
rawValue = currentLevel();
}
NSString *notifStr = CPUthermalNotifLevelDisplayString(notifLevel);

// 通知级别详情（带 Battman 原版数字格式）
NSString *notifDetail;
if (rawValue >= 0) {
notifDetail = [NSString stringWithFormat:S("%@ (%d)"), notifStr, rawValue];
} else {
notifDetail = notifStr;
}

return [NSString stringWithFormat:S("热压力：%@\n通知级别：%@"), pressureStr, notifDetail];
}

- (void)showThermalStatus {
NSString *status = [self thermalStatusString];
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("当前热状态")
message:status
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 功率模式

- (NSString *)powerModeValue {
id value = [self prefs][S("powerMode")];
if ([value isKindOfClass:[NSString class]]) return value;
return S("fullPower");
}

- (NSString *)powerModeTitle:(NSString *)mode {
if ([mode isEqualToString:S("lowPower")]) return S("低功耗");
return S("解除温控");
}

- (void)restartThermalmonitord {
CPUthermalRestartThermalmonitordSoon();
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
if ([key isEqualToString:S("thermalPressure")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self openThermalPressurePicker];
return;
}
if ([key isEqualToString:S("viewThermalStatus")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self showThermalStatus];
return;
}
if ([key isEqualToString:S("resetNotifLevel")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self resetNotificationLevel];
return;
}
}
[super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)showPowerModePicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("功率模式")
message:S("低功耗 = 限制 CPU 最高 2016MHz，不抬高待机频率\n解除温控 = 减少降频/降亮度，保留系统安全保护")
preferredStyle:UIAlertControllerStyleActionSheet];

NSString *currentMode = [self powerModeValue];
UIAlertAction *low = [UIAlertAction actionWithTitle:S("低功耗")
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[self savePowerMode:S("lowPower")];
}];
UIAlertAction *full = [UIAlertAction actionWithTitle:S("解除温控")
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

- (PSSpecifier *)thermalPressureSpecifier {
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:[self thermalPressureLabel]
target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:NULL];
[spec setIdentifier:S("thermalPressure")];
[spec setProperty:S("thermalPressure") forKey:S("key")];
[spec setButtonAction:@selector(openThermalPressurePicker)];
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
[group setProperty:S("低功耗只限制最高频率，不再强制锁 2016MHz；解除温控会减少降频/降亮度，但保留系统过热保护。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self powerModeSpecifier]];

// ===================== 第3组: 核心保护（整合） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[group setProperty:S("建议保持默认：CPU/亮度保护开启，避免误判温度。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("屏蔽高温通知") key:S("suppressThermalNotifications")]];

// ===================== 第4组: 温控等级调校（从 Battman 完整移植） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("温控等级调校") forKey:S("label")];
[group setProperty:S("温控等级控制默认启用，无需开关。\n热压力影响 CPU/GPU 降频策略；选择热压力时通知级别自动设为 Normal。\ndaemon 定时器每1秒自动 re-apply，无需重启。") forKey:S("footerText")];
[specs addObject:group];

// 热压力等级选择器（保留）
[specs addObject:[self thermalPressureSpecifier]];

// 通知级别显示行（Battman 原版风格：显示带原始数值的通知级别）
// 点击可重置通知级别
[specs addObject:[self buttonSpecifier:[self detailedThermalNotifLevelLabel]
action:@selector(resetNotificationLevel)
identifier:S("resetNotifLevel")]];

// 查看当前热状态
[specs addObject:[self buttonSpecifier:S("查看当前热状态")
action:@selector(showThermalStatus)
identifier:S("viewThermalStatus")]];

// ===================== 第5组: 操作 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("操作") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self buttonSpecifier:S("重启用户空间")
action:@selector(usreboot)
identifier:S("usreboot")]];

_specifiers = [specs copy];
}
return _specifiers;
}

@end
