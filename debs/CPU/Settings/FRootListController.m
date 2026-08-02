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

- (void)restartThermalmonitord {
CPUthermalRestartThermalmonitordSoon();
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return;
NSMutableDictionary *prefs = [self prefs];
prefs[key] = value;
[self savePrefs:prefs];

// HIP(口袋过热)开关变更后重启 thermalmonitord，
// 让 %ctor → loadPrefs → applyHIPStateToSystem 把 HIP 状态同步到系统原生热状态 plist
if ([key isEqualToString:S("hipEnabled")]) {
[self restartThermalmonitord];
}
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return nil;
// 所有功能默认关闭，由用户在面板中开启
id val = [self prefs][key];
if (val) return val;
// 特定防护功能默认开启（开箱即用免配置）
if ([key isEqualToString:S("thermalBlockNotifPopup")] ||
[key isEqualToString:S("thermalPreventDimmingEnabled")]) {
return [NSNumber numberWithBool:YES];
}
return [NSNumber numberWithBool:NO]; // 全部默认关闭
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

#pragma mark - 开源代码

- (void)openSourceCode {
    [self openURLString:S("https://github.com/be-huge/insulation") fallback:nil failureMessage:S("无法打开 GitHub，请手动访问 https://github.com/be-huge/insulation")];
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
// 功率模式选择：PSLinkListCell 列表选择（与 Insulation 一致）
// 选择后由框架写入 defaults+key 并发 PostNotification，
// Tweak.x 监听 settingsChanged 通知自动 loadPrefs + 应用功率模式
PSSpecifier *spec = [PSSpecifier
preferenceSpecifierNamed:S("功率模式")
target:self
set:NULL
get:NULL
detail:nil
cell:PSLinkListCell
edit:nil];
[spec setIdentifier:S("powerMode")];
[spec setProperty:S("powerMode") forKey:S("key")];
[spec setProperty:S("com.huayuarc.CPUthermal") forKey:S("defaults")];
[spec setProperty:[NSArray arrayWithObjects:S("低功耗"), S("解除温控"), nil] forKey:S("validTitles")];
[spec setProperty:[NSArray arrayWithObjects:S("lowPower"), S("fullPower"), nil] forKey:S("validValues")];
[spec setProperty:S(kCPUthermalSettingsChangedNotifC) forKey:S("PostNotification")];
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

// ===================== 第1组: 功率模式 =====================
// 说明: 无总开关 — 温控保护默认强制开启，面板不提供启用/关闭入口，避免用户误操作关闭导致温控失效
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("功率模式") forKey:S("label")];
[group setProperty:S("低功耗 = 省电并锁定 CPU 频率 2016MHz；解除温控 = 解除全部温控限制") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self powerModeSpecifier]];

// ===================== 第2组: 温度计警告 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("温度计警告") forKey:S("label")];
[group setProperty:S("开启后阻止系统因高温弹出全屏「iPhone 需要冷却」温度计警告。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("屏蔽高温温度计警告") key:S("thermalBlockNotifPopup")]];

// ===================== 第3组: 口袋过热 (HOT-IN-POCKET) =====================
// 移植自 Battman-1.0.3.3 ThermalTunes 面板 TT_SECT_HIP
// 通过 SCPreferences 写入 hipOverride/hipPersistentlyEnabled/simulateHip 控制 thermalmonitord 原生 HIP
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("口袋过热 (HOT-IN-POCKET)") forKey:S("label")];
[group setProperty:S("屏幕关闭且不播放任何媒体时，自动降低 CPU 与 GPU 活动，防止设备在口袋中积热。此模式下功率模式控制让位于系统原生保护。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("口袋过热保护") key:S("hipEnabled")]];

// ===================== 第4组: 屏幕控制 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("屏幕控制") forKey:S("label")];
[group setProperty:S("开启后阻止系统因温控主动调暗屏幕亮度，保持当前亮度不变。") forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("防温控暗屏") key:S("thermalPreventDimmingEnabled")]];

// ===================== 第5组: 操作 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("操作") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self buttonSpecifier:S("重启用户空间")
action:@selector(usreboot)
identifier:S("usreboot")]];

// ===================== 第6组: 开源代码 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("开源") forKey:S("label")];
[specs addObject:group];

[specs addObject:[self buttonSpecifier:S("GitHub be-huge/insulation")
action:@selector(openSourceCode)
identifier:S("openSource")]];

[self setSpecifiers:specs];
}
return _specifiers;
}

@end
