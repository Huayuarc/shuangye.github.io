#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../SJGSettings.h"

@interface SJGRootListController : PSListController
@property (nonatomic, copy) NSDictionary *statusSnapshot;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)reloadServiceStatus;
- (void)requestCacheCleanup;
- (void)requestNormalMemoryTrim;
- (void)requestDeepMemoryTrim;
- (void)requestMemoryTrimMode:(NSString *)mode title:(NSString *)title message:(NSString *)message;
- (id)readStatusValue:(PSSpecifier *)specifier;
@end

@implementation SJGRootListController

/* Retain PSListController's inherited _specifiers; never redeclare/shadow it. */
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        _specifiers = [loaded mutableCopy];
        if (!_specifiers.count) {
            /* Some Preferences variants fail to unpack Root's top-level items dict. */
            NSBundle *bundle = [NSBundle bundleForClass:[self class]];
            NSDictionary *root = SJGReadPlist([bundle pathForResource:@"Root" ofType:@"plist"]);
            NSMutableArray *fallback = [NSMutableArray array];
            NSDictionary *types = @{@"PSGroupCell":@(PSGroupCell), @"PSSwitchCell":@(PSSwitchCell),
                                     @"PSLinkListCell":@(PSLinkListCell), @"PSButtonCell":@(PSButtonCell),
                                     @"PSTitleValueCell":@(PSTitleValueCell), @"PSStaticTextCell":@(PSStaticTextCell)};
            NSArray *items = [root[@"items"] isKindOfClass:[NSArray class]] ? root[@"items"] : @[];
            for (id entry in items) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *item = entry;
                NSNumber *type = types[item[@"cell"]];
                if (!type) continue;
                NSString *getter = [item[@"get"] isKindOfClass:[NSString class]] ? item[@"get"] : nil;
                NSString *setter = [item[@"set"] isKindOfClass:[NSString class]] ? item[@"set"] : nil;
                NSString *detail = [item[@"detail"] isKindOfClass:[NSString class]] ? item[@"detail"] : nil;
                PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:item[@"label"] ?: @""
                      target:self set:setter ? NSSelectorFromString(setter) : NULL
                      get:getter ? NSSelectorFromString(getter) : NULL
                      detail:detail ? NSClassFromString(detail) : Nil
                      cell:(PSCellType)type.integerValue edit:Nil];
                for (NSString *key in item) [s setProperty:item[key] forKey:key];
                if ([item[@"action"] isKindOfClass:[NSString class]])
                    s->action = NSSelectorFromString(item[@"action"]);
                [fallback addObject:s];
            }
            if (!fallback.count) {
                PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"SBJetsamGuard"];
                [group setProperty:@"面板资源未载入。请重新安装完整 DEB；本页面不会执行系统命令。"
                            forKey:@"footerText"];
                [fallback addObject:group];
            }
            _specifiers = fallback;
        }
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.statusSnapshot = SJGReadStatus() ?: @{};
    [self reloadSpecifiers];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
          message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:[NSString class]] || !key.length)
        return [specifier propertyForKey:@"default"] ?: @NO;
    return SJGReadSettings()[key] ?: [specifier propertyForKey:@"default"] ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:[NSString class]] || !key.length) return;
    id validated = value ? SJGValidatedValue(key, value) : nil;
    NSError *error = nil;
    /* The fixed shared API performs a locked atomic replacement. Remove only this
       key for nil; unrelated preferences and unknown future keys remain intact. */
    NSMutableDictionary *next = [SJGReadSettings() mutableCopy];
    if (value) next[key] = value; else [next removeObjectForKey:key];
    if (!SJGWriteSettings(next)) {
        [self reloadSpecifier:specifier];
        [self showMessage:error.localizedDescription ?: @"共享偏好写入失败" title:@"未保存"];
        return;
    }
    if ([key isEqualToString:@"enabled"] && validated && ![validated boolValue])
        [self showMessage:@"已停止后续限额调整。为避免触发 Jetsam，不会立即下调当前 SpringBoard；下次 SpringBoard 自然重启后恢复。已有更高限额始终保留。"
                    title:@"已关闭保护"];
    else if ([key isEqualToString:@"limitPreset"] && [validated isEqual:@"2048"])
        [self showMessage:@"2048 MiB 为用户可选的推荐起点。较高限额可能挤压其他应用与系统内存；本功能不会增加物理 RAM。"
                    title:@"限额已保存"];
    else if ([key isEqualToString:@"limitPreset"] && [validated isEqual:@"4096"])
        [self showMessage:@"4096 MiB 已保存。该值可能显著挤压其他进程并增加全局内存压力；本功能不会增加物理 RAM。"
                    title:@"高风险限额已保存"];
}

