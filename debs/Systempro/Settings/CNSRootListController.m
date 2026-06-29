#import "CNSPrefs.h"
#import "CNSRulesListController.h"
#import <roothide.h>
#import <notify.h>
#import <UIKit/UIKit.h>

// ============================================================
//  CNSConfig: 配置读写工具(三控制器共用)
// ============================================================
@implementation CNSConfig

+ (NSString *)configFullPath { return jbroot(CNS_CONFIG_PATH); }

+ (NSMutableDictionary *)load {
    NSString *path = [self configFullPath];
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (cfg == nil) {
        cfg = [NSMutableDictionary dictionary];
        cfg[CNS_KEY_ENABLED] = @YES;
        cfg[CNS_KEY_RESPECTMUTE] = @YES;
        cfg[CNS_KEY_RULES] = [NSMutableArray array];
    }
    return cfg;
}

+ (void)save:(NSDictionary *)config {
    NSString *path = [self configFullPath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [config writeToFile:path atomically:YES];
    notify_post(CNS_NOTIFY_NAME);
    CNSPLog(@"保存配置: 规则 %@ 条, 已发通知", @([config[CNS_KEY_RULES] count]));
}

+ (NSString *)newRuleID { return [[NSUUID UUID] UUIDString]; }

+ (NSMutableArray *)loadRules {
    NSMutableDictionary *cfg = [self load];
    NSArray *rules = cfg[CNS_KEY_RULES];
    NSMutableArray *out = [NSMutableArray array];
    BOOL patched = NO;
    if ([rules isKindOfClass:[NSArray class]]) {
        for (NSDictionary *r in rules) {
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *m = [r mutableCopy];
            // 旧数据(或手写配置)无 ruleID 时补一个, 保证主键稳定
            if ([m[CNS_RULE_ID] length] == 0) { m[CNS_RULE_ID] = [self newRuleID]; patched = YES; }
            // 音频路径自愈: 旧配置可能存了含 .jbroot-XXXX 随机前缀的完整路径,
            // 重越狱后会失效。此处归一化为相对路径并回写, 一次修好存量配置。
            NSString *sound = m[CNS_RULE_SOUND];
            if (sound.length > 0) {
                NSString *norm = CNSNormalizeSoundPath(sound);
                if (![norm isEqualToString:sound]) { m[CNS_RULE_SOUND] = norm; patched = YES; }
            }
            [out addObject:m];
        }
    }
    if (patched) [self saveRules:out];   // 回写补齐的 ruleID
    return out;
}

+ (void)saveRules:(NSArray *)rules {
    NSMutableDictionary *cfg = [self load];
    cfg[CNS_KEY_RULES] = rules ?: @[];
    [self save:cfg];
}

+ (NSMutableDictionary *)ruleWithID:(NSString *)ruleID {
    if (ruleID.length == 0) return nil;
    for (NSMutableDictionary *r in [self loadRules])
        if ([r[CNS_RULE_ID] isEqualToString:ruleID]) return r;
    return nil;
}

+ (void)upsertRule:(NSDictionary *)rule {
    NSString *rid = rule[CNS_RULE_ID];
    if (rid.length == 0) return;
    NSMutableArray *rules = [self loadRules];
    NSUInteger found = NSNotFound;
    for (NSUInteger i = 0; i < rules.count; i++)
        if ([rules[i][CNS_RULE_ID] isEqualToString:rid]) { found = i; break; }
    if (found != NSNotFound) rules[found] = rule;
    else [rules addObject:rule];
    [self saveRules:rules];
}

+ (void)deleteRuleID:(NSString *)ruleID {
    if (ruleID.length == 0) return;
    NSMutableArray *rules = [self loadRules];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSDictionary *r in rules)
        if (![r[CNS_RULE_ID] isEqualToString:ruleID]) [keep addObject:r];
    [self saveRules:keep];
}

+ (void)ensureSoundsDir {
    [[NSFileManager defaultManager] createDirectoryAtPath:jbroot(CNS_SOUNDS_DIR)
                              withIntermediateDirectories:YES attributes:nil error:nil];
}

@end

// ============================================================
//  CNSRootListController: 主设置页
// ============================================================
@interface CNSRootListController : PSListController
@end

