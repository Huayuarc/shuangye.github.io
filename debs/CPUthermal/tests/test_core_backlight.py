"""isolation.9 核心防降亮度契约（职责已从原独立显示模块并入 CPUthermal 核心）。

核心只注入 thermalmonitord：它只能事后纠正自己发出的写入，
无法拦截其它进程（CoreBrightness/显示驱动等）对亮度节点的写入。
本测试固化“只升不降”“面板上限学习”“事件+周期恢复”“低开销门控”“无文件日志”这些可静态验证的契约。
"""
import plistlib
import re
import unittest
from pathlib import Path

S = Path(__file__).resolve().parents[1]
TWEAK = (S / 'Tweak.x').read_text()
README = (S / 'README.md').read_text()
MAKEFILE = (S / 'Makefile').read_text()


def body(start):
    """按花括号配对截取函数体，兼容本工程“块级收尾花括号在行首”的混合缩进风格。"""
    text = TWEAK.split(start, 1)[1]
    depth = 0
    lines = []
    for line in text.splitlines():
        lines.append(line)
        depth += line.count('{') - line.count('}')
        if depth < 0:
            lines.pop()
            break
    return '\n'.join(lines)


class CoreBacklightContract(unittest.TestCase):
    def test_limit_key_set_includes_verified_keys(self):
        keys = TWEAK.split('static const char * const kCPUthermalBacklightLimitKeys[] = {', 1)[1].split('NULL};', 1)[0]
        for key in ('BLNitsCap', 'brightness-nits', 'IOMFB_brightness_limit', 'max-brightness', 'brightness-cap'):
            self.assertIn('"%s"' % key, keys, key)

    def test_matcher_covers_cap_and_nits_keys(self):
        matcher = body('static BOOL keyIsBacklightThermalLimit(NSString *key) {')
        self.assertIn('[lower isEqualToString:S("blnitscap")]', matcher)
        self.assertIn('[lower isEqualToString:S("brightness-nits")]', matcher)
        # 显示生命周期键永远不参与，避免锁屏/自动锁屏被当成亮度限制
        self.assertIn('if (keyIsDisplayLifecycleProperty(key)) return NO;', matcher)

    def test_replacement_is_only_raise(self):
        replacement = body('static id backlightReplacementMatchingValue(NSString *key, id originalValue) {')
        self.assertIn('if (original + 0.5 >= candidate) return nil;', replacement)
        self.assertIn('if (v <= 0.0) return nil;', replacement)
        self.assertIn('kCPUthermalFixedPointScale', replacement)
        # 面板上限学习：写入前先记住原值
        self.assertIn('CPUthermalRememberBacklightMaximum(originalValue);', replacement)
        # 只有真正低于候选上限时才替换，绝不把更高的原值压回上限
        self.assertEqual(replacement.count('return nil;'), 5)

    def test_raise_path_uses_only_raise_comparison(self):
        raise_body = body('static NSUInteger CPUthermalRaiseExistingBacklightLimits(void) {')
        self.assertIn('if (current + 0.5 < scaled) {', raise_body)
        self.assertIn('if(target<kCPUthermalMinimumPlausibleBacklightLimit)return 0;', raise_body)
        self.assertIn('if(!thermalDimmingPreventionEnabled()||CPUthermalScreenIsBlanked())return 0;', raise_body)
        self.assertIn('fixedPoint = (current > kCPUthermalFixedPointScale)', raise_body)

    def test_panel_max_learning_bounds(self):
        remember = body('static void CPUthermalRememberBacklightMaximum(id value) {')
        self.assertIn('kCPUthermalMinimumPlausibleBacklightLimit', remember)
        self.assertIn('v>10000.0', remember)
        self.assertIn('CPUthermalRememberCoreBrightnessMaximum', TWEAK)
        self.assertIn('"BrightnessSystemClient"', TWEAK)

    def test_recovery_triggers_periodic_wake_and_mode_switch(self):
        # 周期自检：20s，低开销，屏熄时提前返回
        tick = body('static void CPUthermalBacklightAuditTick(void) {')
        self.assertIn('CPUthermalCaptureExistingBacklightMaximum();', tick)
        self.assertIn('CPUthermalRaiseExistingBacklightLimits();', tick)
        self.assertIn('20ull*NSEC_PER_SEC', tick)
        self.assertEqual(TWEAK.count('CPUthermalStartBacklightAuditTimer'), 2)  # 定义 + 调用
        # 屏幕点亮/解锁复用模式应用中的统一恢复事务，不再叠加三轮 IORegistry 全树扫描。
        wake = body('static void restoreUserModeAfterWake(const char *source) {')
        self.assertNotIn('for (int i = 0; i < 3; i++)', wake)
        self.assertNotIn('CPUthermalRaiseExistingBacklightLimits();', wake)
        recovery = body('static void CPUthermalScheduleBacklightRecovery(void) {')
        self.assertIn('const double delays[] = {0.50, 3.00};', recovery)
        self.assertIn('QOS_CLASS_UTILITY', recovery)
        self.assertNotIn('QOS_CLASS_USER_INITIATED', recovery)
        # 模式切换：full 与 low 分支都会调度恢复
        self.assertGreaterEqual(TWEAK.count('CPUthermalScheduleBacklightRecovery();'), 3)

    def test_write_interception_is_core_owned_and_gated(self):
        hook = body('%hookf(kern_return_t, IORegistryEntrySetCFProperty, io_registry_entry_t entry, CFStringRef key, CFTypeRef value) {')
        self.assertIn('thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(keyString)', hook)
        self.assertIn('backlightReplacementMatchingValue', hook)
        setter = body('static kern_return_t hooked_IOServiceSetProperty(io_service_t service, CFStringRef key, CFTypeRef value) {')
        self.assertIn('thermalDimmingPreventionEnabled() && keyIsBacklightThermalLimit(keyString)', setter)
        # 拦截只作用于本进程（thermalmonitord）自己的写入
        self.assertIn('Filter', (S / 'CPUthermal.plist').read_text())

    def test_thermal_config_backlight_subtree_patched(self):
        self.assertIn('copyPropertiesByRemovingThermalLimits', TWEAK)
        self.assertIn('CPUthermalIsDisplayMitigationKey', TWEAK)
        self.assertIn('CPUthermalZeroDisplayMitigationValue', TWEAK)
        self.assertIn('"needsPushingTSFDtoDisplayDriver"', TWEAK)
        self.assertIn('"displayBrightnessMitigation"', TWEAK)

    def test_no_file_logging_and_low_overhead(self):
        for module in ('Tweak.x',):
            text = (S / module).read_text()
            self.assertNotIn('createFileAtPath', text)
            self.assertNotIn('fileHandleForWritingAtPath', text)
            self.assertNotIn('NSLog', text)
        # 亮度自检只有 20s 一个节拍，也没有引入 dispatch_source 高频定时器
        tick = body('static void CPUthermalBacklightAuditTick(void) {')
        schedule = body('static void CPUthermalScheduleBacklightRecovery(void) {')
        for chunk in (tick, schedule):
            self.assertNotIn('NSEC_PER_MSEC', chunk)
            self.assertNotIn('dispatch_source', chunk)
        self.assertEqual(tick.count('20ull*NSEC_PER_SEC'), 1)
        self.assertEqual(TWEAK.count('20ull*NSEC_PER_SEC'), 2)

    def test_readme_documents_weaker_scope_and_gate(self):
        for phrase in ('只能事后纠正', '无法拦截其它进程', '比被移除模块弱', '用户明确取舍'):
            self.assertIn(phrase, README, phrase)

    def test_makefile_has_four_tweaks_with_battery_health(self):
        names = re.findall(r'(?m)^TWEAK_NAME\s*=\s*(.+)$', MAKEFILE)[0].split()
        self.assertEqual(names, ['CPUthermal', 'CPUthermalSpringBoard', 'CPUthermalBatteryHealth', 'CPUthermalBatteryComponent', '0hello120hz'])
        self.assertEqual(len([n for n in names if n.startswith('CPUthermal')]), 4)


if __name__ == '__main__':
    unittest.main()
