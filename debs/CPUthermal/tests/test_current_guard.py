"""isolation.9「电流防降频」契约与行为模型测试。

契约部分直接读取源码/面板；行为部分用等价 Python 模型复现
Tools/CPUthermalChargeTool.m 的 5 秒采样逻辑，阈值全部从源码解析，
避免模型与实现漂移。argv 中不依赖任何真机。
"""
import plistlib
import re
import unittest
from pathlib import Path

S = Path(__file__).resolve().parents[1]
CHARGE_TOOL = (S / 'Tools/CPUthermalChargeTool.m').read_text()
TWEAK = (S / 'Tweak.x').read_text()
COMPAT = (S / 'include/CPUthermalCompat.h').read_text()
PANEL = plistlib.loads((S / 'Settings/Root.plist').read_bytes())

SECTION_BEGIN = '// ===== 电流防降频（isolation.9）起始 ====='
SECTION_END = '// ===== 电流防降频（isolation.9）结束 ====='
GUARD_SECTION = CHARGE_TOOL.split(SECTION_BEGIN, 1)[1].split(SECTION_END, 1)[0]

STRESS_NOTIF = 'com.huayuarc.cputhermal/currentStress'
CHARGE_KEYS = ('ExternalConnected', 'PredictiveChargingInhibit', 'ChargingCurrentLimit', 'ChargeCurrentLimit')


def constants_from_source():
    """从 ChargeTool 源码解析阈值常量，保证模型与实现同源。"""
    found = {}
    for name, value in re.findall(r'static const (?:double|int|CFAbsoluteTime) (kCurrentGuard\w+) = (-?[\d.]+);', GUARD_SECTION):
        found[name] = float(value)
    return found


C = constants_from_source()


class NumberParsing(unittest.TestCase):
    """CPUthermalNumberValue：容忍 CFNumber 整数/浮点/布尔与 CFString。"""

    @staticmethod
    def parse(value):
        """与 CPUthermalNumberValue 等价的严格解析：int/float/bool 与纯数字字符串。"""
        if isinstance(value, bool):
            return (1.0 if value else 0.0)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            text = value.strip()
            if not text:
                return None
            try:
                return float(text)
            except ValueError:
                return None
        return None

    def test_source_handles_number_bool_and_string(self):
        self.assertIn('CFNumberGetTypeID()', COMPAT)
        self.assertIn('CFBooleanGetTypeID()', COMPAT)
        self.assertIn('CFStringGetTypeID()', COMPAT)
        self.assertIn('strtod(', COMPAT)
        self.assertIn('kCFNumberDoubleType', COMPAT)
        self.assertIn('CFNumberGetValue', COMPAT)

    def test_model_accepts_int_float_bool_and_numeric_string(self):
        self.assertEqual(self.parse(3000), 3000.0)
        self.assertEqual(self.parse(1500.5), 1500.5)
        self.assertEqual(self.parse(True), 1.0)
        self.assertEqual(self.parse(False), 0.0)
        self.assertEqual(self.parse('  3000 '), 3000.0)
        self.assertEqual(self.parse('-950'), -950.0)

    def test_model_rejects_garbage_and_units(self):
        for bad in ('', '   ', 'nan-', 'abc', '3000 mA', 'n/a'):
            self.assertIsNone(self.parse(bad), bad)
        # 尾随非数字内容按不可解析处理：宁可不写，也不误写
        self.assertIn("if (end && *end != '\\0') return NO;", COMPAT)

    def test_fallback_key_reader_skips_missing_keys(self):
        self.assertIn('IORegistryEntryCreateCFProperty', COMPAT)
        self.assertIn('if (!property) continue;', COMPAT)
        self.assertIn('if (matchedKey) *matchedKey = key;', COMPAT)


