#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

static const char *kPrefRelativePathC = "Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kLegacyPrefPathC = "/var/mobile/Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kNotifNameC = "com.huayuarc.CPUthermal/settingsChanged";
static const char *kPowerModeNotifNameC = "com.huayuarc.CPUthermal/powerModeChanged";

// 动态创建 NSString 的辅助宏 — 避免编译期 __cfstring
#define S(str) [NSString stringWithUTF8String:(str)]

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (NSString *)prefPath {
NSString *resolvedJBRoot = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
if (resolvedJBRoot) {
return [resolvedJBRoot stringByAppendingPathComponent:S(kPrefRelativePathC)];
}
return [S("/var/jb") stringByAppendingPathComponent:S(kPrefRelativePathC)];
}

- (NSString *)legacyPrefPath {
return S(kLegacyPrefPathC);
}

- (void)ensurePrefsDirectory {
NSString *directory = [[self prefPath] stringByDeletingLastPathComponent];
[[NSFileManager defaultManager] createDirectoryAtPath:directory
withIntermediateDirectories:YES
attributes:nil
error:nil];
}

- (void)migrateLegacyPrefsIfNeeded {
NSFileManager *fileManager = [NSFileManager defaultManager];
NSString *prefPath = [self prefPath];
if ([fileManager fileExistsAtPath:prefPath]) return;

NSString *legacyPath = [self legacyPrefPath];
NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
if (!legacyPrefs) return;

[self ensurePrefsDirectory];
if ([legacyPrefs writeToFile:prefPath atomically:YES]) {
[fileManager removeItemAtPath:legacyPath error:nil];
}
}

- (NSMutableDictionary *)prefs {
[self migrateLegacyPrefsIfNeeded];
NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:[self prefPath]];
if (!d) d = [NSMutableDictionary dictionary];
return d;
}

- (void)savePrefs:(NSMutableDictionary *)prefs {
[self ensurePrefsDirectory];
[prefs writeToFile:[self prefPath] atomically:YES];
[[NSFileManager defaultManager] removeItemAtPath:[self legacyPrefPath] error:nil];
notify_post(kNotifNameC);
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
pid_t pid;
char *args[] = {"killall", "-q", "thermalmonitord", NULL};
const char *paths[] = {"/var/jb/usr/bin/killall", "/usr/bin/killall", NULL};
for (int i = 0; paths[i]; i++) {
if ([[NSFileManager defaultManager] fileExistsAtPath:S(paths[i])]) {
if (posix_spawn(&pid, paths[i], NULL, NULL, args, NULL) == 0) {
waitpid(pid, NULL, 0);
}
return;
}
}
}

- (void)savePowerMode:(NSString *)mode {
NSMutableDictionary *prefs = [self prefs];
prefs[S("powerMode")] = mode ?: S("fullPower");
[self savePrefs:prefs];
notify_post(kPowerModeNotifNameC);
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
// CPU性能保护/亮度保护/热状态封锁/HID事件 默认开启
id val = [self prefs][key];
if (val) return val;
if ([key isEqualToString:S("keepCPMSAlive")]) {
return [NSNumber numberWithBool:NO]; // CPMS 默认关闭
}
return [NSNumber numberWithBool:YES]; // 其余保护默认开启
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
if ([[specifier propertyForKey:S("key")] isEqualToString:S("powerMode")]) {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self showPowerModePicker];
return;
}
}
[super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)showPowerModePicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("功率模式")
message:S("低功耗 = 省电并限制 CPU 频率 1428–2016MHz\n解除温控 = 解除全部温控限制")
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
[group setProperty:S("低功耗 = 省电并限制 CPU 频率 1428–2016MHz；解除温控 = 解除全部温控限制") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self powerModeSpecifier]];

// ===================== 第3组: 核心保护（整合） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[group setProperty:S("开启即生效，关闭则对应保护失效") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("屏蔽高温通知") key:S("suppressThermalNotifications")]];
[specs addObject:[self switchSpecifier:S("热状态封锁") key:S("thermalStateProtection")]];
[specs addObject:[self switchSpecifier:S("阻止 HID 温度事件") key:S("blockHidEvents")]];

// ===================== 第4组: 高级 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("高级") forKey:S("label")];
[group setProperty:S("保留 CPMS 紧急保护安全阀，温度超过 75°C 时放行所有保护") forKey:S("footerText")];
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
