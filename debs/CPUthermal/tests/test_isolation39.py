import plistlib
import unittest
from pathlib import Path

S = Path(__file__).resolve().parents[1]
APP = (S / 'CPUthermalAppShield.xm').read_text()
DISPLAY = (S / 'CPUthermalDisplayShield.xm').read_text()
MAKEFILE = (S / 'Makefile').read_text()


class Isolation39ThermalVisibilityAndDisplay(unittest.TestCase):
    def test_app_visible_thermal_paths_are_nominal(self):
        for term in ('NSProcessInfo', 'thermalState', '_OSThermalNotificationCurrentLevel',
                     'com.apple.system.thermalpressurelevel', 'com.apple.system.maxthermalsensorvalue',
                     'notify_register_check', 'notify_get_state'):
            self.assertIn(term, APP)
        for daemon in ('thermalmonitord', 'backboardd', 'powerd', 'SpringBoard'):
            self.assertIn(daemon, APP)

    def test_app_filter_is_class_based(self):
        f = plistlib.loads((S / 'CPUthermalAppShield.plist').read_bytes())['Filter']
        self.assertEqual(f['Classes'], ['NSProcessInfo'])
        self.assertEqual(f['Mode'], 'Any')

    def test_display_shield_is_only_raise_and_zero_passes(self):
        self.assertIn('if (raw <= 0.0) return nil;', DISPLAY)
        self.assertIn('nits + 0.5 >= learned', DISPLAY)
        self.assertIn('kCPUthermalDisplayMinimumCapNits = 400.0', DISPLAY)
        self.assertIn('kCPUthermalDisplayFixedPointScale = 65536.0', DISPLAY)
        self.assertNotIn('setBrightness', DISPLAY)
        self.assertNotIn('DisplayBrightness', DISPLAY)

    def test_display_filter_is_narrow(self):
        f = plistlib.loads((S / 'CPUthermalDisplayShield.plist').read_bytes())['Filter']
        self.assertEqual(f['Executables'], ['backboardd', 'brightnessd', 'displaypolicyd', 'SpringBoard'])

    def test_low_power_policy_is_untouched(self):
        for forbidden in ('isLowPowerMode', 'setCPULevel:', 'setCPULowPowerTarget:', 'CPUMaxPower'):
            self.assertNotIn(forbidden, APP)
            self.assertNotIn(forbidden, DISPLAY)

    def test_both_targets_are_built(self):
        for target in ('CPUthermalAppShield', 'CPUthermalDisplayShield'):
            self.assertIn(target + '_FILES', MAKEFILE)
            self.assertIn(target + '_LIBRARIES = substrate', MAKEFILE)


if __name__ == '__main__':
    unittest.main()