@implementation CNSRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        [CNSConfig ensureSoundsDir];
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *grpMain = [PSSpecifier groupSpecifierWithName:@""];
        [grpMain setProperty:@"按 App / 标题 / 内容匹配通知, 命中后替换为自定义提示音。通话来电铃声始终保留。" forKey:@"footerText"];
        [specs addObject:grpMain];

        PSSpecifier *swEnabled = [PSSpecifier preferenceSpecifierNamed:@"启用"
            target:self set:@selector(setEnabled:specifier:) get:@selector(getEnabled:)
            detail:nil cell:PSSwitchCell edit:nil];
        [specs addObject:swEnabled];

        PSSpecifier *swMute = [PSSpecifier preferenceSpecifierNamed:@"跟随系统静音"
            target:self set:@selector(setRespectMute:specifier:) get:@selector(getRespectMute:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swMute setProperty:@"开启: 静音/勿扰下不播自定义声(推荐)。关闭: 无视静音强制播放。" forKey:@"footerText"];
        [specs addObject:swMute];

        PSSpecifier *grpRules = [PSSpecifier groupSpecifierWithName:@"通知规则"];
        [grpRules setProperty:@"每条规则可指定来源 App、关键字、匹配方式与提示音。" forKey:@"footerText"];
        [specs addObject:grpRules];

        PSSpecifier *linkRules = [PSSpecifier preferenceSpecifierNamed:@"管理规则"
            target:self set:nil get:nil
            detail:[CNSRulesListController class] cell:PSLinkCell edit:nil];
        [linkRules setProperty:@YES forKey:@"isController"];
        [specs addObject:linkRules];

        PSSpecifier *grpAdv = [PSSpecifier groupSpecifierWithName:@"高级"];
        [grpAdv setProperty:@"启动宽限期: 注销/重启后这段时间内不播自定义声, 避免系统重发历史通知造成误响。建议 5-15 秒。" forKey:@"footerText"];
        [specs addObject:grpAdv];

        PSSpecifier *grace = [PSSpecifier preferenceSpecifierNamed:@"启动宽限期(秒)"
            target:self set:@selector(setGrace:specifier:) get:@selector(getGrace:)
            detail:nil cell:PSEditTextCell edit:nil];
        [grace setProperty:@"10" forKey:@"placeholder"];
        [grace setProperty:@NO forKey:@"autoCaps"];
        [grace setProperty:@NO forKey:@"autoCorrection"];
        [grace setProperty:@(UIKeyboardTypeNumberPad) forKey:@"keyboardType"];
        [specs addObject:grace];

        PSSpecifier *grpLog = [PSSpecifier groupSpecifierWithName:@"调试"];
        [grpLog setProperty:@"仅排查问题时开启, 会把通知与匹配写入日志文件; 平时请关闭。" forKey:@"footerText"];
        [specs addObject:grpLog];

        PSSpecifier *swLog = [PSSpecifier preferenceSpecifierNamed:@"调试日志"
            target:self set:@selector(setDebugLog:specifier:) get:@selector(getDebugLog:)
            detail:nil cell:PSSwitchCell edit:nil];
        [specs addObject:swLog];

        PSSpecifier *clearLog = [PSSpecifier preferenceSpecifierNamed:@"清空日志"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        clearLog->action = @selector(cnsClearLog);
        [clearLog setProperty:@YES forKey:@"enabled"];
        [specs addObject:clearLog];

        PSSpecifier *grpAbout = [PSSpecifier groupSpecifierWithName:@"关于"];
        [grpAbout setProperty:[NSString stringWithFormat:@"自定义音频请放入 %@\n\n本插件仅自用，谢绝分享。", CNS_SOUNDS_DIR] forKey:@"footerText"];
        [specs addObject:grpAbout];
        PSSpecifier *ver = [PSSpecifier preferenceSpecifierNamed:@"版本"
            target:self set:nil get:@selector(getVersion:) detail:nil cell:PSTitleValueCell edit:nil];
        [ver setProperty:@"1.1" forKey:@"value"];
        [ver setProperty:@NO forKey:@"enabled"];
        [specs addObject:ver];

        _specifiers = specs;
    }
    return _specifiers;
}

- (id)getEnabled:(PSSpecifier *)s { return [CNSConfig load][CNS_KEY_ENABLED] ?: @YES; }
- (void)setEnabled:(id)v specifier:(PSSpecifier *)s {
    NSMutableDictionary *cfg = [CNSConfig load]; cfg[CNS_KEY_ENABLED] = v ?: @NO; [CNSConfig save:cfg];
}
- (id)getRespectMute:(PSSpecifier *)s { id v = [CNSConfig load][CNS_KEY_RESPECTMUTE]; return v ?: @YES; }
- (void)setRespectMute:(id)v specifier:(PSSpecifier *)s {
    NSMutableDictionary *cfg = [CNSConfig load]; cfg[CNS_KEY_RESPECTMUTE] = v ?: @NO; [CNSConfig save:cfg];
}
- (id)getDebugLog:(PSSpecifier *)s { return [CNSConfig load][CNS_KEY_DEBUGLOG] ?: @NO; }
- (void)setDebugLog:(id)v specifier:(PSSpecifier *)s {
    NSMutableDictionary *cfg = [CNSConfig load]; cfg[CNS_KEY_DEBUGLOG] = v ?: @NO; [CNSConfig save:cfg];
}
- (id)getGrace:(PSSpecifier *)s {
    id v = [CNSConfig load][CNS_KEY_GRACE];
    return v ? [NSString stringWithFormat:@"%g", [v doubleValue]] : @"10";
}
- (void)setGrace:(id)v specifier:(PSSpecifier *)s {
    double g = [v doubleValue];
    if (g < 0) g = 0;
    NSMutableDictionary *cfg = [CNSConfig load]; cfg[CNS_KEY_GRACE] = @(g); [CNSConfig save:cfg];
}
- (id)getVersion:(PSSpecifier *)s { return @"1.1"; }
- (void)cnsClearLog {
    [@"" writeToFile:jbroot(CNS_LOG_PATH) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已清空"
        message:@"日志文件已清空。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

