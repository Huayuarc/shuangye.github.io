"""isolation.50 契约：不再周期回写用户亮度，显示热上限守卫继续保持安全。"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TWEAK = (P / 'Tweak.x').read_text()
MAKEFILE = (P / 'Makefile').read_text()
POSTINST = (P / 'scripts/postinst.in').read_text()
PRERM = (P / 'scripts/prerm.in').read_text()
SETTINGS = (P / 'Settings/FRootListController.m').read_text()


class CoreMustNotWrite(unittest.TestCase):
    def test_core_has_no_level_write_or_timer(self):
        for forbidden in ('IOMFBBrightnessLevel', 'CPUthermalStartDisplayLevelTimer',
                          'CPUthermalAssertDisplayBrightnessLevel'):
            self.assertNotIn(forbidden, TWEAK)


class SliderRemainsSystemOwned(unittest.TestCase):
    def test_periodic_display_tool_is_removed(self):
        self.assertFalse((P / 'Tools/CPUthermalDisplayTool.m').exists())
        self.assertFalse((P / 'Tools/CPUthermalDisplayTool.entitlements').exists())
        self.assertFalse((P / 'layout/Library/LaunchDaemons/com.huayuarc.cputhermal.display.plist').exists())
        self.assertNotIn('CPUthermalDisplayTool', MAKEFILE)
        self.assertNotIn('for n in charge display', MAKEFILE)

    def test_settings_no_longer_offer_brightness_lock(self):
        for forbidden in ('displayNitsLockEnabled', 'displayNitsCeiling',
                          '屏幕亮度锁定', '启用亮度锁定', '最高亮度 (nits)'):
            self.assertNotIn(forbidden, SETTINGS)

    def test_upgrade_stops_old_daemon_without_restarting_it(self):
        self.assertIn('launchctl bootout system/com.huayuarc.cputhermal.display', POSTINST)
        self.assertNotIn('launchctl bootstrap system @JBROOT@/Library/LaunchDaemons/com.huayuarc.cputhermal.display.plist', POSTINST)
        self.assertNotIn('launchctl kickstart -k system/com.huayuarc.cputhermal.display', POSTINST)
        self.assertNotIn('com.huayuarc.cputhermal.display', PRERM)


class DisplayShieldStaysSafe(unittest.TestCase):
    def test_shield_remains_packaged(self):
        self.assertIn('CPUthermalDisplayShield', MAKEFILE)
        self.assertTrue((P / 'CPUthermalDisplayShield.xm').exists())
        self.assertTrue((P / 'CPUthermalDisplayShield.plist').exists())

    def test_shield_ctor_still_has_no_cross_process_calls(self):
        shield = (P / 'CPUthermalDisplayShield.xm').read_text()
        ctor = shield.split('%ctor {', 1)[1].split('\n}', 1)[0]
        ctor = '\n'.join(line.split('//', 1)[0] for line in ctor.splitlines())
        for forbidden in ('BrightnessSystemClient', 'objc_getClass', 'dlopen('):
            self.assertNotIn(forbidden, ctor)


if __name__ == '__main__':
    unittest.main()
