"""isolation.57 契约：亮度巡检必须是 0.5 秒级，并且先在写入路径上拦截温控压暗。

用户要求：系统触发暗屏时不能被人眼发现——所以三层都必须在线：
  1. 核心（thermalmonitord）每 0.5s 检查面板上限键；
  2. 显示守卫（backboardd 等）在写入路径上直接丢弃“满档断崖式”压暗；
  3. 显示守护（CPUthermalDisplayTool）每 0.5s 检查并把被压低的亮度级抬回。
"""
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parent.parent
TWEAK = (P / 'Tweak.x').read_text()
SHIELD = (P / 'CPUthermalDisplayShield.xm').read_text()
TOOL = (P / 'Tools' / 'CPUthermalDisplayTool.m').read_text()
CONTROL = (P / 'control').read_text()


class FastPolling(unittest.TestCase):
    def test_tool_polls_every_half_second(self):
        self.assertIn('kDisplayTickMicroseconds = 500000', TOOL)

    def test_tool_can_correct_again_after_half_second(self):
        self.assertIn('kDisplayCorrectionCooldown = 0.5', TOOL)

    def test_tool_judges_almost_immediately(self):
        self.assertIn('kDisplayStableSeconds = 0.35', TOOL)

    def test_tool_corrects_hard_collapse_without_learned_sample(self):
        self.assertIn('hardCollapse', TOOL)
        self.assertIn('ratio < 0.5', TOOL)
        self.assertIn('requested * (hardCollapse ? 0.85 : expected)', TOOL)

    def test_tool_caches_prefs_while_polling_fast(self):
        self.assertIn('static NSDictionary *CachedPrefs(void)', TOOL)
        self.assertIn('NSDictionary *prefs = CachedPrefs();', TOOL)

    def test_tool_reports_panel_limited_case(self):
        self.assertIn('PhysicalNits', TOOL)
        self.assertIn('panel-limited', TOOL)


class CoreFastCapTick(unittest.TestCase):
    def test_core_has_half_second_cap_tick(self):
        self.assertIn('static void CPUthermalFastCapTick(void) {', TWEAK)
        self.assertIn('500000000ull', TWEAK)

    def test_core_cap_tick_only_touches_cap_keys(self):
        tick = TWEAK.split('static void CPUthermalFastCapTick(void) {', 1)[1].split('static void CPUthermalBacklightAuditTick', 1)[0]
        self.assertIn('"BLNitsCap"', tick)
        self.assertIn('"brightness-nits"', tick)
        # 核心绝不写面板亮度级（只抬上限）。
        code = '\n'.join(line.split('//', 1)[0] for line in tick.splitlines())
        self.assertNotIn('IOMFBBrightnessLevel', code)

    def test_core_starts_the_fast_tick(self):
        starter = TWEAK.split('static void CPUthermalStartBacklightAuditTimer(void) {', 1)[1]
        self.assertIn('CPUthermalFastCapTick();', starter[:400])


class ShieldSuppressesDrop(unittest.TestCase):
    def test_shield_has_drop_suppressor(self):
        self.assertIn('CPUthermalShouldSuppressLevelDrop', SHIELD)
        self.assertIn('kShieldSuppressTopRatio', SHIELD)
        self.assertIn('kShieldSuppressTemperatureC', SHIELD)

    def test_shield_hooks_discard_the_write(self):
        for hook in ('CPUthermalHookedRegistrySet', 'CPUthermalHookedServiceSet'):
            body = SHIELD.split('static kern_return_t %s(' % hook, 1)[1].split('\n}', 1)[0]
            self.assertIn('CPUthermalShouldSuppressLevelDrop(', body)
            self.assertIn('return KERN_SUCCESS;', body)

    def test_shield_never_passes_zero_and_never_writes_values(self):
        body = SHIELD.split('static BOOL CPUthermalShouldSuppressLevelDrop(', 1)[1].split('\n}', 1)[0]
        self.assertIn('if (next <= 0.0) return NO;', body)
        self.assertIn('if (current < threshold) return NO;', body)
        # 只读取属性，不写任何属性
        self.assertNotIn('SetCFProperty', body)

    def test_shield_uses_local_registry_only(self):
        body = SHIELD.split('static BOOL CPUthermalShouldSuppressLevelDrop(', 1)[1].split('\n}', 1)[0]
        self.assertNotIn('objc_msgSend', body)
        self.assertNotIn('BrightnessSystemClient', body)


class Version(unittest.TestCase):
    def test_version(self):
        self.assertIn('Version: 1.6.2-171+isolation.58', CONTROL)


if __name__ == '__main__':
    unittest.main()
