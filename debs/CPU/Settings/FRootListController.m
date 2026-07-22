#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>
#import <CPUthermalThermalPrefs.h>
#import <CPUthermalMonitor.h>

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

- (void)restartThermalmonitord {
CPUthermalRestartThermalmonitordNow();
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return;
NSMutableDictionary *prefs = [self prefs];
prefs[key] = value;
[self savePrefs:prefs];
if ([key isEqualToString:S("enabled")] ||
[key isEqualToString:S("cpuProtection")]) {
[self applyThermalStatusOverrides];
}
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return nil;
id val = [self prefs][key];
if (val) return val;
if ([key isEqualToString:S("enabled")]) return [NSNumber numberWithBool:NO];
return [NSNumber numberWithBool:YES];
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

#pragma mark - 温控监控

- (void)resetThermalNotifications {
	NSMutableDictionary *prefs = [self prefs];
	prefs[S(kCPUthermalResetNotifKeyC)] = @YES;
	[self savePrefs:prefs];
	// 通过 CPUthermalTool 执行通知重置
	NSString *toolPath = CPUthermalToolPath();
	if (toolPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
		char *args[] = {"CPUthermalTool", "reset-thermal-notifications", NULL};
		CPUthermalSpawnRootDetached(toolPath, args);
	}
	// 立即杀死 thermalmonitord，无需等待其响应，launchd 会自动重启
	CPUthermalRestartThermalmonitordNow();
	// 弹出提示
	[self showSimpleAlertWithTitle:S("温控监控")
						   message:S("热通知级别已重置，thermalmonitord 重启中。")];
	// 重置完成后清除标记
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		NSMutableDictionary *prefs2 = [self prefs];
		[prefs2 removeObjectForKey:S(kCPUthermalResetNotifKeyC)];
		[self savePrefs:prefs2];
	});
}

- (void)showThermalState {
	// 拼接当前热状态文本
	CPUthermalPressureLevel pressure = CPUthermalPressure();
	CPUthermalNotifLevel notif = CPUthermalCurrentNotifLevel();
	float maxTemp = CPUthermalMaxTriggerTemperature();

	NSString *msg = [NSString stringWithFormat:S(
		"热压级别: %s (%d)\n"
		"通知级别: %s\n"
		"最大触发温度: %.1f°C"),
		CPUthermalPressureString(pressure), (int)pressure,
		CPUthermalNotifLevelString(notif, true),
		maxTemp];

	[self showSimpleAlertWithTitle:S("当前热状态") message:msg];
}

- (void)openPressureOverridePicker {
	UIAlertController *alert = [UIAlertController
		alertControllerWithTitle:S("热压覆盖")
		message:S("手动设定热压级别，thermalmonitord 将按此级别执行温控策略。\n设为 Nominal 可解除降频。")
		preferredStyle:UIAlertControllerStyleActionSheet];

	NSDictionary *levels = @{
		S("Nominal（正常）"):  @(kCPUthermalPressureNominal),
		S("Light（轻度）"):    @(kCPUthermalPressureLight),
		S("Moderate（中度）"): @(kCPUthermalPressureModerate),
		S("Heavy（重度）"):    @(kCPUthermalPressureHeavy),
		S("Trapping（抑制）"): @(kCPUthermalPressureTrapping),
		S("Sleeping（休眠）"): @(kCPUthermalPressureSleeping),
	};

	NSMutableDictionary *prefs = [self prefs];
	NSNumber *currentVal = prefs[S(kCPUthermalPressureOverrideKeyC)];
	int currentInt = currentVal ? [currentVal intValue] : 0;

	for (NSString *title in levels) {
		int val = [levels[title] intValue];
		UIAlertAction *action = [UIAlertAction actionWithTitle:title
			style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
				NSMutableDictionary *p = [self prefs];
				p[S(kCPUthermalPressureOverrideKeyC)] = @(val);
				p[S(kCPUthermalPressureOverrideEnabledKeyC)] = @YES;
				[self savePrefs:p];
				[self applyThermalStatusOverrides];
				// 通知 thermalmonitord 重载偏好
				notify_post(kCPUthermalMonitorNotifC);
				[self showSimpleAlertWithTitle:S("热压覆盖")
					message:[NSString stringWithFormat:S("热压已设为 %@ (值: %d)"), title, val]];
			}];
		if (val == currentInt) {
			[action setValue:@YES forKey:S("checked")];
		}
		[alert addAction:action];
	}

	// 如果当前启用了覆盖，添加"关闭覆盖"选项
	if (currentVal) {
		UIAlertAction *disableAction = [UIAlertAction actionWithTitle:S("关闭覆盖")
			style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
				NSMutableDictionary *p = [self prefs];
				[p removeObjectForKey:S(kCPUthermalPressureOverrideKeyC)];
				p[S(kCPUthermalPressureOverrideEnabledKeyC)] = @NO;
				[self savePrefs:p];
				[self applyThermalStatusOverrides];
				notify_post(kCPUthermalMonitorNotifC);
				CPUthermalResetPressure();
				[self showSimpleAlertWithTitle:S("热压覆盖") message:S("热压覆盖已关闭，恢复系统自动管理。")];
			}];
		[alert addAction:disableAction];
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

// ===================== 第2组: 核心保护（整合） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("屏蔽温度计通知") key:S("suppressThermalNotifications")]];

// ===================== 第3组: 温控监控（移植自 Battman 温控等级） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("温控监控") forKey:S("label")];
[group setProperty:S("读取和控制系统热压/通知级别，热压覆盖需 platform-application 权限。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("热压监控") key:S(kCPUthermalPressureMonitorKeyC)]];
[specs addObject:[self switchSpecifier:S("通知级别监控") key:S(kCPUthermalNotificationMonitorKeyC)]];
[specs addObject:[self buttonSpecifier:S("查看当前热状态")
action:@selector(showThermalState)
identifier:S("showThermalState")]];
[specs addObject:[self buttonSpecifier:S("热压覆盖")
action:@selector(openPressureOverridePicker)
identifier:S("pressureOverride")]];
[specs addObject:[self buttonSpecifier:S("重置热通知级别")
action:@selector(resetThermalNotifications)
identifier:S("resetNotifs")]];

// ===================== 第4组: 操作 =====================
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
