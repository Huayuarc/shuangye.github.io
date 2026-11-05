"""isolation.59 契约：上限巡检必须自启动，且不能把被压低的上限学成原生值。

真机实测（iPhone 14,2 / iOS 16.1.2）：isolation.58 装上后把 BLNitsCap 从 1060 写到 800，
五分钟内都没被抬回——因为 core 的巡检只在 thermalmonitord 读取背光配置时启动，
而它当次并没有走那条分支。同时 400 nits 的可信下限太低，400 被当成“原生上限”学进去了。
"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parent.parent
TWEAK = (P / 'Tweak.x').read_text()
SHIELD = (P / 'CPUthermalDisplayShield.xm').read_text()
TOOL = (P / 'Tools' / 'CPUthermalDisplayTool.m').read_text()
CONTROL = (P / 'control').read_text()


class CoreStartsOnItsOwn(unittest.TestCase):
    def test_ctor_starts_the_audit_timer(self):
        ctor = TWEAK.split('%ctor {', 1)[1]
        self.assertIn('CPUthermalStartBacklightAuditTimer();', ctor[:6000])

    def test_start_is_delayed_not_blocking(self):
        ctor = TWEAK.split('%ctor {', 1)[1]
        self.assertIn('dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull*NSEC_PER_SEC)', ctor[:6000])

    def test_fast_cap_tick_still_runs_from_the_starter(self):
        starter = TWEAK.split('static void CPUthermalStartBacklightAuditTimer(void) {', 1)[1]
        self.assertIn('CPUthermalFastCapTick();', starter[:400])


class PlausibleCeiling(unittest.TestCase):
    def test_core_floor_raised(self):
        self.assertIn('kCPUthermalMinimumPlausibleBacklightLimit = 600.0', TWEAK)

    def test_shield_floor_raised(self):
        self.assertIn('kCPUthermalDisplayMinimumCapNits = 600.0', SHIELD)

    def test_tool_cap_floor_raised(self):
        self.assertIn('kDisplayCapFloorNits = 600.0', TOOL)

    def test_cap_correction_works_at_low_brightness(self):
        self.assertIn('requested >= 50.0', TOOL)


class Version(unittest.TestCase):
    def test_version(self):
        self.assertIn('Version: 1.6.2-172+isolation.59', CONTROL)


if __name__ == '__main__':
    unittest.main()
