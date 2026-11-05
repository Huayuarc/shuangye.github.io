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


class ShieldNeverBlocksUserDims(unittest.TestCase):
    """isolation.60：显示守卫不得吞掉面板亮度级写入。

    真机实测（172/isolation.59）：用户把亮度滑块拖到 54%，IOMFBBrightnessLevel 仍被顶在
    1060 nits，屏幕亮度完全不变——正是 isolation.57 的“满档断崖”拦截把用户自己的调暗
    写入丢掉了。亮度级的事只交给 CPUthermalDisplayTool（它读 CoreBrightness 的请求值，
    能区分用户意图与系统压暗），守卫只保留上限（cap）保护。
    """

    def test_shield_has_no_level_drop_suppressor(self):
        self.assertNotIn('CPUthermalShouldSuppressLevelDrop', SHIELD)
        self.assertNotIn('suppressed thermal panel level drop', SHIELD)

    def test_shield_still_protects_the_cap(self):
        self.assertIn('CPUthermalDisplayCapKey(key)', SHIELD)
        self.assertIn('CPUthermalProtectedDisplayCapValue', SHIELD)

    def test_shield_passes_writes_through(self):
        for hook in ('CPUthermalHookedRegistrySet', 'CPUthermalHookedServiceSet'):
            body = SHIELD.split('static kern_return_t %s(' % hook, 1)[1].split('\n}', 1)[0]
            self.assertIn('replacement ? (__bridge CFTypeRef)replacement : value', body)
            self.assertNotIn('return KERN_SUCCESS;', body)


class Version(unittest.TestCase):
    def test_version(self):
        self.assertIn('Version: 1.6.2-173+isolation.60', CONTROL)


if __name__ == '__main__':
    unittest.main()
