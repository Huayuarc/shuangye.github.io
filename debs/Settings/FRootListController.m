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
static const char *kPowerModeChangedC = "com.huayuarc.CPUthermal/powerModeChanged";

// 动态创建 NSString 的辅助宏 — 避免编译期 __cfstring
#define S(str) [NSString stringWithUTF8String:(str)]

// 功率模式值
static const char *kPowerModeValues[] = {
"lowPower",   // 低功耗
"fullPower",  // 满血
};

static const char *kPowerModeLabels[] = {
"低功耗",     // 低功耗
"满血",       // 满血
};

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

// 保存并通知 thermalmonitord 即时生效
- (void)savePrefsAndApply:(NSMutableDictionary *)prefs {
[prefs writeToFile:S(kPrefPathC) atomically:YES];
// 同时发 settingsChanged + powerModeChanged 确保 thermalmonitord 收到
notify_post(kNotifNameC);
notify_post(kPowerModeChangedC);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return;
NSMutableDictionary *prefs = [self prefs];
prefs[key] = value;
[self savePrefsAndApply:prefs];
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
NSString *key = [spec propertyForKey:S("key")];
if (!key) return nil;
id val = [self prefs][key];
if (val) return val;

// 默认值
if ([key isEqualToString:S("keepCPMSAlive")]) {
return [NSNumber numberWithBool:NO];
}
if ([key isEqualToString:S("powerMode")]) {
return S("lowPower");  // 功率模式默认低功耗
}
if ([key isEqualToString:S("suppressThermalNotifications")]) {
return [NSNumber numberWithBool:NO];  // 屏蔽通知默认关闭
}
return [NSNumber numberWithBool:YES]; // 其余保护默认开启
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

// ============================================================
// ★ 打开QQ交流群
// ============================================================
- (void)openQQGroup {
NSURL *url = [NSURL URLWithString:S("https://qm.qq.com/q/JvllAQiEwI")];
if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
} else {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("提示")
message:S("无法打开链接，请手动复制：\nhttps://qm.qq.com/q/JvllAQiEwI")
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:S("好的")
style:UIAlertActionStyleDefault handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
}
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

// ============================================================
// ★ 功率模式选择
// ============================================================
- (void)showPowerModePicker {
UIAlertController *alert = [UIAlertController
alertControllerWithTitle:S("功率模式")
message:S("低功耗 = 省电并限制 CPU 频率 1380MHz\n满血 = 解除全部温控")
preferredStyle:UIAlertControllerStyleActionSheet];

NSString *currentMode = [self prefs][S("powerMode")] ?: S("lowPower");

for (int i = 0; i < 2; i++) {
NSString *modeValue = S(kPowerModeValues[i]);
NSString *modeLabel = S(kPowerModeLabels[i]);
BOOL isCurrent = [currentMode isEqualToString:modeValue];

UIAlertAction *action = [UIAlertAction
actionWithTitle:isCurrent
? [NSString stringWithFormat:@"✓ %@", modeLabel]
: modeLabel
style:UIAlertActionStyleDefault
handler:^(UIAlertAction *action) {
NSMutableDictionary *prefs = [self prefs];
prefs[S("powerMode")] = modeValue;
[self savePrefsAndApply:prefs];
_specifiers = nil;
[self reloadSpecifiers];
}];
[alert addAction:action];
}

[alert addAction:[UIAlertAction actionWithTitle:S("取消")
style:UIAlertActionStyleCancel handler:nil]];

[self presentViewController:alert animated:YES completion:nil];
}

// ============================================================
// Specifiers 构建
// ============================================================
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

// ===================== ★ 第2组: 功率模式（新增自 Insulation） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("功率模式") forKey:S("label")];
[group setProperty:S("低功耗 = 省电并限制 CPU 频率 1380MHz，满血 = 解除全部温控")
forKey:S("footerText")];
[specs addObject:group];

// 功率模式选择按钮 — 显示当前模式
NSString *currentMode = [self prefs][S("powerMode")] ?: S("lowPower");
NSString *modeLabel = S("低功耗");
for (int i = 0; i < 2; i++) {
if ([currentMode isEqualToString:S(kPowerModeValues[i])]) {
modeLabel = S(kPowerModeLabels[i]);
break;
}
}
NSString *buttonTitle = [NSString stringWithFormat:@"功率模式：%@", modeLabel];
PSSpecifier *powerModeBtn = [PSSpecifier
preferenceSpecifierNamed:buttonTitle
target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:NULL];
[powerModeBtn setButtonAction:@selector(showPowerModePicker)];
[powerModeBtn setIdentifier:S("powerMode")];
[specs addObject:powerModeBtn];

// ===================== ★ 第3组: 通知（新增自 Insulation） =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("通知") forKey:S("label")];
[group setProperty:S("开启后拦截所有 thermal 相关的 Darwin 通知和 ObjC 热压力通知")
forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("屏蔽高温通知") key:S("suppressThermalNotifications")]];

// ===================== 第4组: 核心保护 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("核心保护") forKey:S("label")];
[group setProperty:S("开启即生效，关闭则对应保护失效")
forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("CPU 性能保护") key:S("cpuProtection")]];
[specs addObject:[self switchSpecifier:S("屏幕亮度保护") key:S("brightnessProtection")]];
[specs addObject:[self switchSpecifier:S("热状态封锁") key:S("thermalStateProtection")]];
[specs addObject:[self switchSpecifier:S("阻止 HID 温度事件") key:S("blockHidEvents")]];

group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("高级") forKey:S("label")];
[group setProperty:S("保留 CPMS 紧急保护安全阀，温度超过 75°C 时放行所有保护")
forKey:S("footerText")];
[specs addObject:group];

[specs addObject:[self switchSpecifier:S("保留 CPMS 紧急保护") key:S("keepCPMSAlive")]];

// ===================== 第6组: 操作 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("操作") forKey:S("label")];
[specs addObject:group];

PSSpecifier *rebootBtn = [PSSpecifier
preferenceSpecifierNamed:S("重启用户空间")
target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:NULL];
[rebootBtn setButtonAction:@selector(usreboot)];
[rebootBtn setIdentifier:S("usreboot")];
[specs addObject:rebootBtn];

// ===================== 第7组: 交流反馈 =====================
group = [PSSpecifier emptyGroupSpecifier];
[group setProperty:S("交流反馈") forKey:S("label")];
[specs addObject:group];

PSSpecifier *qqBtn = [PSSpecifier
preferenceSpecifierNamed:S("QQ 交流反馈群")
target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:NULL];
[qqBtn setButtonAction:@selector(openQQGroup)];
[qqBtn setIdentifier:S("qqgroup")];
[specs addObject:qqBtn];

[self setSpecifiers:specs];
}
return _specifiers;
}

@end
