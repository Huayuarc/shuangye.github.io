#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
// PSTableCell 用于运行时解析 cell 类型（isolation.14）；PSSpecifier.h 通常已传递引入，
// 这里用 __has_include 兜底，避免不同头文件集缺省该声明。
#if __has_include(<Preferences/PSTableCell.h>)
#import <Preferences/PSTableCell.h>
#endif
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

@interface FRootListController : PSListController
@end

// isolation.14：动态构建的分段 specifier 必须补齐 values/titles 状态。
// 运行时 plist 加载器会填该状态（-[PSSpecifier setValues:titles:]），纯代码构造不会，
// 缺失时 PSSegmentCell 渲染为空白。此处只声明运行时私有 API，调用前做 respondsToSelector 守卫。
@interface PSSpecifier (CPUthermalSegmentValues)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

// Forward declarations for preference and alert actions.
@interface FRootListController (CPUthermalActionsForward)
- (void)alert:(NSString *)title message:(NSString *)message;
- (NSMutableDictionary *)prefs;
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

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [controller addAction:[UIAlertAction actionWithTitle:S("好的") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (NSMutableDictionary *)prefs {
    NSMutableDictionary *d = CPUthermalReadMutablePrefs();
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

- (void)runThermalToolCommand:(const char *)command value:(BOOL)value hasValue:(BOOL)hasValue {
    NSString *toolPath = CPUthermalToolPath();
    if (!toolPath.length || !command) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        pid_t pid = 0;
        char valueBuffer[2] = { value ? '1' : '0', '\0' };
        char *argsWithValue[] = {(char *)"CPUthermalTool", (char *)command, valueBuffer, NULL};
        char *argsNoValue[] = {(char *)"CPUthermalTool", (char *)command, NULL};
        char **arguments = hasValue ? argsWithValue : argsNoValue;
        if (posix_spawn(&pid, toolPath.fileSystemRepresentation, NULL, NULL, arguments, NULL) == 0) waitpid(pid, NULL, 0);
    });
}

- (void)restartThermalMonitorImmediately {
    NSString *killall = CPUthermalExistingExecutablePath("/usr/bin/killall", @[
        S("/var/jb/usr/bin/killall"), S("/var/jb/bin/killall"), S("/usr/bin/killall"), S("/bin/killall")]);
    if (!killall.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        pid_t pid = 0;
        char *args[] = {(char *)"killall", (char *)"-q", (char *)"thermalmonitord", NULL};
        posix_spawn(&pid, killall.fileSystemRepresentation, NULL, NULL, args, NULL);
    });
}


// ============================================================================
// 控制中心模块尺寸：改写已安装 bundle 的 Info.plist（CCSModuleSize / ModuleSize）
//   控制中心按该 plist 决定模块占位（1×1 或 2×1）；目录在越狱根内、可写，
//   因此无需 hook 私有 API，改写后注销即生效。
// ============================================================================
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return;

    NSMutableDictionary *prefs = [self prefs];

    prefs[key] = value;
    if ([key isEqualToString:S("sunlightLockedEnabled")]) {
        [prefs removeObjectForKey:S("sunlightAutomatic")];
        [prefs removeObjectForKey:S("sunlightOverride")];
    }

    // isolation.15：面板级写校验——写后立即读回比对（此前写入静默失败/被其它写者覆盖
    // 都无从发现）；不一致 → 再写一次并复核；仍不一致 → 直接写规范路径
    // （CPUthermalCanonicalPrefPath）并复核。写成功路径内部会修复文件属主/权限（mobile 可读写）。
    CPUthermalWritePrefs(prefs);
    NSDictionary *readBack = CPUthermalReadPrefs();
    if (!CPUthermalPrefValueEquals(readBack[key], value)) {
        CPUthermalWritePrefs(prefs);
        readBack = CPUthermalReadPrefs();
        if (!CPUthermalPrefValueEquals(readBack[key], value)) {
            CPUthermalWritePrefsAtPathVerified(prefs, CPUthermalCanonicalPrefPath());
        }
    }

    // 运行方式：写偏好后立即通知主模块应用（分段选择直接写偏好，必须在此联动）
    if ([key isEqualToString:S("powerMode")]) {
        CPUthermalPostPowerMode([value isKindOfClass:[NSString class]] ? value : S("fullPower"));
    }
    notify_post(kCPUthermalSettingsChangedNotifC);
}


- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return nil;
    // isolation.15：读路径保持"prefs 显式值优先（含 false）→ specifier default → NO"，
    // 不写盘、不删除、不触发任何破坏性动作（写入链路已修复属主/权限，mobile 可正常读到）。
    id val = [self prefs][key];
    if (val != nil) return val;
    id defaultValue = [spec propertyForKey:S("default")];
    return defaultValue ?: [NSNumber numberWithBool:NO];
}

#pragma mark - 工具方法

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

#pragma mark - 开源代码

- (void)openSourceCode {
    [self openURLString:S("https://github.com/be-huge/insulation") fallback:nil failureMessage:S("无法打开 GitHub，请手动访问 https://github.com/be-huge/insulation")];
}

#pragma mark - Specifier 加载

// isolation.14：分段与按钮的 cell 类型优先向运行时查询（数值随系统版本变化），
// 失败或解析为 0（PSGroupCell）时回退编译期常量；常量仍保留在二进制中便于审计。
static PSCellType CPUthermalCellType(NSString *name, PSCellType fallback) {
    if ([PSTableCell respondsToSelector:@selector(cellTypeFromString:)]) {
        PSCellType resolved = [PSTableCell cellTypeFromString:name];
        if ((NSInteger)resolved > 0) return resolved;
    }
    return fallback;
}

// isolation.14：为动态构造的分段 specifier 补齐 values/titles 状态（空白行修复的核心）。
static void CPUthermalApplySegmentValues(PSSpecifier *spec, NSArray *values, NSArray *titles) {
    if ([spec respondsToSelector:@selector(setValues:titles:)]) {
        [spec setValues:values titles:titles];
    }
}

- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray array];
#define GROUP(label, footer) do { \
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:S(label)]; \
            NSString *footerText = S(footer); \
            if (footerText.length > 0) [group setProperty:footerText forKey:S("footerText")]; \
            [specifiers addObject:group]; \
        } while (0)
