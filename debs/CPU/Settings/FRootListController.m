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

- (NSString *)thermalLevelControlValue {
return [self prefs][S(kCPUthermalThermalLevelControlEnabledC)] ?: @NO;
}

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
message:S("手动设置系统热压力级别，影响 CPU/GPU 降频策略、背光和无线充电行为。\n修改后 daemon 定时器会自动应用，无需重启 thermalmonitord。")
preferredStyle:UIAlertControllerStyleActionSheet];

NSInteger currentPressure = [[self thermalPressureValue] integerValue];

for (NSInteger i = kBattmanThermalPressureLevelNominal; i <= kBattmanThermalPressureLevelSleeping; i++) {
NSString *title = S(CPUthermalPressureDisplayNames[i]);
UIAlertAction *action = [UIAlertAction actionWithTitle:title
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalPressureC)] = [NSNumber numberWithInteger:i];
[self savePrefs:prefs];
PSSpecifier *spec = [self specifierForID:S("thermalPressure")];
spec.name = [self thermalPressureLabel];
[self reloadSpecifierID:S("thermalPressure") animated:YES];
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

#pragma mark - 通知级别调校（从 Battman 完整移植）

- (NSString *)thermalNotifLevelValue {
id val = [self prefs][S(kCPUthermalManualThermalNotifLevelC)];
if (val) return [NSString stringWithFormat:S("%ld"), (long)[val integerValue]];
return [NSString stringWithFormat:S("%d"), kBattmanThermalNotificationLevelNormal];
}

- (NSString *)thermalNotifLevelLabel {
CPUthermalThermalNotifLevel level = (CPUthermalThermalNotifLevel)[[self thermalNotifLevelValue] integerValue];
return [NSString stringWithFormat:S("通知级别：%@"), CPUthermalNotifLevelDisplayString(level)];
}

- (void)openThermalNotifLevelPicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("热通知级别")
message:S("设置热通知级别后，系统会据此自动降低背光、限制闪光灯等。越高的级别限制越多。\n正常=无限制；设备重启=强制重启。")
preferredStyle:UIAlertControllerStyleActionSheet];

NSInteger currentLevel = [[self thermalNotifLevelValue] integerValue];

for (NSInteger i = kBattmanThermalNotificationLevelNormal; i <= kBattmanThermalNotificationLevelDeviceRestart; i++) {
NSString *title = S(CPUthermalNotifLevelDisplayNames[i]);
UIAlertAction *action = [UIAlertAction actionWithTitle:title
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalNotifLevelC)] = [NSNumber numberWithInteger:i];
[self savePrefs:prefs];
PSSpecifier *spec = [self specifierForID:S("thermalNotifLevel")];
spec.name = [self thermalNotifLevelLabel];
[self reloadSpecifierID:S("thermalNotifLevel") animated:YES];
}];
if (i == currentLevel) [action setValue:@YES forKey:S("checked")];
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

#pragma mark - 查看当前热状态（从 Battman 完整移植）

