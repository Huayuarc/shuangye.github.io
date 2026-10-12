"""isolation.13 动态 Preferences specifier 与默认显示契约。"""
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

    def test_all_19_items_and_content_are_dynamic(self):
        # 8 GROUP invocations + 7 ITEM invocations + mode/level/reboot/source = 19.
        body = SOURCE.split('- (NSArray *)specifiers {', 1)[1]
        groups = [x for x in re.findall(r'^\s*GROUP\(', body, re.M)]
        items = re.findall(r'\bITEM\("', body)
        self.assertEqual((len(groups), len(items), len(groups)+len(items)+4), (8, 7, 19))
        for key in ('powerMode','lockWhenFaceDown','sunlightLockedEnabled','blockThermalPopup',
                    'smartChargeUseSmartBatteryAPI','smartChargeEnabled',
                    'smartChargeDisableInflow','smartChargeStopLevel','currentGuardEnabled'):
            self.assertIn('"'+key+'"', body)
        for label in ('温度保护','运行方式','设备朝下自动锁屏','阳光暴晒','锁定阳光暴晒模式',
                      '高温警告','屏蔽高温温度计警告','SmartBatteryAPI 智能停充','使用 SmartBatteryAPI',
                      '智能停充','停充时自动禁流','停充电量','电流防降频','启用电流防降频',
                      '重启用户空间','开源','GitHub be-huge/insulation'):
            self.assertIn(label, body)
        self.assertIn('S("usreboot") forKey:S("action")', body)
        self.assertIn('S("openSourceCode") forKey:S("action")', body)

    def test_dynamic_defaults_and_segment_values(self):
        for key in ('blockThermalPopup','smartChargeUseSmartBatteryAPI','currentGuardEnabled'):
            self.assertRegex(SOURCE, rf'ITEM\([^\n]+"{key}"[^\n]+numberWithBool:YES')
        for key in ('lockWhenFaceDown','sunlightLockedEnabled','smartChargeEnabled','smartChargeDisableInflow'):
            self.assertRegex(SOURCE, rf'ITEM\([^\n]+"{key}"[^\n]+numberWithBool:NO')
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