#define ITEM(label, key, cellType, def) do { \
            PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:S(label) target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:cellType edit:nil]; \
            [item setProperty:S(key) forKey:S("key")]; \
            [item setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")]; \
            [item setProperty:def forKey:S("default")]; \
            [specifiers addObject:item]; \
        } while (0)
        GROUP("温度保护", "运行方式决定用户态预算请求：低功耗仅限制 CPU（2500mW／45%／Level2），清除 GPU/Package 满预算下限，不动亮度；解除温控请求 CPU/GPU/Package Floor/Ceiling=100、CPU Level0。Package 是共享功率预算，不是整个 SoC 硬锁；不保证最大时钟或实际满功率，硬件保护仍可接管。");
        PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:S("运行方式") target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:CPUthermalCellType(S("PSSegmentCell"), PSSegmentCell) edit:nil];
        [mode setProperty:S("powerMode") forKey:S("key")]; [mode setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")];
        [mode setProperty:S("fullPower") forKey:S("default")]; [mode setProperty:@[S("低功耗"), S("解除温控")] forKey:S("validTitles")]; [mode setProperty:@[S("lowPower"), S("fullPower")] forKey:S("validValues")];
        CPUthermalApplySegmentValues(mode, @[S("lowPower"), S("fullPower")], @[S("低功耗"), S("解除温控")]);
        [specifiers addObject:mode];
        GROUP("", "开启后，SpringBoard 检测到设备屏幕朝下时模拟按下锁屏键。仅注入 SpringBoard，默认关闭。"); ITEM("设备朝下自动锁屏", "lockWhenFaceDown", PSSwitchCell, [NSNumber numberWithBool:NO]);
        GROUP("阳光暴晒", "强制锁定阳光暴晒 (Sunlight) 模式：屏幕亮度上限与对比度按强光环境提升，不再等待环境光判断；关闭即恢复系统自动检测。"); ITEM("锁定阳光暴晒模式", "sunlightLockedEnabled", PSSwitchCell, [NSNumber numberWithBool:NO]);
        GROUP("高温警告", "开启后仅处理 SpringBoard 的进程内热状态读取；为优先稳定性，不再全局拦截系统通知注册、取消或读值，部分高温警告路径仍可能由系统显示。默认关闭，关闭后保留原始热状态；不改变真实温度及硬件保护。"); ITEM("屏蔽高温温度计警告", "blockThermalPopup", PSSwitchCell, [NSNumber numberWithBool:NO]);
        GROUP("SmartBatteryAPI 智能停充", "移植 ChargeLimiter 电量阈值核心：可优先使用 AppleSmartBattery，达到阈值后通过 PredictiveChargingInhibit 停充；可选同时将 ExternalConnected 置为 false 禁流。电量下降 5% 后先恢复输入再恢复充电。"); ITEM("使用 SmartBatteryAPI", "smartChargeUseSmartBatteryAPI", PSSwitchCell, [NSNumber numberWithBool:NO]); ITEM("智能停充", "smartChargeEnabled", PSSwitchCell, [NSNumber numberWithBool:NO]); ITEM("停充时自动禁流", "smartChargeDisableInflow", PSSwitchCell, [NSNumber numberWithBool:NO]);
        PSSpecifier *level = [PSSpecifier preferenceSpecifierNamed:S("停充电量") target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:CPUthermalCellType(S("PSSegmentCell"), PSSegmentCell) edit:nil]; [level setProperty:S("smartChargeStopLevel") forKey:S("key")]; [level setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")]; [level setProperty:[NSNumber numberWithInt:80] forKey:S("default")]; [level setProperty:@[S("70%"),S("75%"),S("80%"),S("85%"),S("90%"),S("95%"),S("100%")] forKey:S("validTitles")]; [level setProperty:@[[NSNumber numberWithInt:70],[NSNumber numberWithInt:75],[NSNumber numberWithInt:80],[NSNumber numberWithInt:85],[NSNumber numberWithInt:90],[NSNumber numberWithInt:95],[NSNumber numberWithInt:100]] forKey:S("validValues")];
        CPUthermalApplySegmentValues(level, @[[NSNumber numberWithInt:70],[NSNumber numberWithInt:75],[NSNumber numberWithInt:80],[NSNumber numberWithInt:85],[NSNumber numberWithInt:90],[NSNumber numberWithInt:95],[NSNumber numberWithInt:100]], @[S("70%"),S("75%"),S("80%"),S("85%"),S("90%"),S("95%"),S("100%")]);
        [specifiers addObject:level];
        GROUP("Hello 120Hz", "完整移植 Hello 120Hz 3.3.3-3：帧率选择、全局注入、应用排除、调试 HUD、重置与注销。默认关闭，启用后按原版策略运行。");
        PSSpecifier *hello = [PSSpecifier preferenceSpecifierNamed:S("Hello 120Hz") target:self set:nil get:nil detail:NSClassFromString(S("hello120hzPreRootListController")) cell:PSLinkCell edit:nil];
        [specifiers addObject:hello];
        GROUP("开源", ""); PSSpecifier *source = [PSSpecifier preferenceSpecifierNamed:S("GitHub be-huge/insulation") target:self set:@selector(openSourceCode) get:nil detail:nil cell:CPUthermalCellType(S("PSButtonCell"), PSButtonCell) edit:nil]; [source setProperty:S("openSourceCode") forKey:S("action")]; [specifiers addObject:source];
#undef ITEM
#undef GROUP
        _specifiers = [specifiers copy];
    }
    return _specifiers;
}

@end
