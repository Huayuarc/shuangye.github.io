"""isolation.39 静态契约：应用侧热状态伪装 + 显示 nits 上限学习模块，以及它们与低功耗 CPU 链的隔离。"""
import plistlib
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
APP = (P / 'CPUthermalAppShield.xm').read_text()
DISPLAY = (P / 'CPUthermalDisplayShield.xm').read_text()
MAKEFILE = (P / 'Makefile').read_text()
CONTROL = (P / 'control').read_text()


class ApplicationShieldContracts(unittest.TestCase):
    def test_files_and_filter_present(self):
        self.assertTrue((P / 'CPUthermalAppShield.xm').exists())
        self.assertTrue((P / 'CPUthermalAppShield.plist').exists())
        # 过滤器无法表达“排除”，因此不带 Filter，由进程内闸门决定是否安装钩子。
        plist = plistlib.loads((P / 'CPUthermalAppShield.plist').read_bytes())
        self.assertNotIn('Filter', plist)

    def test_hooks_cover_thermal_read_sources(self):
        self.assertIn('- (NSInteger)thermalState {', APP)
        self.assertIn('_OSThermalNotificationCurrentLevel', APP)
        self.assertIn('notify_register_check', APP)
        self.assertIn('notify_get_state', APP)
        self.assertIn('*state = 0;', APP)

    def test_four_thermal_notify_names(self):
        for name in ('com.apple.system.thermalpressurelevel',
                     'com.apple.system.thermalnotification',
                     'com.apple.system.maxthermalsensorvalue',
                     'com.apple.system.thermalsunlightstate'):
            self.assertIn(name, APP)

    def test_excluded_processes_and_master_switch(self):
        for process in ('SpringBoard', 'thermalmonitord', 'backboardd', 'powerd'):
            self.assertIn('"%s"' % process, APP)
        # 总开关缺失时默认启用。
        self.assertIn('BOOL enabled = YES;', APP)
        self.assertIn('S("appShieldEnabled")', APP)
        self.assertIn('if (!CPUthermalAppShieldProcessAllowed()) return;', APP)


class DisplayShieldContracts(unittest.TestCase):
    def test_filter_targets_only_four_processes(self):
        self.assertTrue((P / 'CPUthermalDisplayShield.xm').exists())
        plist = plistlib.loads((P / 'CPUthermalDisplayShield.plist').read_bytes())
        self.assertEqual(plist['Filter']['Executables'],
                         ['SpringBoard', 'backboardd', 'brightnessd', 'displaypolicyd'])
        self.assertNotIn('Bundles', plist['Filter'])

    def test_hooks_both_iokit_writers(self):
        self.assertIn('%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry', DISPLAY)
        # IOServiceSetProperty 无公开声明，必须 dlsym 后 MSHookFunction。
        self.assertIn('dlsym(iokit, "IOServiceSetProperty")', DISPLAY)
        self.assertIn('MSHookFunction(symbol, (void *)CPUthermalHookedIOServiceSetProperty', DISPLAY)

    def test_learns_plausible_nits_and_fixed_point(self):
        self.assertIn('kCPUthermalShieldMinimumPlausibleNits = 400.0', DISPLAY)
        self.assertIn('kCPUthermalShieldMaximumPlausibleNits = 10000.0', DISPLAY)
        self.assertIn('kCPUthermalShieldFixedPointScale = 65536.0', DISPLAY)
        self.assertIn('double decoded = raw / kCPUthermalShieldFixedPointScale;', DISPLAY)

    def test_passes_through_zero_lifecycle_and_unknown(self):
        self.assertIn('if (!(raw > 0.0)) return nil;', DISPLAY)
        self.assertIn('static BOOL CPUthermalDisplayIsLifecycleKey(NSString *key)', DISPLAY)
        self.assertIn('if (!CPUthermalDisplayNumberFromCF(value, &raw)) return nil;', DISPLAY)

    def test_raise_only_never_lowers(self):
        self.assertIn('if (raw + 0.5 >= candidate) return nil;', DISPLAY)

    def test_never_commits_user_brightness(self):
        # 只替换上限键；从不写 DisplayBrightness/提交亮度。
        self.assertNotIn('DisplayBrightness', DISPLAY)
        self.assertNotIn('Commit', DISPLAY)
        self.assertNotIn('IOServiceRequestProbe', DISPLAY)


class BuildAndIsolationContracts(unittest.TestCase):
    def test_makefile_targets_and_roothide_links(self):
        names = re.findall(r'(?m)^TWEAK_NAME\s*=\s*(.+)$', MAKEFILE)[0].split()
        self.assertEqual(names, ['CPUthermal', 'CPUthermalSpringBoard', 'CPUthermalBatteryHealth',
                                 'CPUthermalBatteryComponent', '0hello120hz',
                                 'CPUthermalAppShield', 'CPUthermalDisplayShield'])
        for target in ('CPUthermalAppShield', 'CPUthermalDisplayShield'):
            self.assertIn('%s_FILES = %s.xm' % (target, target), MAKEFILE)
            self.assertIn('%s_LDFLAGS += $(ROOTHIDE_LDFLAGS)' % target, MAKEFILE)
            self.assertIn('%s_LIBRARIES = substrate' % target, MAKEFILE)

    def test_modules_do_not_touch_low_power_cpu_chain(self):
        for source in (APP, DISPLAY):
            for term in ('powerMode', 'setCPULevel', 'setCPUPowerCeiling',
                         'setCPUPowerFloor', 'MitigationController', 'CPULowPowerTarget'):
                self.assertNotIn(term, source, term)

    def test_version(self):
        self.assertIn('Version: 1.6.2-158+isolation.39', CONTROL)


if __name__ == '__main__':
    unittest.main()
