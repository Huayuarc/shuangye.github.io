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
    if ([key isEqualToString:@"limitPreset"] && [validated isEqual:@"2048"] &&
        [NSProcessInfo processInfo].physicalMemory < 6ULL * 1024ULL * 1024ULL * 1024ULL) {
        [self reloadSpecifier:specifier];
        [self showMessage:@"2048 MiB 仅供至少 6 GiB RAM 的设备实验使用；推荐自适应或不高于 1536 MiB。"
                    title:@"未更改限额"];
        return;
    }
    NSError *error = nil;
    /* Setter has an atomic, locked read-modify-write; nil removes only this key. */
    if (!SJGWriteSetting(key, value, &error)) {
        [self reloadSpecifier:specifier];
        [self showMessage:error.localizedDescription ?: @"共享偏好写入失败" title:@"未保存"];
        return;
    }
    if ([key isEqualToString:@"enabled"] && validated && ![validated boolValue])
        [self showMessage:@"已停止后续限额调整。为避免触发 Jetsam，不会立即下调当前 SpringBoard；下次 SpringBoard 自然重启后恢复。已有更高限额始终保留。"
                    title:@"已关闭保护"];
    else if ([key isEqualToString:@"limitPreset"] && [validated isEqual:@"2048"])
        [self showMessage:@"2048 MiB 为实验值，可能挤压其他应用与系统的内存空间。推荐不高于 1536 MiB；本功能不会增加物理 RAM。"
                    title:@"实验限额"];
    else if ([key isEqualToString:@"pressureDelayTune"] && [validated boolValue])
        [self showMessage:@"一天级压力延迟可能导致系统卡机或失去响应。只有实验总开关同时开启时才请求修改；不支持或只读项将跳过。"
                    title:@"高风险实验项"];
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

- (id)readStatusValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"statusKey"];
    if ([key isEqualToString:@"path"]) return SJGPreferencesPath() ?: @"路径不可用";
    id value = self.statusSnapshot[key];
    if (!value || value == [NSNull null]) return @"未上报；请手工验证";
    if ([key isEqualToString:@"enabled"] && [value respondsToSelector:@selector(boolValue)])
        return [value boolValue] ? @"已启用（helper 上报）" : @"已关闭（helper 上报）";
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
        NSMutableArray *pairs = [NSMutableArray array];
        for (id entry in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [pairs addObject:[NSString stringWithFormat:@"%@: %@", entry, value[entry]]];
        return pairs.count ? [pairs componentsJoinedByString:@"；"] : @"无记录";
    }
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSString *unit = [key hasSuffix:@"MiB"] ? @" MiB" : @"";
        return [NSString stringWithFormat:@"%@%@", value, unit];
    }
    return @"上报格式不支持";
}
@end
