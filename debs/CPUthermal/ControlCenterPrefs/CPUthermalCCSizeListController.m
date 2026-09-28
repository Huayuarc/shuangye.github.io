// ============================================================================
// CPUthermalCCSizeListController — 控制中心模块尺寸设置页
//
// 由模块 Info.plist 的 CCSPreferencesRootListController 指定：
// 用户在「设置 → 控制中心 → 控制中心自定义 → CPUthermal」点进本页，
// 用分段滑块选择模块占用的格数（宽 1~4 / 高 1~4），保存到插件偏好。
// 模块 VC 通过 -moduleSizeForOrientation: 运行时上报，因此调整后即时生效。
// ============================================================================

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <CPUthermalPaths.h>

@interface CPUthermalCCSizeListController : PSListController
@end

@implementation CPUthermalCCSizeListController

- (NSDictionary *)cpuPrefs {
    NSDictionary *prefs = CPUthermalReadPrefs();
    return prefs ?: @{};
}

- (void)writePref:(NSString *)key value:(id)value {
    NSMutableDictionary *prefs = [CPUthermalReadMutablePrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    prefs[key] = value;
    CPUthermalWritePrefs(prefs);
    // 通知控制中心与主模块刷新（模块尺寸在下次布局时重新查询）
    notify_post(kCPUthermalSettingsChangedNotifC);
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return nil;
    id value = [self cpuPrefs][key];
    if (value) return value;
    if ([key isEqualToString:S("ccModuleWidth")]) return @2;
    if ([key isEqualToString:S("ccModuleHeight")]) return @1;
    return [spec propertyForKey:S("default")] ?: @0;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:S("key")];
    if (!key) return;
    [self writePref:key value:value];
}

- (PSSpecifier *)sliderSpecifierNamed:(NSString *)name key:(NSString *)key fallback:(NSInteger)fallback {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:nil
                                                        cell:PSSliderCell
                                                        edit:nil];
    [spec setProperty:key forKey:S("key")];
    [spec setProperty:@1 forKey:S("min")];
    [spec setProperty:@4 forKey:S("max")];
    [spec setProperty:@3 forKey:S("segmentCount")];
    [spec setProperty:@YES forKey:S("isSegmented")];
    [spec setProperty:@YES forKey:S("showValue")];
    [spec setProperty:@(fallback) forKey:S("default")];
    return spec;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:S("模块尺寸")];
        [group setProperty:S("选择控制中心里本模块占用的格数（宽 × 高）。默认 2×1；调整后重新打开控制中心即可看到效果。")
                    forKey:S("footerText")];
        [specs addObject:group];
        [specs addObject:[self sliderSpecifierNamed:S("宽度") key:S("ccModuleWidth") fallback:2]];
        [specs addObject:[self sliderSpecifierNamed:S("高度") key:S("ccModuleHeight") fallback:1]];

        PSSpecifier *note = [PSSpecifier groupSpecifierWithName:S("说明")];
        [note setProperty:S("宽度 2 即 2×1 宽模块（显示 图标 + 当前运行方式）；宽度 1 为正方形小模块。")
                   forKey:S("footerText")];
        [specs addObject:note];
        _specifiers = [specs copy];
    }
    return _specifiers;
}

@end
