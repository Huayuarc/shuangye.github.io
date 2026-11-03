"""isolation.46 契约：温控压暗的真正杠杆是面板亮度级 IOMFBBrightnessLevel。

真机实测（iPhone 14,2 / iOS 16.1.2 / DCP 面板）：
  BLNitsCap            = 1060 nits  （满值，没有被动过）
  CoreBrightness 请求   = 1060 nits
  IOMFBBrightnessLevel = 163.35 nits（被压暗且不会自愈）
只抬 BLNitsCap 的旧通道对这类机型完全无效。
"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TWEAK = (P / 'Tweak.x').read_text()


def block(text, marker, end='\n}'):
    return text.split(marker, 1)[1].split(end, 1)[0]


class DisplayLevelContracts(unittest.TestCase):
    def test_asserts_the_real_level_key(self):
        self.assertIn('"IOMFBBrightnessLevel"', TWEAK)
        body = block(TWEAK, 'static NSUInteger CPUthermalAssertDisplayBrightnessLevel(void) {')
        self.assertIn('AppleCLCD2', body)
        self.assertIn('kCPUthermalFixedPointScale', body)

    def test_target_is_the_user_request_never_the_panel_max(self):
        # 目标必须是 CoreBrightness 里用户当前请求的 Nits，随滑块变化；
        # 写死面板最大值会让人无法调暗屏幕。
        self.assertIn('static double CPUthermalRequestedDisplayNits(void)', TWEAK)
        requested = block(TWEAK, 'static double CPUthermalRequestedDisplayNits(void) {')
        self.assertIn('DisplayBrightness', requested)
        self.assertIn('Nits', requested)
        self.assertNotIn('g_maxBacklightBrightnessValue', requested)

    def test_only_raises_never_lowers(self):
        body = block(TWEAK, 'static NSUInteger CPUthermalAssertDisplayBrightnessLevel(void) {')
        self.assertIn('current < requested * kCPUthermalDisplayLevelRatio', body)
        # 写入值只能是请求值本身
        self.assertIn('requested * kCPUthermalFixedPointScale', body)

    def test_gated_to_full_power_mode_and_master_switch(self):
        body = block(TWEAK, 'static NSUInteger CPUthermalAssertDisplayBrightnessLevel(void) {')
        self.assertIn('isFullPowerMode()', body)
        self.assertIn('thermalDimmingPreventionEnabled()', body)
        self.assertIn('CPUthermalScreenIsBlanked()', body)

    def test_tick_is_lightweight_and_started_at_load(self):
        tick = block(TWEAK, 'static void CPUthermalDisplayLevelTick(void) {')
        self.assertIn('CPUthermalAssertDisplayBrightnessLevel();', tick)
        self.assertIn('5ull*NSEC_PER_SEC', tick)
        # 轻量自检不得做全树扫描
        self.assertNotIn('IORegistryCreateIterator', tick)
        ctor_start = TWEAK.index('%ctor {')
        self.assertIn('CPUthermalStartDisplayLevelTimer();', TWEAK[ctor_start:])

    def test_ratio_stays_in_safe_band(self):
        # 正常环境光补偿后实测约为请求值的 0.84，判据必须低于它，否则会与系统打架。
        self.assertIn('kCPUthermalDisplayLevelRatio = 0.75', TWEAK)


if __name__ == '__main__':
    unittest.main()
