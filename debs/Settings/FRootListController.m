#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

#define kPrefPath @"/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist"

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // =============================================
        // 第 0 组: 总开关
        // =============================================
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"CPU Thermal — 温控插件"]];

        PSSpecifier *swEnabled = [PSSpecifier preferenceSpecifierNamed:@"启用插件"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swEnabled setProperty:@"enabled" forKey:@"key"];
        [swEnabled setProperty:@NO forKey:@"default"];
        [specs addObject:swEnabled];

        // =============================================
        // 第 1 组: IOKit 层防护
        // =============================================
        PSSpecifier *gIOKit = [PSSpecifier groupSpecifierWithName:@"IOKit 层防护"];
        [gIOKit setProperty:@"拦截 IOKit 温度传感器读写和降频操作。带安全阀: 75°C+ 自动放行所有保护" forKey:@"footerText"];
        [specs addObject:gIOKit];

        PSSpecifier *swCPU = [PSSpecifier preferenceSpecifierNamed:@"阻止 CPU 降频"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swCPU setProperty:@"blockCPUMitigation" forKey:@"key"];
        [swCPU setProperty:@NO forKey:@"default"];
        [specs addObject:swCPU];

        PSSpecifier *swBright = [PSSpecifier preferenceSpecifierNamed:@"阻止亮度降低"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swBright setProperty:@"blockBrightness" forKey:@"key"];
        [swBright setProperty:@NO forKey:@"default"];
        [specs addObject:swBright];

        PSSpecifier *swNominal = [PSSpecifier preferenceSpecifierNamed:@"强制 Nominal 热状态"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swNominal setProperty:@"forceNominalState" forKey:@"key"];
        [swNominal setProperty:@NO forKey:@"default"];
        [specs addObject:swNominal];

        // =============================================
        // 第 2 组: ObjC 类层防护 (基础)
        // =============================================
        PSSpecifier *gObjC = [PSSpecifier groupSpecifierWithName:@"ObjC 类层防护 (基础)"];
        [gObjC setProperty:@"钩住 thermalmonitord 内部类 CommonProduct/HidSensors，阻止热缓解动作和 HID 事件" forKey:@"footerText"];
        [specs addObject:gObjC];

        PSSpecifier *swObjC = [PSSpecifier preferenceSpecifierNamed:@"阻止 ObjC 热缓解动作"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swObjC setProperty:@"blockObjCHooks" forKey:@"key"];
        [swObjC setProperty:@NO forKey:@"default"];
        [specs addObject:swObjC];

        PSSpecifier *swHID = [PSSpecifier preferenceSpecifierNamed:@"阻止 HID 温度事件"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swHID setProperty:@"blockHidEvents" forKey:@"key"];
        [swHID setProperty:@NO forKey:@"default"];
        [specs addObject:swHID];

        PSSpecifier *swPlist = [PSSpecifier preferenceSpecifierNamed:@"修补热配置 plist"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swPlist setProperty:@"patchThermalPlist" forKey:@"key"];
        [swPlist setProperty:@NO forKey:@"default"];
        [specs addObject:swPlist];

        // =============================================
        // 第 3 组: 精细控制 (新增自 1.dylib 分析)
        // =============================================
        PSSpecifier *gAdvanced = [PSSpecifier groupSpecifierWithName:@"决策/控制层 (精细控制)"];
        [gAdvanced setProperty:@"拦截 thermalmonitord 决策树、控制力度计算和热压力升级。\"软化\"模式减半不归零，保留基础调节" forKey:@"footerText"];
        [specs addObject:gAdvanced];

        PSSpecifier *swDecisionTree = [PSSpecifier preferenceSpecifierNamed:@"阻止决策树评估"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swDecisionTree setProperty:@"blockDecisionTree" forKey:@"key"];
        [swDecisionTree setProperty:@NO forKey:@"default"];
        [specs addObject:swDecisionTree];

        PSSpecifier *swSoften = [PSSpecifier preferenceSpecifierNamed:@"软化控制力度 (减半)"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swSoften setProperty:@"softenControlEffort" forKey:@"key"];
        [swSoften setProperty:@NO forKey:@"default"];
        [specs addObject:swSoften];

        PSSpecifier *swThermalPressure = [PSSpecifier preferenceSpecifierNamed:@"阻止热压力升级"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swThermalPressure setProperty:@"blockThermalPressure" forKey:@"key"];
        [swThermalPressure setProperty:@NO forKey:@"default"];
        [specs addObject:swThermalPressure];

        PSSpecifier *swConfig = [PSSpecifier preferenceSpecifierNamed:@"修改热配置表 (+5°C 阈值)"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swConfig setProperty:@"modifyConfig" forKey:@"key"];
        [swConfig setProperty:@NO forKey:@"default"];
        [specs addObject:swConfig];

        PSSpecifier *swForceLevel = [PSSpecifier preferenceSpecifierNamed:@"覆盖强制热级别 (返回最低)"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swForceLevel setProperty:@"overrideForceLevel" forKey:@"key"];
        [swForceLevel setProperty:@NO forKey:@"default"];
        [specs addObject:swForceLevel];

        // =============================================
        // 第 4 组: 安全设置
        // =============================================
        PSSpecifier *gSafety = [PSSpecifier groupSpecifierWithName:@"安全设置"];
        [gSafety setProperty:@"温度安全阀: 设备超过此温度时自动放行所有保护，防止硬件损坏。75°C 是 iOS 热关机的典型阈值" forKey:@"footerText"];
        [specs addObject:gSafety];

        PSSpecifier *swCPMS = [PSSpecifier preferenceSpecifierNamed:@"保留 CPMS 紧急保护 (安全阀)"
            target:self set:@selector(setPref:spec:) get:@selector(getPref:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swCPMS setProperty:@"keepCPMSAlive" forKey:@"key"];
        [swCPMS setProperty:@NO forKey:@"default"];
        [specs addObject:swCPMS];

        // =============================================
        // 第 5 组: 模拟热级别
        // =============================================
        PSSpecifier *gPuppet = [PSSpecifier groupSpecifierWithName:@"模拟热级别"];
        [gPuppet setProperty:@"手动切换 thermalmonitord 的热状态级别 (关闭后无需重启即可测试)" forKey:@"footerText"];
        [specs addObject:gPuppet];

        PSSpecifier *btnPuppet = [PSSpecifier preferenceSpecifierNamed:@"当前: nominal"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [btnPuppet setButtonAction:@selector(showPuppetPicker)];
        [btnPuppet setProperty:@"thermalPuppetSelector" forKey:@"key"];
        [specs addObject:btnPuppet];

        // =============================================
        // 第 6 组: 操作按钮
        // =============================================
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"操作"]];

        PSSpecifier *btnApply = [PSSpecifier preferenceSpecifierNamed:@"立即生效"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [btnApply setButtonAction:@selector(applyNow)];
        [btnApply setProperty:@"applyNow" forKey:@"key"];
        [specs addObject:btnApply];

        PSSpecifier *btnSave = [PSSpecifier preferenceSpecifierNamed:@"保存配置"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [btnSave setButtonAction:@selector(saveConfig)];
        [btnSave setProperty:@"saveConfig" forKey:@"key"];
        [specs addObject:btnSave];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

// ============================================================================
// 偏好读写 — 直接操作 plist 文件
// ============================================================================
- (id)getPref:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    return d[key] ?: [spec propertyForKey:@"default"];
}

- (void)setPref:(id)val spec:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) d = [NSMutableDictionary dictionary];
    d[key] = val;
    [d writeToFile:kPrefPath atomically:YES];
    notify_post("com.huayuarc.cputhermal.prefschanged");
}