class GuardModel:
    """ChargeTool 5 秒采样的等价模型（阈值取自源码常量）。"""

    def __init__(self, values, keys=('AdapterCurrentLimit', 'USBPDCurrentLimit'), clock=0.0):
        self.keys = list(keys)
        self.values = dict(values)          # 键缺失 = 不在字典里
        self.clock = clock
        self.originals = None
        self.persisted = None
        self.owns = False
        self.discharge_streak = 0
        self.release_streak = 0
        self.stress_streak = 0
        self.last_post = None
        self.present_writes = []
        self.restore_writes = []
        self.posts = []
        self.persisted_before_first_write = False

    def present(self, key):
        return self.values.get(key)

    def tick(self, amperage, connected=True, enabled=True, advance=5.0):
        self.clock += advance
        if not enabled:
            self.restore()
            return
        if not connected:
            if amperage is not None and abs(amperage) >= C['kCurrentGuardStressCurrentMA']:
                self.stress_streak += 1
                if self.stress_streak >= C['kCurrentGuardStressSamples']:
                    self.post()
            elif amperage is None or abs(amperage) < C['kCurrentGuardStressClearMA']:
                self.stress_streak = 0
            self.restore()
            return
        self.stress_streak = 0
        if amperage is None:
            return
        if amperage <= C['kCurrentGuardAssistCurrentMA']:
            self.release_streak = 0
            self.discharge_streak = min(self.discharge_streak + 1, int(C['kCurrentGuardAssistSamples']))
            if self.discharge_streak >= C['kCurrentGuardAssistSamples']:
                self.raise_limits()
        elif amperage > C['kCurrentGuardReleaseCurrentMA']:
            self.discharge_streak = 0
            self.release_streak = min(self.release_streak + 1, int(C['kCurrentGuardReleaseSamples']))
            if self.release_streak >= C['kCurrentGuardReleaseSamples']:
                self.restore()

    def raise_limits(self):
        originals = dict(self.originals or {})
        persisted_count = len(originals)
        wrote = False
        for key in ('AdapterCurrentLimit', 'USBPDCurrentLimit'):
            if key not in self.keys or self.present(key) is None:
                continue                              # 键不存在：跳过该键
            if self.present(key) >= C['kCurrentGuardRaiseLimitMA']:
                continue                              # 已不低于目标：不降
            originals.setdefault(key, self.present(key))
            if not wrote and not self.owns:
                self.persisted = dict(originals)      # 首个键实际写入前持久化原值
                self.persisted_before_first_write = True
            self.values[key] = C['kCurrentGuardRaiseLimitMA']
            self.present_writes.append((key, C['kCurrentGuardRaiseLimitMA']))
            wrote = True
            self.owns = True
            self.originals = originals
        if not wrote and not self.owns:
            self.persisted = None
        elif wrote and len(originals) > persisted_count:
            self.persisted = dict(originals)          # 补齐本次新增键的原值

    def restore(self):
        limits = self.originals or self.persisted or {}
        if not limits:
            self.owns = False
            self.originals = None
            self.discharge_streak = 0
            self.release_streak = 0
            return
        for key, value in limits.items():
            self.values[key] = value
            self.restore_writes.append((key, value))
        self.owns = False
        self.originals = None
        self.persisted = None
        self.discharge_streak = 0
        self.release_streak = 0

    def post(self):
        if self.last_post is not None and self.clock - self.last_post < C['kCurrentGuardStressPostInterval']:
            return
        self.last_post = self.clock
        self.posts.append(self.clock)