- (void)requestNormalMemoryTrim {
    [self requestMemoryTrimMode:@"normal" title:@"内存优化" message:@"将对当前 helper 进程执行有界内存优化，完成后释放全部临时内存。不会清理其他应用，不会修改全局 Jetsam 参数。"];
}
- (void)requestDeepMemoryTrim {
    [self requestMemoryTrimMode:@"deep" title:@"深度优化" message:@"将执行更高预算的有界内存优化，可能短暂增加内存压力；达到安全阈值会自动停止并释放全部临时内存。"];
}
- (void)requestMemoryTrimMode:(NSString *)mode title:(NSString *)title message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        NSString *name=[mode isEqualToString:@"deep"]?@"com.huayuarc.sbjetsamguard.trim.deep":@"com.huayuarc.sbjetsamguard.trim.normal";
        uint32_t rc=notify_post(name.UTF8String);
        [self showMessage:rc==NOTIFY_STATUS_OK?@"请求已发送，请稍后刷新服务状态查看结果。":@"后台服务通知发送失败。" title:title];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)requestCacheCleanup {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请求手动清理磁盘缓存？"
        message:@"清理的是磁盘文件，不增加 RAM。仅向 helper 发送请求；服务未运行时不会执行。是否包含应用缓存由单独开关决定。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"发送请求" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            uint32_t result = notify_post(SJG_CLEAN_CACHES);
            [weakSelf showMessage:result == NOTIFY_STATUS_OK ?
                @"请求已发送，并不代表清理成功。稍后点“刷新服务状态”查看 helper 的实际处理结果。" : @"Darwin 通知发送失败。"
                title:@"缓存清理"];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadServiceStatus {
    self.statusSnapshot = SJGReadStatus() ?: @{};
    [self reloadSpecifiers];
}

- (BOOL)statusIsStale {
    NSDictionary *status = self.statusSnapshot;
    if ([status[@"helper_stopped"] respondsToSelector:@selector(boolValue)] &&
        [status[@"helper_stopped"] boolValue]) return YES;
    id raw = status[@"lastUpdated"];
    NSDate *date = [raw isKindOfClass:[NSDate class]] ? raw : nil;
    if ([raw isKindOfClass:[NSNumber class]]) date = [NSDate dateWithTimeIntervalSince1970:[raw doubleValue]];
    if ([raw isKindOfClass:[NSString class]]) {
        date = [[NSISO8601DateFormatter new] dateFromString:raw];
        if (!date) {
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
            date = [formatter dateFromString:raw];
        }
    }
    return !date || -[date timeIntervalSinceNow] > 150.0;
}

- (NSString *)localizedResult:(id)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *code = [(NSString *)value lowercaseString];
    NSDictionary *translations = @{
        @"success": @"已完成", @"ok": @"已完成", @"applied": @"已应用",
        @"raised": @"已提高", @"unchanged": @"无需更改", @"disabled": @"已关闭",
        @"helper_stopped": @"后台服务已停止", @"permission_denied": @"权限不足",
        @"retry_exhausted": @"重试已耗尽", @"skipped": @"已跳过",
        @"unsupported": @"系统不支持", @"readonly": @"参数只读", @"error": @"处理失败",
        @"cleaned": @"已清理", @"cleanup_requested": @"已请求清理",
        @"cleanup_skipped": @"已跳过清理", @"not_running": @"服务未运行",
        @"starting": @"正在启动", @"verified_raised": @"已提高并读回验证",
        @"write_sent_verification_failed": @"已请求写入，读回未验证",
        @"unchanged_existing_or_special_limit": @"已有限额较高或特殊值，保持原样",
        @"disabled_next_process_uses_original_limits": @"已关闭；下次桌面重启恢复",
        @"waiting_for_springboard": @"等待 SpringBoard 启动"
    };
    if ([code hasPrefix:@"error_"]) return [NSString stringWithFormat:@"系统接口错误：%@", value];
    return translations[code] ?: value;
}

- (NSString *)shortStatusDictionary:(NSDictionary *)dictionary {
    if (!dictionary.count) return @"无记录";
    NSArray *keys = [[dictionary allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *parts = [NSMutableArray array];
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id value = dictionary[key];
        NSString *text = [value isKindOfClass:[NSDictionary class]] ?
            [NSString stringWithFormat:@"%lu项", (unsigned long)[value count]] : [value description];
        if (text.length > 32) text = [[text substringToIndex:32] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, text]];
        if (parts.count == 3) break;
    }
    NSString *summary = [parts componentsJoinedByString:@"；"];
    return keys.count > parts.count ? [summary stringByAppendingFormat:@"（共%lu项）", (unsigned long)keys.count] : summary;
}

- (id)readStatusValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"statusKey"];
    if ([key isEqualToString:@"path"]) return SJGPreferencesPath() ?: @"路径不可用";
    id value = self.statusSnapshot[key];
    BOOL stale = [self statusIsStale];
    if (!value || value == [NSNull null]) return @"未上报；请手工验证";
    if (stale) {
        if ([key isEqualToString:@"enabled"]) return @"上报已过期（后台服务停止或超过150秒）";
        if ([key isEqualToString:@"result"]) return @"上报已过期";
    }
    if ([key isEqualToString:@"enabled"] && [value respondsToSelector:@selector(boolValue)])
        return [value boolValue] ? @"已启用（helper 上报）" : @"已关闭（helper 上报）";
    if ([key isEqualToString:@"result"]) return [self localizedResult:value] ?: @"未知结果";
    if ([key isEqualToString:@"lastUpdated"]) {
        NSDate *date = [value isKindOfClass:[NSDate class]] ? value :
            ([value isKindOfClass:[NSNumber class]] ? [NSDate dateWithTimeIntervalSince1970:[value doubleValue]] : nil);
        if (date) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateStyle = NSDateFormatterShortStyle; formatter.timeStyle = NSDateFormatterMediumStyle;
            return [formatter stringFromDate:date];
        }
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [self shortStatusDictionary:value];
    }
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSString *unit = [key hasSuffix:@"MiB"] ? @" MiB" : @"";
        return [NSString stringWithFormat:@"%@%@", value, unit];
    }
    return @"上报格式不支持";
}
@end
