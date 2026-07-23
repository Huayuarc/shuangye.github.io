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
message:S("手动设置系统热压力级别，将影响 CPU/GPU 降频策略、背光和无线充电行为。\n修改后无需重启 thermalmonitord，daemon 定时器会自动应用。")
preferredStyle:UIAlertControllerStyleActionSheet];

NSInteger currentPressure = [[self thermalPressureValue] integerValue];

for (NSInteger i = kBattmanThermalPressureLevelNominal; i <= kBattmanThermalPressureLevelSleeping; i++) {
NSString *title = S(CPUthermalPressureDisplayNames[i]);
UIAlertAction *action = [UIAlertAction actionWithTitle:title
style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalPressureC)] = [NSNumber numberWithInteger:i];
[self savePrefs:prefs];
// 不重启 thermalmonitord — 定时器每1秒自动 re-apply
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

#pragma mark - 查看当前热状态

- (NSString *)thermalStatusString {
CPUthermalEnsureThermalTokens();
CPUthermalThermalPressure pressure = CPUthermalReadThermalPressure();

// 读取最大触发温度
float maxTemp = -1.0;
int maxTempToken = 0;
if (notify_register_check("com.apple.system.maxthermalsensorvalue", &maxTempToken) == 0) {
uint64_t tempState = 0;
if (notify_get_state(maxTempToken, &tempState) == 0) {
maxTemp = (float)tempState / 100.0f;
}
notify_cancel(maxTempToken);
}

// 读取阳光暴晒状态
int solarState = 0;
int solarToken = 0;
if (notify_register_check("com.apple.system.thermalsunlightstate", &solarToken) == 0) {
uint64_t solarLevel = 0;
if (notify_get_state(solarToken, &solarLevel) == 0) {
solarState = (int)solarLevel;
}
notify_cancel(solarToken);
}

NSString *pressureStr = CPUthermalPressureDisplayString(pressure);
NSString *tempStr = (maxTemp >= 0)
? [NSString stringWithFormat:S("%.1f°C"), maxTemp]
: S("不可用");
NSString *solarStr = solarState ? S("是") : S("否");

return [NSString stringWithFormat:S("热压力: %@\n最高触发温度: %@\n阳光暴晒: %@"),
pressureStr, tempStr, solarStr];
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
message:S("将热压力重置为 Nominal（正常），并关闭温控等级控制开关？")
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("取消")
style:UIAlertActionStyleCancel handler:nil]];
[alert addAction:[UIAlertAction actionWithTitle:S("确定重置")
style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
NSMutableDictionary *prefs = [self prefs];
prefs[S(kCPUthermalManualThermalPressureC)] = [NSNumber numberWithInt:kBattmanThermalPressureLevelNominal];
prefs[S(kCPUthermalThermalLevelControlEnabledC)] = [NSNumber numberWithBool:NO];
[self savePrefs:prefs];

// 强制通知系统重置热压力
CPUthermalSetThermalPressure(kBattmanThermalPressureLevelNominal);

// 刷新 UI
PSSpecifier *pressureSpec = [self specifierForID:S("thermalPressure")];
pressureSpec.name = [self thermalPressureLabel];
[self reloadSpecifierID:S("thermalPressure") animated:YES];
[self reloadSpecifierID:S(kCPUthermalThermalLevelControlEnabledC) animated:YES];

[self showSimpleAlertWithTitle:S("已重置") message:S("温控等级已重置为 Nominal，开关已关闭。")];
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
return S("防温控");
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
[group setProperty:S("低功耗只限制最高频率，不再强制锁 2016MHz；防温控会减少降频/降亮度，但保留系统过热保护。") forKey:S("footerText")];
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

// ===================== 第4组: 温控等级调校（从 Battman 移植） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("温控等级调校") forKey:S("label")];
[group setProperty:S("通过 notify API 直接设置系统热压力级别，覆盖 thermalmonitord 默认行为。谨慎使用，不当设置可能导致异常发热或性能下降。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("启用温控等级控制") key:S(kCPUthermalThermalLevelControlEnabledC)]];
[specs addObject:[self thermalPressureSpecifier]];

[specs addObject:[self buttonSpecifier:S("📊 查看当前热状态")
action:@selector(showThermalStatus)
identifier:S("viewThermalStatus")]];
[specs addObject:[self buttonSpecifier:S("🔄 重置温控")
action:@selector(resetThermalLevels)
identifier:S("resetThermalLevels")]];

// ===================== 第5组: 操作 =====================
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