class GuardBehaviour(unittest.TestCase):
    def test_thresholds_match_spec(self):
        self.assertEqual(C['kCurrentGuardAssistCurrentMA'], -50.0)
        self.assertEqual(C['kCurrentGuardAssistSamples'], 3.0)
        self.assertEqual(C['kCurrentGuardRaiseLimitMA'], 3000.0)
        self.assertEqual(C['kCurrentGuardReleaseCurrentMA'], -10.0)
        self.assertEqual(C['kCurrentGuardReleaseSamples'], 12.0)
        self.assertEqual(C['kCurrentGuardStressCurrentMA'], 2000.0)
        self.assertEqual(C['kCurrentGuardStressSamples'], 3.0)
        self.assertEqual(C['kCurrentGuardStressClearMA'], 1200.0)
        self.assertEqual(C['kCurrentGuardStressPostInterval'], 30.0)

    def test_three_samples_trigger_two_do_not(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        guard.tick(-300)
        guard.tick(-300)
        self.assertEqual(guard.present_writes, [])
        guard.tick(-300)
        self.assertEqual(guard.present_writes, [('AdapterCurrentLimit', 3000.0), ('USBPDCurrentLimit', 3000.0)])

    def test_only_raise_never_lower_or_exceed_cap(self):
        high = GuardModel({'AdapterCurrentLimit': 4000, 'USBPDCurrentLimit': 4500})
        for _ in range(6):
            high.tick(-900)
        self.assertEqual(high.present_writes, [])                       # 高于上限：不降
        self.assertEqual(high.present('AdapterCurrentLimit'), 4000)
        at_cap = GuardModel({'AdapterCurrentLimit': 3000, 'USBPDCurrentLimit': 2500})
        for _ in range(6):
            at_cap.tick(-900)
        self.assertEqual(at_cap.present_writes, [('USBPDCurrentLimit', 3000.0)])
        self.assertTrue(all(v <= 3000.0 for _, v in at_cap.present_writes))

    def test_original_persisted_before_first_write(self):
        guard = GuardModel({'AdapterCurrentLimit': 1200, 'USBPDCurrentLimit': 900})
        for _ in range(3):
            guard.tick(-600)
        self.assertTrue(guard.persisted_before_first_write)   # 首个键写入前就已持久化
        self.assertEqual(guard.persisted, {'AdapterCurrentLimit': 1200, 'USBPDCurrentLimit': 900})
        self.assertEqual(guard.originals, guard.persisted)

    def test_release_after_twelve_samples_and_original_restored(self):
        guard = GuardModel({'AdapterCurrentLimit': 1200, 'USBPDCurrentLimit': 900})
        for _ in range(3):
            guard.tick(-600)
        for _ in range(11):
            guard.tick(150)
        self.assertEqual(guard.restore_writes, [])
        guard.tick(150)
        self.assertEqual(guard.restore_writes, [('AdapterCurrentLimit', 1200), ('USBPDCurrentLimit', 900)])
        self.assertFalse(guard.owns)
        self.assertIsNone(guard.persisted)

    def test_dead_band_between_thresholds_holds_state(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(3):
            guard.tick(-600)
        for _ in range(40):
            guard.tick(-30)                                            # -50 < i <= -10：不提升也不释放
        self.assertTrue(guard.owns)
        self.assertEqual(guard.restore_writes, [])

    def test_adapter_unplug_releases_immediately(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(3):
            guard.tick(-600)
        guard.tick(-400, connected=False)
        self.assertEqual(guard.restore_writes, [('AdapterCurrentLimit', 1000), ('USBPDCurrentLimit', 1000)])

    def test_disable_releases(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(3):
            guard.tick(-600)
        guard.tick(-600, enabled=False)
        self.assertEqual(len(guard.restore_writes), 2)

    def test_key_fallback_order_and_missing_keys(self):
        only_pd = GuardModel({'USBPDCurrentLimit': 800}, keys=('USBPDCurrentLimit',))
        for _ in range(3):
            only_pd.tick(-700)
        self.assertEqual(only_pd.present_writes, [('USBPDCurrentLimit', 3000.0)])
        none = GuardModel({})
        for _ in range(6):
            none.tick(-700)
        self.assertEqual(none.present_writes, [])                      # 全部缺失：安全降级 no-op
        self.assertIsNone(none.persisted)

    def test_unreadable_current_is_noop(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(9):
            guard.tick(None)
        self.assertEqual(guard.present_writes, [])
        self.assertEqual(guard.restore_writes, [])
        self.assertEqual(guard.posts, [])

    def test_discharge_stress_notify_after_three_samples(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        guard.tick(-2500, connected=False)
        guard.tick(-2500, connected=False)
        self.assertEqual(guard.posts, [])
        guard.tick(-2500, connected=False)
        self.assertEqual(len(guard.posts), 1)

    def test_discharge_stress_notify_throttled_to_30s(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(30):
            guard.tick(-2600, connected=False)                         # 150 秒持续大电流放电
        self.assertEqual(len(guard.posts), 5)                          # 30s 一次：t=15,45,75,105,135
        self.assertEqual([round(p) for p in guard.posts], [15, 45, 75, 105, 135])
        for first, second in zip(guard.posts, guard.posts[1:]):
            self.assertGreaterEqual(second - first, 30.0)

    def test_discharge_stress_stops_below_clear_threshold(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(3):
            guard.tick(-2500, connected=False)
        guard.tick(-900, connected=False)                              # < 1200mA：停止并清 streak
        self.assertEqual(guard.stress_streak, 0)
        for _ in range(2):
            guard.tick(-2500, connected=False)
        self.assertEqual(len(guard.posts), 1)                          # 未重新满 3 次采样

    def test_connected_high_current_does_not_notify(self):
        guard = GuardModel({'AdapterCurrentLimit': 1000, 'USBPDCurrentLimit': 1000})
        for _ in range(20):
            guard.tick(-2500, connected=True)
        self.assertEqual(guard.posts, [])


class Contract(unittest.TestCase):
    def test_panel_group_switch_and_default(self):
        items = PANEL['items']
        index = [i for i, x in enumerate(items) if x.get('label') == '电流防降频']
        self.assertEqual(len(index), 1)
        group = items[index[0]]
        self.assertEqual(group.get('cell'), 'PSGroupCell')
        footer = group.get('footerText', '')
        for phrase in ('充放电电流', '适配器输入电流上限', '只升不降', '3000', '重申满预算', '发热', '硬件'):
            self.assertIn(phrase, footer)
        switch = items[index[0] + 1]
        self.assertEqual(switch.get('cell'), 'PSSwitchCell')
        self.assertEqual(switch.get('key'), 'currentGuardEnabled')
        self.assertEqual(switch.get('defaults'), 'com.huayuarc.cputhermal')
        self.assertIs(switch.get('default'), True)
        self.assertNotEqual(switch.get('default'), False)

    def test_panel_has_no_orphan_group(self):
        items = PANEL['items']
        for i, item in enumerate(items):
            if item.get('cell') != 'PSGroupCell':
                continue
            self.assertTrue(item.get('label') or item.get('footerText'), i)
            self.assertLess(i + 1, len(items))
            self.assertNotEqual(items[i + 1].get('cell'), 'PSGroupCell')

    def test_no_charge_or_stop_charging_key_in_new_code(self):
        for key in CHARGE_KEYS:
            self.assertNotIn(key, GUARD_SECTION, key)
        # 新代码只写两个适配器限流键
        self.assertEqual(sorted(set(re.findall(r'S\("(\w+Limit)"\)', GUARD_SECTION))),
                         ['AdapterCurrentLimit', 'USBPDCurrentLimit'])
        self.assertIn('CurrentGuardLimitKeys', GUARD_SECTION)
        self.assertIn('return @[S("AdapterCurrentLimit"), S("USBPDCurrentLimit")];', GUARD_SECTION)

    def test_only_expected_prefs_key_persisted(self):
        guard_keys = set(re.findall(r'S\("(__\w+)"\)', GUARD_SECTION))
        self.assertEqual(guard_keys, {'__currentGuardOriginalLimits'})
        self.assertIn('CPUthermalWritePrefs(prefs)', GUARD_SECTION)
        self.assertNotIn('__smartCharge', GUARD_SECTION)

    def test_no_charge_timer_change(self):
        self.assertIn('[NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:', CHARGE_TOOL)
        self.assertEqual(CHARGE_TOOL.count('scheduledTimerWithTimeInterval:5.0 repeats:YES block:'), 1)
        # 15 秒回调仍然只调用 EvaluateBattery；新采样没有塞进旧节奏
        fifteen = CHARGE_TOOL.split('scheduledTimerWithTimeInterval:15.0 repeats:YES block:', 1)[1].split('}]', 1)[0]
        self.assertIn('EvaluateBattery();', fifteen)
        self.assertNotIn('EvaluateCurrentGuard', fifteen)
        self.assertEqual(CHARGE_TOOL.count('EvaluateCurrentGuard();'), 1)   # 仅 5 秒 timer 调用
        self.assertNotIn('EvaluateBattery', GUARD_SECTION)
        self.assertNotIn('smartChargeStopLevel', GUARD_SECTION)

    def test_restore_paths_wired(self):
        self.assertEqual(GUARD_SECTION.count('static void RestoreCurrentGuardLimits(void) {'), 1)
        reset_body = CHARGE_TOOL.split('static BOOL ResetCharging(void) {', 1)[1].split('}', 1)[0]
        self.assertIn('RestoreCurrentGuardLimits();', reset_body)
        self.assertIn('RestoreOwnedState();', reset_body)
        signal_body = CHARGE_TOOL.split('static void SignalHandler(int signalNumber) {', 1)[1].split('}', 1)[0]
        self.assertIn('ResetCharging();', signal_body)
        self.assertIn('signal(SIGTERM, SignalHandler); signal(SIGINT, SignalHandler); signal(SIGHUP, SignalHandler);', CHARGE_TOOL)
        self.assertIn("strcmp(argv[1], \"reset\") == 0", CHARGE_TOOL)
        self.assertIn('if (!CurrentGuardEnabled(prefs)) { RestoreCurrentGuardLimits(); return; }', GUARD_SECTION)
        self.assertIn('RestoreCurrentGuardLimits();\n        IOObjectRelease(service);', GUARD_SECTION)

    def test_feature_default_on_in_code(self):
        self.assertIn('static BOOL CurrentGuardEnabled(NSDictionary *prefs) {\n    return BoolPreference(prefs, S("currentGuardEnabled"), YES);', CHARGE_TOOL)

    def test_no_file_logging_in_new_code(self):
        self.assertNotIn('createFileAtPath', GUARD_SECTION)
        self.assertNotIn('fileHandleForWriting', GUARD_SECTION)
        self.assertNotIn('NSLog', GUARD_SECTION)
        self.assertNotIn('fopen', GUARD_SECTION)

    def test_notification_name_shared_by_tool_and_tweak(self):
        self.assertIn('static const char *kCPUthermalCurrentStressNotifC = "%s";' % STRESS_NOTIF, COMPAT)
        self.assertIn('(void)notify_post(kCPUthermalCurrentStressNotifC);', GUARD_SECTION)
        self.assertIn('#import <CPUthermalCompat.h>', CHARGE_TOOL)
        self.assertIn('#include <CPUthermalCompat.h>', TWEAK)

    def test_tweak_observer_uses_engine_queue_with_throttle(self):
        handler = TWEAK.split('static void handleCurrentStressToken(int token) {', 1)[1].split('\n}', 1)[0]
        self.assertIn('if (!shouldApplyFullCPUProtection()) return;', handler)
        self.assertIn('>= 20.0', handler)
        self.assertIn('applyFullPowerToCommonProduct();', handler)
        self.assertIn('restoreFullPowerToTrackedControllers();', handler)
        self.assertNotIn('dispatch_after', handler)
        self.assertNotIn('NSTimer', handler)
        self.assertNotIn('dispatch_source', handler)
        registration = TWEAK.split('static void registerCurrentStressObserver(void) {', 1)[1].split('\n}', 1)[0]
        self.assertIn('notify_register_dispatch(kCPUthermalCurrentStressNotifC, &g_currentStressToken, CPUthermalEngineQueue()', registration)
        self.assertIn('registerCurrentStressObserver();', TWEAK.split('%ctor {', 1)[1])
        self.assertEqual(TWEAK.count('registerCurrentStressObserver();'), 1)   # 仅 %ctor 调用

    def test_tweak_keeps_isolation8_floor_semantics(self):
        self.assertIn('static const int kUnrestrictedPowerLimitMW = 65000;', TWEAK)
        self.assertIn('static const int kFullPowerCPULevel = 0;', TWEAK)
        self.assertIn('static const int kLowPowerCPULevel = 2;', TWEAK)
        self.assertIn('static const int kLowPowerPowerLimitMW = 2500;', TWEAK)
        self.assertIn('return runtimeProtectionEnabled() && isFullPowerMode();', TWEAK)
        for removed in ('force120HzEnable', 'CPUthermalThrottleLog', 'DLogToFile', 'powerd'):
            self.assertNotIn(removed, TWEAK)

    def test_cross_version_helpers_used_by_new_code_path(self):
        for helper in ('CPUthermalSystemMajorVersion', 'CPUthermalNumberValue', 'CPUthermalPropertyNumber'):
            self.assertIn(helper, COMPAT)
        self.assertIn('CPUthermalPropertyNumber(service, @[S("InstantAmperage"), S("Amperage")], &amperage, NULL)', GUARD_SECTION)
        self.assertIn('CPUthermalPropertyNumber(service, @[key], &present, NULL)', GUARD_SECTION)
        self.assertIn('CPUthermalNumberValue(limits[key], &original)', GUARD_SECTION)
        # 原值记录完整性：首个键写入前持久化，写完补齐本次新增键（只在有新增时写一次 prefs）
        self.assertIn('if (!wrote && !gCurrentGuardOwnsLimits) SaveCurrentGuardOriginalLimits(originals);', GUARD_SECTION)
        self.assertIn('} else if (wrote && originals.count > persistedCount) {', GUARD_SECTION)
        self.assertIn('SaveCurrentGuardOriginalLimits(originals);\n    }', GUARD_SECTION)
        self.assertIn('#ifndef CPUTHERMAL_COMPAT_H', COMPAT)

    def test_version_bumped(self):
        self.assertIn('Version: 1.6.2-154+isolation.11', (S / 'control').read_text())
        self.assertIn('1.6.2-154+isolation.11', (S / 'README.md').read_text())


if __name__ == '__main__':
    unittest.main()
