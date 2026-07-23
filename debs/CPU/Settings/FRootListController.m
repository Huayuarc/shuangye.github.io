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

#pragma mark - 功率模式

- (NSString *)powerModeValue {
id value = [self prefs][S("powerMode")];
if ([value isKindOfClass:[NSString class]]) return value;
return S("fullPower");
}

- (CPUthermalThermalPressureLevel)thermalPressureValue {
	id value = [self prefs][S(kCPUthermalThermalPressureKeyC)];
	if ([value respondsToSelector:@selector(integerValue)]) {
		NSInteger pressure = [value integerValue];
		if (pressure >= kCPUthermalThermalPressureLevelNominal && pressure < kCPUthermalThermalPressureLevelUnknown) {
			return (CPUthermalThermalPressureLevel)pressure;
		}
	}
	return CPUthermalCurrentThermalPressureLevel();
}

- (NSString *)thermalPressureLabel {
	CPUthermalThermalPressureLevel pressure = [self thermalPressureValue];
	return [NSString stringWithFormat:S("热压级别：%@"), CPUthermalThermalPressureTitle(pressure)];
}

- (NSString *)thermalNotificationLabel {
	return [NSString stringWithFormat:S("通知等级：%@ · 重置"), CPUthermalThermalNotificationLabel()];
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
	[self reloadSpecifierID:S(kCPUthermalThermalPressureKeyC) animated:YES];
}

- (void)saveThermalPressure:(CPUthermalThermalPressureLevel)pressure {
	NSMutableDictionary *prefs = [self prefs];
	prefs[S(kCPUthermalThermalPressureKeyC)] = [NSNumber numberWithInteger:pressure];
	[self savePrefs:prefs];
	int ret = CPUthermalApplyThermalPressureLevelViaTool(pressure);
	notify_post(kCPUthermalThermalPressureChangedNotifC);
	PSSpecifier *specifier = [self specifierForID:S(kCPUthermalThermalPressureKeyC)];
	specifier.name = [self thermalPressureLabel];
	[self reloadSpecifierID:S(kCPUthermalThermalPressureKeyC) animated:YES];
	if (ret != 0) {
		[self showSimpleAlertWithTitle:S("提示") message:[NSString stringWithFormat:S("热压级别设置失败，错误码：%d"), ret]];
	}
}

- (void)resetThermalNotification {
	int ret = CPUthermalResetThermalNotificationViaTool();
	PSSpecifier *specifier = [self specifierForID:S(kCPUthermalThermalNotificationKeyC)];
	specifier.name = [self thermalNotificationLabel];
	[self reloadSpecifierID:S(kCPUthermalThermalNotificationKeyC) animated:YES];
	if (ret != 0) {
		[self showSimpleAlertWithTitle:S("提示") message:[NSString stringWithFormat:S("通知等级重置失败，错误码：%d"), ret]];
	}
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
	if ([key isEqualToString:S(kCPUthermalThermalPressureKeyC)]) {
		[tableView deselectRowAtIndexPath:indexPath animated:YES];
		[self showThermalPressurePicker];
		return;
	}
	if ([key isEqualToString:S(kCPUthermalThermalNotificationKeyC)]) {
		[tableView deselectRowAtIndexPath:indexPath animated:YES];
		[self resetThermalNotification];
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

- (void)showThermalPressurePicker {
	UIAlertController *alert = [UIAlertController
	alertControllerWithTitle:S("温控等级")
	message:S("选择后会立即写入系统热压状态，无需等待重启。严重/锁定/睡眠可能触发系统高温警告。")
	preferredStyle:UIAlertControllerStyleActionSheet];

	CPUthermalThermalPressureLevel currentPressure = [self thermalPressureValue];
	NSArray<NSNumber *> *levels = @[
		[NSNumber numberWithInteger:kCPUthermalThermalPressureLevelNominal],
		[NSNumber numberWithInteger:kCPUthermalThermalPressureLevelLight],
		[NSNumber numberWithInteger:kCPUthermalThermalPressureLevelModerate],
		[NSNumber numberWithInteger:kCPUthermalThermalPressureLevelHeavy],
		[NSNumber numberWithInteger:kCPUthermalThermalPressureLevelTrapping],
		[NSNumber numberWithInteger:kCPUthermalThermalPressureLevelSleeping]
	];

	for (NSNumber *number in levels) {
		CPUthermalThermalPressureLevel pressure = (CPUthermalThermalPressureLevel)[number integerValue];
		UIAlertActionStyle style = pressure >= kCPUthermalThermalPressureLevelHeavy ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
		UIAlertAction *action = [UIAlertAction actionWithTitle:CPUthermalThermalPressureTitle(pressure)
		style:style handler:^(UIAlertAction *selectedAction) {
			[self saveThermalPressure:pressure];
		}];
		if (pressure == currentPressure) {
			[action setValue:@YES forKey:S("checked")];
		}
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
	target:self
	set:NULL
	get:NULL
	detail:nil
	cell:PSButtonCell
	edit:nil];
	[spec setIdentifier:S(kCPUthermalThermalPressureKeyC)];
	[spec setProperty:S(kCPUthermalThermalPressureKeyC) forKey:S("key")];
	[spec setButtonAction:@selector(showThermalPressurePicker)];
	return spec;
}

- (PSSpecifier *)thermalNotificationSpecifier {
	PSSpecifier *spec = [PSSpecifier
	preferenceSpecifierNamed:[self thermalNotificationLabel]
	target:self
	set:NULL
	get:NULL
	detail:nil
	cell:PSButtonCell
	edit:nil];
	[spec setIdentifier:S(kCPUthermalThermalNotificationKeyC)];
	[spec setProperty:S(kCPUthermalThermalNotificationKeyC) forKey:S("key")];
	[spec setButtonAction:@selector(resetThermalNotification)];
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

// ===================== 第3组: 温控等级 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("温控等级") forKey:S("label")];
[group setProperty:S("热压级别：正常、轻微、中等、严重、锁定、睡眠。选择后立即执行并实时生效。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self thermalPressureSpecifier]];
[specs addObject:[self thermalNotificationSpecifier]];

// ===================== 第4组: 核心保护（整合） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[group setProperty:S("建议保持默认：CPU/亮度保护开启，避免误判温度。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("屏蔽高温通知") key:S("suppressThermalNotifications")]];

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