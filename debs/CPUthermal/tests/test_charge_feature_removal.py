"""功能精简契约：旧实现不得回归，智能停充与共享兼容助手保留。"""
import hashlib
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TOOL = (P / 'Tools/CPUthermalChargeTool.m').read_text()
PANEL = (P / 'Settings/FRootListController.m').read_text()
COMPAT = (P / 'include/CPUthermalCompat.h').read_text()
# 拼接构造禁用词，让仓库扫描包含本测试而不会自命中。
REMOVED = ('Current' + 'Guard', 'current' + 'GuardEnabled',
           'current' + 'Stress', 'Current' + 'Stress', 'current_' + 'guard',
           '电流' + '防降频')
CURRENT_IO = ('Instant' + 'Amperage', 'Amper' + 'age',
              'Adapter' + 'CurrentLimit', 'USBPD' + 'CurrentLimit')
TEXT_SUFFIXES = {'.x', '.xm', '.m', '.h', '.inc', '.plist', '.sh', '.in',
                 '.md', '.py', '.json', '.txt', '.entitlements'}


def function(text, marker):
    return marker + text.split(marker, 1)[1].split('\n}', 1)[0] + '\n}'


class ChargeFeatureRemoval(unittest.TestCase):
    def test_removed_symbols_and_description_absent_everywhere(self):
        self.assertFalse((P / 'tests' / ('test_current_' + 'guard.py')).exists())
        for path in P.rglob('*'):
            if not path.is_file():
                continue
            if path.name not in ('Makefile', 'control') and path.suffix not in TEXT_SUFFIXES:
                continue
            text = path.read_text(errors='replace').casefold()
            for token in REMOVED:
                with self.subTest(path=str(path.relative_to(P)), token=token):
                    self.assertNotIn(token.casefold(), text)

    def test_current_sampling_and_limit_writes_absent(self):
        # 不只查旧函数名，也防止改名后保留输入采样或限流写入。
        for path in P.rglob('*'):
            if path.is_file() and path.suffix in ('.x', '.xm', '.m', '.h', '.inc'):
                text = path.read_text()
                for token in CURRENT_IO:
                    self.assertNotIn(token, text, str(path.relative_to(P)))
        self.assertNotIn('notify_post(', TOOL)

    def test_charge_daemon_keeps_only_original_15_second_timer(self):
        self.assertEqual(re.findall(r'scheduledTimerWithTimeInterval:([\d.]+)', TOOL), ['15.0'])
        timer = TOOL.split('scheduledTimerWithTimeInterval:15.0', 1)[1].split('}];', 1)[0]
        self.assertIn('@autoreleasepool { EvaluateBattery(); }', timer)
        self.assertEqual(TOOL.count('EvaluateBattery();'), 3)  # 设置通知、15 秒 timer、启动
        self.assertIn('notify_register_dispatch(kCPUthermalSettingsChangedNotifC', TOOL)

    def test_original_smart_charge_functions_byte_preserved(self):
        # isolation.16 原函数指纹：精确锁住阈值、5% 回差、ownership 与恢复顺序。
        expected = {
            'static void EvaluateBattery(void) {': 'a003404afb17d5c7d3953cab1850a65b94c38aa58787336015567eb19d554c06',
            'static void RestoreOwnedState(void) {': 'cc726dda4d54bf8529ee3dc25cc86586df7cb0658422f9284a06096d0cb410a6',
            'static void LoadOwnership(void) {': '021f47691f5dc3db1b784faefa0432f3e1d86cc6231ddc0948925f7ee3df51a0',
            'static void SaveOwnership(void) {': '9f5f6f2a8d066bd9fd8652e50d24fc44d320f19905713425278972a7caa6dfe0',
        }
        for marker, digest in expected.items():
            with self.subTest(function=marker):
                self.assertEqual(hashlib.sha256(function(TOOL, marker).encode()).hexdigest(), digest)

    def test_reset_and_signal_restore_only_smart_charge_ownership(self):
        self.assertEqual(function(TOOL, 'static BOOL ResetCharging(void) {'),
                         'static BOOL ResetCharging(void) {\n'
                         '    RestoreOwnedState();\n'
                         '    return !gOwnsInhibit && !gOwnsInflowDisable;\n}')
        self.assertIn('strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;', TOOL)
        self.assertIn('ResetCharging();', function(TOOL, 'static void SignalHandler(int signalNumber) {'))
        for signal in ('SIGTERM', 'SIGINT', 'SIGHUP'):
            self.assertIn('signal(%s, SignalHandler)' % signal, TOOL)

    def test_compat_read_helpers_kept_without_new_side_effects(self):
        for signature in ('CPUthermalSystemMajorVersion(void)', 'CPUthermalNumberValue(id value, double *out)',
                          'CPUthermalPropertyNumber(io_service_t service, NSArray<NSString *> *keys, double *out, NSString **matchedKey)'):
            self.assertIn(signature, COMPAT)
        self.assertIn('IORegistryEntryCreateCFProperty(', COMPAT)
        self.assertIn('strtod(utf8, &end)', COMPAT)
        for token in ('IORegistryEntrySetCF', 'notify_', 'scheduledTimer', 'CPUthermalWritePrefs'):
            self.assertNotIn(token, COMPAT)

    def test_panel_has_seven_remaining_default_off_switches(self):
        keys = re.findall(r'ITEM\("[^"]+", "([^"]+)", PSSwitchCell, \[NSNumber numberWithBool:NO\]', PANEL)
        self.assertEqual(keys, ['lockWhenFaceDown', 'ignoreThermalThrottle', 'sunlightLockedEnabled', 'blockThermalPopup',
                                'suppressBatteryServiceWarnings', 'smartChargeEnabled'])
        self.assertEqual(len(re.findall(r'^\s*GROUP\(', PANEL, re.M)), 9)


if __name__ == '__main__':
    unittest.main(verbosity=2)
