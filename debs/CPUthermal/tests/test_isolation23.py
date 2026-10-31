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
                      'FLGroupViewModelImpl','SystemHealthUI'):
            self.assertIn(name, hooks)
        # 禁止猜测未经验证的类
        for guess in ('SetupAssistant','SNDeviceBatteryInfo','BatteryServiceController'):
            self.assertNotIn(guess, hooks)
        # 残留提示（设置顶部/关于本机）按可见文本精确过滤，命中才跳过
        self.assertIn('CPUthermalIsBatteryWarningItem', x)
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

    def test_thermal_throttle_bypass_switch(self):
        p = read('Settings/FRootListController.m')
        self.assertIn('"ignoreThermalThrottle"', p)
        self.assertIn('彻底屏蔽温度检测', p)

    def test_thermal_sensor_readings_zeroed(self):
        t = read('Tweak.x')
        self.assertIn('static BOOL g_ignoreThermalThrottle', t)
        # 传感器读数 Hook 已在 CommonProduct 与 ThermalControl 存在
        self.assertGreaterEqual(t.count('- (int)dieTempFilteredMaxAverage'), 2)
        # 决策链模板（VOID0/RELEASE/EFFORT）均已纳入新开关条件
        self.assertGreaterEqual(t.count('thermalThrottleIgnored()'), 8)

    def test_thermal_bypass_independent_of_powermode(self):
        t = read('Tweak.x')
        # 闸门函数同时读取 g_enabled 与 g_ignoreThermalThrottle，独立于运行方式
        self.assertIn('runtimeConfigSnapshot(&enabled, NULL, NULL, NULL, &ignoreThrottle);', t)

if __name__ == '__main__':
    unittest.main()
