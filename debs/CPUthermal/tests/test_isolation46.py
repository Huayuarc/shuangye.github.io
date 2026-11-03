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

    def test_only_writes_the_slider_request(self):
        body = block(TWEAK, 'static NSUInteger CPUthermalAssertDisplayBrightnessLevel(void) {')
        # 目标永远来自用户请求（并经上限裁剪），不会凭空写一个更大的值
        self.assertIn('requested > kCPUthermalFullModeCeilingNits', body)
        self.assertIn('target * kCPUthermalFixedPointScale', body)

    def test_deadband_prevents_flicker(self):
        body = block(TWEAK, 'static NSUInteger CPUthermalAssertDisplayBrightnessLevel(void) {')
        self.assertIn('fabs(current - target) > kCPUthermalDisplayLevelDeadbandNits', body)
        self.assertIn('kCPUthermalDisplayLevelDeadbandNits = 8.0', TWEAK)

    def test_gated_to_full_power_mode_and_master_switch(self):
        body = block(TWEAK, 'static NSUInteger CPUthermalAssertDisplayBrightnessLevel(void) {')
        self.assertIn('isFullPowerMode()', body)
        self.assertIn('thermalDimmingPreventionEnabled()', body)
        self.assertIn('CPUthermalScreenIsBlanked()', body)

    def test_tick_is_lightweight_and_started_at_load(self):
        tick = block(TWEAK, 'static void CPUthermalDisplayLevelTick(void) {')
        self.assertIn('CPUthermalAssertDisplayBrightnessLevel();', tick)
        self.assertIn('3ull*NSEC_PER_SEC', tick)
        # 轻量自检不得做全树扫描
        self.assertNotIn('IORegistryCreateIterator', tick)
        ctor_start = TWEAK.index('%ctor {')
        self.assertIn('CPUthermalStartDisplayLevelTimer();', TWEAK[ctor_start:])

    def test_ceiling_is_850_nits(self):
        # 13 Pro SDR 典型最大亮度；用户要求解除温控下稳定输出到该值。
        self.assertIn('kCPUthermalFullModeCeilingNits = 850.0', TWEAK)


if __name__ == '__main__':
    unittest.main()
