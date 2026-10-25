"""isolation.14 动态 Preferences specifier、分段空白修复与默认显示契约；isolation.15 起全部开关默认关闭。"""
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
SOURCE = (P / 'Settings/FRootListController.m').read_text()
MAKEFILE = (P / 'Makefile').read_text()


class DynamicSpecifierContracts(unittest.TestCase):
    def test_root_plist_is_fully_removed(self):
        self.assertFalse((P / 'Settings/Root.plist').exists())
        self.assertNotIn('Settings/Root.plist', MAKEFILE)
        self.assertNotIn('loadSpecifiersFromPlistName:', SOURCE)

    def test_real_controller_and_cached_data_source(self):
        self.assertIn('@interface FRootListController : PSListController', SOURCE)
        body = SOURCE.split('- (NSArray *)specifiers {', 1)[1]
        self.assertIn('if (!_specifiers) {', body)
        self.assertIn('NSMutableArray *specifiers = [NSMutableArray array];', body)
        self.assertIn('_specifiers = [specifiers copy];', body)
        self.assertIn('return _specifiers;', body)
        self.assertIn('[PSSpecifier groupSpecifierWithName:', body)
        self.assertIn('[PSSpecifier preferenceSpecifierNamed:', body)

    def test_all_17_items_and_content_are_dynamic(self):
        # 8 GROUP invocations + 7 ITEM invocations + mode/level/source = 19.
        body = SOURCE.split('- (NSArray *)specifiers {', 1)[1]
        groups = [x for x in re.findall(r'^\s*GROUP\(', body, re.M)]
        items = re.findall(r'\bITEM\("', body)
        self.assertEqual((len(groups), len(items), len(groups)+len(items)+4), (8, 7, 19))
        for key in ('powerMode','lockWhenFaceDown','sunlightLockedEnabled','blockThermalPopup',
                    'smartChargeUseSmartBatteryAPI','smartChargeEnabled',
                    'smartChargeDisableInflow','suppressBatteryServiceWarnings','smartChargeStopLevel'):
            self.assertIn('"'+key+'"', body)
        for label in ('温度保护','运行方式','设备朝下自动锁屏','阳光暴晒','锁定阳光暴晒模式',
                      '高温警告','屏蔽高温温度计警告','电池状态显示','隐藏电池维修提示','SmartBatteryAPI 智能停充','使用 SmartBatteryAPI',
                      '智能停充','停充时自动禁流','停充电量',
                      '开源','GitHub be-huge/insulation'):
            self.assertIn(label, body)
        self.assertNotIn('usreboot', body)
        self.assertIn('S("openSourceCode") forKey:S("action")', body)
        self.assertNotIn('usreboot', body)

    def test_dynamic_defaults_and_segment_values(self):
        # 保留的六个开关全部"首次默认关闭"。
        for key in ('blockThermalPopup','smartChargeUseSmartBatteryAPI',
                    'lockWhenFaceDown','sunlightLockedEnabled','smartChargeEnabled',
                    'smartChargeDisableInflow'):
            self.assertRegex(SOURCE, rf'ITEM\([^\n]+"{key}"[^\n]+numberWithBool:NO')
        self.assertEqual(len(re.findall(
            r'ITEM\("[^"]+", "[^"]+", PSSwitchCell, \[NSNumber numberWithBool:YES\]', SOURCE)), 0)
        self.assertIn('[mode setProperty:S("fullPower") forKey:S("default")]', SOURCE)
        self.assertIn('@[S("lowPower"), S("fullPower")] forKey:S("validValues")', SOURCE)
        self.assertIn('[level setProperty:[NSNumber numberWithInt:80] forKey:S("default")]', SOURCE)
        for n in range(70, 101, 5):
            self.assertIn(f'numberWithInt:{n}', SOURCE)

    def test_explicit_false_precedes_dynamic_default(self):
        method = SOURCE.split('- (id)readPreferenceValue:', 1)[1].split('\n}', 1)[0]
        p_value = method.index('id val = [self prefs][key];')
        p_return = method.index('if (val != nil) return val;')
        p_default = method.index('id defaultValue = [spec propertyForKey:S("default")];')
        self.assertLess(p_value, p_return)
        self.assertLess(p_return, p_default)
        self.assertIn('return defaultValue ?: [NSNumber numberWithBool:NO];', method)
        self.assertNotIn('isEqualToString:S("smartChargeStopLevel")', method)
        self.assertNotIn('isEqualToString:S("smartChargeUseSmartBatteryAPI")', method)

    def test_write_and_notification_contract_unchanged(self):
        method = SOURCE.split('- (void)setPreferenceValue:', 1)[1].split('\n}', 1)[0]
        self.assertIn('CPUthermalWritePrefs(prefs);', method)
        self.assertIn('CPUthermalPostPowerMode(', method)
        self.assertIn('notify_post(kCPUthermalSettingsChangedNotifC);', method)

    # ------------------------------------------------------------------
    # isolation.14：动态分段行空白修复
    # ------------------------------------------------------------------

    def test_segment_helpers_exist_with_respond_to_selector_guards(self):
        # 两个静态辅助函数都在 @implementation 内、-specifiers 之前定义。
        impl = SOURCE.split('@implementation FRootListController', 1)[1]
        before_specifiers = impl.split('- (NSArray *)specifiers {', 1)[0]
        self.assertIn('static PSCellType CPUthermalCellType(NSString *name, PSCellType fallback)', before_specifiers)
        self.assertIn('static void CPUthermalApplySegmentValues(PSSpecifier *spec, NSArray *values, NSArray *titles)', before_specifiers)
        # CPUthermalCellType：运行时解析 cell 类型，带 respondsToSelector 守卫与常量回退
        cell_type_body = impl.split('static PSCellType CPUthermalCellType', 1)[1].split('\n}', 1)[0]
        self.assertIn('[PSTableCell respondsToSelector:@selector(cellTypeFromString:)]', cell_type_body)
        self.assertIn('PSCellType resolved = [PSTableCell cellTypeFromString:name];', cell_type_body)
        self.assertIn('if ((NSInteger)resolved > 0) return resolved;', cell_type_body)
        self.assertIn('return fallback;', cell_type_body)
        # CPUthermalApplySegmentValues：补齐分段状态，同样带 respondsToSelector 守卫
        apply_body = impl.split('static void CPUthermalApplySegmentValues', 1)[1].split('\n}', 1)[0]
        self.assertIn('[spec respondsToSelector:@selector(setValues:titles:)]', apply_body)
        self.assertIn('[spec setValues:values titles:titles];', apply_body)

    def test_psspecifier_segment_values_category_declared(self):
        # 运行时私有 API 只声明不实现，调用受 respondsToSelector 保护。
        self.assertIn('@interface PSSpecifier (CPUthermalSegmentValues)', SOURCE)
        self.assertIn('- (void)setValues:(NSArray *)values titles:(NSArray *)titles;', SOURCE)
        self.assertIn('@selector(setValues:titles:)', SOURCE)
        self.assertEqual(SOURCE.count('[spec setValues:values titles:titles];'), 1)

    def test_both_segments_apply_values_and_titles(self):
        # 运行方式：低功耗/解除温控（顺序与 validValues/validTitles 一致）
        self.assertIn(
            'CPUthermalApplySegmentValues(mode, @[S("lowPower"), S("fullPower")], @[S("低功耗"), S("解除温控")]);',
            SOURCE)
        # 停充电量：70%–100% 值与标题
        values = ','.join('[NSNumber numberWithInt:%d]' % n for n in range(70, 101, 5))
        titles = ','.join('S("%d%%")' % n for n in range(70, 101, 5))
        self.assertIn('CPUthermalApplySegmentValues(level, @[%s], @[%s]);' % (values, titles), SOURCE)
        # 补值发生在加入数组之前（specifier 先完整、再注册）
        body = SOURCE.split('- (NSArray *)specifiers {', 1)[1]
        for name in ('mode', 'level'):
            block = body.split('PSSpecifier *%s ' % name, 1)[1].split('GROUP(', 1)[0]
            self.assertLess(block.index('CPUthermalApplySegmentValues(%s,' % name),
                            block.index('[specifiers addObject:%s];' % name))

    def test_cell_types_resolved_at_runtime_switches_kept_constant(self):
        # 两个分段 + 两个按钮经解析后的类型传入 cell:（回退仍为编译期常量）
        self.assertEqual(SOURCE.count('CPUthermalCellType(S("PSSegmentCell"), PSSegmentCell)'), 2)
        self.assertEqual(SOURCE.count('CPUthermalCellType(S("PSButtonCell"), PSButtonCell)'), 1)
        self.assertNotIn('cell:PSSegmentCell', SOURCE)
        self.assertNotIn('cell:PSButtonCell', SOURCE)
        self.assertNotIn('CPUthermalCellType(S("PSSwitchCell")', SOURCE)
        # 七个保留开关保持 PSSwitchCell 常量（不改动其渲染路径）
        self.assertEqual(SOURCE.count('PSSwitchCell'), 7)
        self.assertEqual(len(re.findall(r'ITEM\("[^"]+", "[^"]+", PSSwitchCell,', SOURCE)), 7)
        # 面板顺序/读写在 setPreferenceValue: 中保持联动
        method = SOURCE.split('- (void)setPreferenceValue:', 1)[1].split('\n}', 1)[0]
        self.assertIn('isEqualToString:S("powerMode")', method)

    def test_segment_rows_keep_key_defaults_and_actions(self):
        # 修复不得改变 key/defaults/default/validTitles/validValues 与两个按钮 action。
        mode_block = SOURCE.split('PSSpecifier *mode ', 1)[1].split('GROUP(', 1)[0]
        self.assertIn('[mode setProperty:S("powerMode") forKey:S("key")]', mode_block)
        self.assertIn('[mode setProperty:S("com.huayuarc.cputhermal") forKey:S("defaults")]', mode_block)
        self.assertIn('[mode setProperty:S("fullPower") forKey:S("default")]', mode_block)
        self.assertIn('@[S("低功耗"), S("解除温控")] forKey:S("validTitles")', mode_block)
        self.assertIn('@[S("lowPower"), S("fullPower")] forKey:S("validValues")', mode_block)
        level_block = SOURCE.split('PSSpecifier *level ', 1)[1].split('GROUP(', 1)[0]
        self.assertIn('[level setProperty:S("smartChargeStopLevel") forKey:S("key")]', level_block)
        self.assertIn('[level setProperty:[NSNumber numberWithInt:80] forKey:S("default")]', level_block)
        self.assertIn('forKey:S("validTitles")', level_block)
        self.assertIn('forKey:S("validValues")', level_block)
        for action in ('S("openSourceCode") forKey:S("action")',):
            self.assertIn(action, SOURCE)


if __name__ == '__main__':
    unittest.main(verbosity=2)
