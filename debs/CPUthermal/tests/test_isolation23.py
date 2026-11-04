import pathlib, re, unittest
ROOT = pathlib.Path(__file__).resolve().parent.parent

def read(rel):
    return (ROOT / rel).read_text(encoding='utf-8')

class Isolation23Contracts(unittest.TestCase):
    def test_component_module_exists(self):
        self.assertTrue((ROOT/'CPUthermalBatteryComponent.xm').is_file())
        self.assertTrue((ROOT/'CPUthermalBatteryComponent.plist').is_file())

    def test_component_filter_scope(self):
        pl = (ROOT/'CPUthermalBatteryComponent.plist').read_bytes()
        text = pl.decode('utf-8', 'replace')
        self.assertIn('com.apple.Preferences', text)
        self.assertIn('SpringBoard', text)
        # 不注入 thermalmonitord / powerd 等 daemon
        for banned in ('thermalmonitord','powerd','backboardd'):
            self.assertNotIn(banned, text)

    def test_component_hooks_are_evidence_based(self):
        x = read('CPUthermalBatteryComponent.xm')
        hooks = re.findall(r'%hook\s+(\w+)', x)
        # 只允许实证过的 Hook 目标
        for name in ('BatteryUIResourceClass','BatteryUIController','SBIconController',
                      'FLGroupViewModelImpl','SystemHealthUI','PSGAboutDataSource',
                      'PSUIPrefsListController','SBApplication','BSUIBadgeController',
                      'PSGAboutController','CRUAlertCell'):
            self.assertIn(name, hooks)
        # 禁止猜测未经验证的类
        for guess in ('SetupAssistant','SNDeviceBatteryInfo','BatteryServiceController'):
            self.assertNotIn(guess, hooks)
        # 残留提示（设置顶部/关于本机）按可见文本精确过滤，命中才跳过
        self.assertIn('CPUthermalIsBatteryWarningItem', x)
        # iOS 16 关于本机走 PSGAboutController + CRUAlertCell，需要 specifier 与 UI 双层拦截
        self.assertIn('CPUthermalFilterAboutSpecifiers', x)
        self.assertIn('CPUthermalHideBatteryUnknownPartRows', x)
        for marker in ('未知部件','Unknown Part','Important Battery Message'):
            self.assertIn(marker, x)

    def test_component_snapshot_only_read(self):
        x = read('CPUthermalBatteryComponent.xm')
        self.assertIn('CPUthermalReadPrefsSnapshot()', x)
        self.assertNotIn('CPUthermalWritePrefs', x)
        self.assertNotIn('removeItemAtPath', x)

    def test_single_smartcharge_switch_in_panel(self):
        s = read('Settings/FRootListController.m')
        # 三个子开关已合并：面板只保留一个智能停充总开关
        self.assertEqual(s.count('smartChargeUseSmartBatteryAPI'), 0)
        self.assertEqual(s.count('smartChargeDisableInflow'), 0)
        self.assertIn('smartChargeEnabled', s)

    def test_smartcharge_defaults_with_single_switch(self):
        t = read('Tools/CPUthermalChargeTool.m')
        # 总开关开启时默认启用 SmartBattery 优先 + 禁流（与旧三开关全开等价）
        self.assertIn('BoolPreference(prefs, S("smartChargeUseSmartBatteryAPI"), YES)', t)
        self.assertIn('BoolPreference(prefs, S("smartChargeDisableInflow"), YES)', t)

    def test_battery_switches_merged_into_one(self):
        p = read('Settings/FRootListController.m')
        self.assertNotIn('suppressComponentWarning', p)
        self.assertNotIn('隐藏部件与服务历史未知部件', p)
        self.assertIn('ITEM("隐藏电池维修提示", "suppressBatteryServiceWarnings"', p)

    def test_smartcharge_switch_renamed(self):
        p = read('Settings/FRootListController.m')
        self.assertIn('ITEM("智能停充", "smartChargeEnabled"', p)
        self.assertNotIn('ITEM("SmartBatteryAPI 智能停充"', p)

    def test_thermal_throttle_bypass_removed(self):
        p = read('Settings/FRootListController.m')
        t = read('Tweak.x')
        for removed in ('ignoreThermalThrottle', '彻底屏蔽温度检测', 'thermalThrottleIgnored', 'g_ignoreThermalThrottle'):
            self.assertNotIn(removed, p + t)
        # 温度 getter 的单位和 ABI 未确认，必须完全保持原生。
        self.assertNotRegex(t, re.compile(r'^- \(float\)thermalSensorValuesMaxFromIndexSet:', re.M))
        self.assertNotRegex(t, re.compile(r'^- \(int\)dieTempFilteredMaxAverage\s*\{', re.M))
        self.assertNotRegex(t, re.compile(r'^- \(int\)getHighestSkinTemp\s*\{', re.M))

    def test_both_modes_force_nominal_pressure(self):
        t = read('Tweak.x')
        self.assertIn('static BOOL shouldForceNominalThermalPressure(void)', t)
        self.assertIn('return runtimeProtectionEnabled();', t)
        self.assertIn('CPUthermalForceNominalPressure();', t)

if __name__ == '__main__':
    unittest.main()