- (NSString *)thermalStatusString {
CPUthermalEnsureThermalTokens();

// 读取热压力级别
CPUthermalThermalPressure pressure = CPUthermalReadThermalPressure();
NSString *pressureStr = CPUthermalPressureDisplayString(pressure);

// 读取热通知级别（使用 Battman 的 OSThermalNotificationCurrentLevel）
CPUthermalThermalNotifLevel notifLevel = CPUthermalReadThermalNotifLevel();
NSString *notifStr = CPUthermalNotifLevelDisplayString(notifLevel);

// 读取最高触发温度（从 Battman 移植）
float maxTemp = CPUthermalReadMaxTriggerTemperature();
NSString *tempStr = (maxTemp >= 0)
? [NSString stringWithFormat:S("%.1f°C"), maxTemp]
: S("不可用");

// 读取阳光暴晒状态（从 Battman 移植）
int solarState = CPUthermalReadSolarState();
NSString *solarStr = solarState ? S("是") : S("否");

// 读取传感器最高温度
int sensorToken = 0;
uint64_t sensorVal = 0;
if (notify_register_check("com.apple.system.thermalpressure.pearl.pressure", &sensorToken) == 0) {
if (notify_get_state(sensorToken, &sensorVal) == 0) {
// 珍珠压力值也用了这个 key，值含义与主压力一致
}
notify_cancel(sensorToken);
}

NSString *airQualityStr = S("不可用");
int airToken = 0;
uint64_t airVal = 0;
if (notify_register_check("com.apple.system.thermalpressure.airaccount", &airToken) == 0) {
if (notify_get_state(airToken, &airVal) == 0) {
airQualityStr = airVal ? S("差") : S("好");
}
notify_cancel(airToken);
}

return [NSString stringWithFormat:S("热压力: %@\n通知级别: %@\n最高触发温度: %@\n阳光暴晒: %@\n空气质量: %@"),
pressureStr, notifStr, tempStr, solarStr, airQualityStr];
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

- (void)resetThermalLevels {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("重置温控")
message:S("将热压力重置为 Nominal（正常），通知级别重置为 Normal，并关闭温控等级控制开关？")
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("取消")
style:UIAlertActionStyleCancel handler:nil]];
[alert addAction:[UIAlertAction actionWithTitle:S("确定重置")
style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalPressureC)] = [NSNumber numberWithInt:kBattmanThermalPressureLevelNominal];
prefs[S(kCPUthermalManualThermalNotifLevelC)] = [NSNumber numberWithInt:kBattmanThermalNotificationLevelNormal];
prefs[S(kCPUthermalThermalLevelControlEnabledC)] = [NSNumber numberWithBool:NO];
[self savePrefs:prefs];

// 强制通知系统重置热状态
CPUthermalSetThermalPressure(kBattmanThermalPressureLevelNominal);
CPUthermalSetThermalNotifLevel(kBattmanThermalNotificationLevelNormal);

// 刷新 UI
PSSpecifier *pressureSpec = [self specifierForID:S("thermalPressure")];
pressureSpec.name = [self thermalPressureLabel];
[self reloadSpecifierID:S("thermalPressure") animated:YES];
PSSpecifier *notifSpec = [self specifierForID:S("thermalNotifLevel")];
notifSpec.name = [self thermalNotifLevelLabel];
[self reloadSpecifierID:S("thermalNotifLevel") animated:YES];
[self reloadSpecifierID:S(kCPUthermalThermalLevelControlEnabledC) animated:YES];

[self showSimpleAlertWithTitle:S("已重置") message:S("温控等级和通知级别已重置，开关已关闭。")];
}]];
[self presentViewController:alert animated:YES completion:nil];
}

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
if ([key isEqualToString:S("thermalNotifLevel")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self openThermalNotifLevelPicker];
return;
}
if ([key isEqualToString:S("viewThermalStatus")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self showThermalStatus];
return;
}
if ([key isEqualToString:S("resetThermalLevels")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self resetThermalLevels];
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

- (PSSpecifier *)thermalNotifLevelSpecifier {
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:[self thermalNotifLevelLabel]
target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:NULL];
[spec setIdentifier:S("thermalNotifLevel")];
[spec setProperty:S("thermalNotifLevel") forKey:S("key")];
[spec setButtonAction:@selector(openThermalNotifLevelPicker)];
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
[group setProperty:S("通过 notify API + _OSThermalNotification 私有框架设置系统热级别。\n热压力影响 CPU/GPU 降频策略；通知级别影响背光/闪光灯限制。\ndaemon 定时器每1秒自动 re-apply，无需重启。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("启用温控等级控制") key:S(kCPUthermalThermalLevelControlEnabledC)]];
[specs addObject:[self thermalPressureSpecifier]];
[specs addObject:[self thermalNotifLevelSpecifier]];

[specs addObject:[self buttonSpecifier:S("查看当前热状态")
action:@selector(showThermalStatus)
identifier:S("viewThermalStatus")]];

[specs addObject:[self buttonSpecifier:S("重置温控")
action:@selector(resetThermalLevels)
identifier:S("resetThermalLevels")]];

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
