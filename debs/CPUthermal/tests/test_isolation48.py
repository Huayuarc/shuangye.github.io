"""isolation.48 契约：面板亮度级必须由独立守护进程写，核心 tweak 不得再尝试。

实测证据（iPhone 14,2 / iOS 16.1.2）：
  核心 tweak 在 thermalmonitord 里写 AppleCLCD2 的 IOMFBBrightnessLevel
  → kr=0xE00002E2（内核拒绝），屏幕毫无变化；
  同样的写在带显示 IOKit 授权的用户态进程里 → kr=0 且立即生效。
所以“算目标值”和“真正写进去”必须拆成两个进程。
"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TWEAK = (P / 'Tweak.x').read_text()
TOOL = (P / 'Tools/CPUthermalDisplayTool.m').read_text()
MAKEFILE = (P / 'Makefile').read_text()
POSTINST = (P / 'scripts/postinst.in').read_text()
PRERM = (P / 'scripts/prerm.in').read_text()
PLIST = (P / 'layout/Library/LaunchDaemons/com.huayuarc.cputhermal.display.plist').read_text()
ENTS = (P / 'Tools/CPUthermalDisplayTool.entitlements').read_text()


class CoreMustNotWrite(unittest.TestCase):
    def test_core_has_no_level_write(self):
        # 核心再写一次也只是多一条被拒绝的日志，必须彻底移除。
        self.assertNotIn('IOMFBBrightnessLevel', TWEAK)

    def test_core_has_no_display_level_timer(self):
        self.assertNotIn('CPUthermalStartDisplayLevelTimer', TWEAK)
        self.assertNotIn('CPUthermalAssertDisplayBrightnessLevel', TWEAK)


class DaemonOwnsTheLever(unittest.TestCase):
    def test_writes_the_real_key(self):
        self.assertIn('IOMFBBrightnessLevel', TOOL)
        self.assertIn('AppleCLCD2', TOOL)

    def test_target_is_slider_request_capped_by_user_value(self):
        self.assertIn('kDisplayDefaultCeilingNits = 850.0', TOOL)
        self.assertIn('requested > ceiling ? ceiling : requested', TOOL)

    def test_ceiling_comes_from_settings_and_is_clamped(self):
        self.assertIn('displayNitsCeiling', TOOL)
        self.assertIn('kDisplayMinimumCeilingNits = 100.0', TOOL)
        self.assertIn('kDisplayMaximumCeilingNits = 2000.0', TOOL)
        settings = (P / 'Settings/FRootListController.m').read_text()
        self.assertIn('displayNitsCeiling', settings)
        self.assertIn('displayNitsLockEnabled', settings)
        self.assertIn('PSEditTextCell', settings)

    def test_deadband_and_floor(self):
        self.assertIn('kDisplayDeadbandNits = 8.0', TOOL)
        self.assertIn('kDisplayFloorNits = 20.0', TOOL)
        self.assertIn('fabs(current - target) > kDisplayDeadbandNits', TOOL)

    def test_gated_by_prefs(self):
        self.assertIn('CPUthermalReadPrefs()', TOOL)
        self.assertIn('powerMode', TOOL)
        self.assertIn('fullPower', TOOL)

    def test_tick_is_two_seconds(self):
        self.assertIn('kDisplayTickMicroseconds = 2000000', TOOL)


class Packaging(unittest.TestCase):
    def test_tool_built_and_signed(self):
        self.assertIn('CPUthermalDisplayTool', MAKEFILE)
        self.assertIn('CPUthermalDisplayTool_CODESIGN_FLAGS = -STools/CPUthermalDisplayTool.entitlements', MAKEFILE)
        self.assertIn('com.apple.security.iokit-user-client-class', ENTS)
        self.assertIn('IOMobileFramebufferUserClient', ENTS)

    def test_daemon_plist_and_lifecycle(self):
        self.assertIn('com.huayuarc.cputhermal.display', PLIST)
        self.assertIn('<key>KeepAlive</key><true/>', PLIST)
        self.assertIn('com.huayuarc.cputhermal.display.plist', POSTINST)
        self.assertIn('launchctl bootout system/com.huayuarc.cputhermal.display', PRERM)

    def test_rootless_path_rewrite_covers_both_daemons(self):
        self.assertIn('for n in charge display', MAKEFILE)


class DisplayShieldStaysSafe(unittest.TestCase):
    def test_shield_ctor_still_has_no_cross_process_calls(self):
        shield = (P / 'CPUthermalDisplayShield.xm').read_text()
        ctor = shield.split('%ctor {', 1)[1].split('\n}', 1)[0]
        ctor = '\n'.join(line.split('//', 1)[0] for line in ctor.splitlines())
        for forbidden in ('BrightnessSystemClient', 'dlopen('):
            self.assertNotIn(forbidden, ctor)


if __name__ == '__main__':
    unittest.main()