// ============================================================================
// 模拟热级别选择器 (ActionSheet)
// ============================================================================
- (void)showPuppetPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"模拟热级别"
        message:@"手动切换 thermalmonitord 的热状态" preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *levels = @[@"nominal", @"light", @"moderate", @"heavy"];
    NSArray *titles = @[@"无压力", @"轻度", @"中度", @"重度"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    NSString *current = prefs[@"thermalPuppetValue"] ?: @"nominal";

    for (NSUInteger i = 0; i < levels.count; i++) {
        NSString *title = titles[i];
        if ([levels[i] isEqualToString:current]) {
            title = [title stringByAppendingString:@" ✓"];
        }
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self setPuppetValue:levels[i]];
            }];
        [alert addAction:action];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 兼容
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.center.x, self.view.center.y, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setPuppetValue:(NSString *)level {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) d = [NSMutableDictionary dictionary];
    d[@"thermalPuppetValue"] = level;
    [d writeToFile:kPrefPath atomically:YES];

    // 更新按钮标题
    for (PSSpecifier *spec in _specifiers) {
        if ([[spec propertyForKey:@"key"] isEqualToString:@"thermalPuppetSelector"]) {
            [spec setName:[NSString stringWithFormat:@"当前: %@", level]];
            [self reloadSpecifier:spec];
            break;
        }
    }

    // 通知 tweak 立即执行
    notify_post("com.huayuarc.cputhermal.puppet");
}

// ============================================================================
// 立即生效 — 通知 tweak 重新加载配置
// ============================================================================
- (void)applyNow {
    notify_post("com.huayuarc.cputhermal.prefschanged");

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已生效"
        message:@"配置已重新加载" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// 保存配置 — 将所有开关值显式写入 plist，确保永久保存
// ============================================================================
- (void)saveConfig {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) d = [NSMutableDictionary dictionary];

    NSSet *switchKeys = [NSSet setWithArray:@[
        @"enabled", @"blockCPUMitigation", @"blockBrightness",
        @"forceNominalState", @"blockObjCHooks", @"blockHidEvents",
        @"patchThermalPlist", @"blockDecisionTree", @"softenControlEffort",
        @"blockThermalPressure", @"modifyConfig", @"overrideForceLevel",
        @"keepCPMSAlive"
    ]];

    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (key && [switchKeys containsObject:key]) {
            d[key] = [self getPref:spec];
        }
    }

    [d writeToFile:kPrefPath atomically:YES];
    notify_post("com.huayuarc.cputhermal.prefschanged");

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已保存"
        message:@"配置已永久写入系统" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
