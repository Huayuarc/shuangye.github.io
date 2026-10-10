#!/usr/bin/env python3
"""Pure-Python policy regression + source contracts; NOT an iOS hook/runtime test.
Run: python3 -m unittest discover -s tests -v
Models integral CFNumber conversion, 16.16 values, cached state and passthrough.
No third-party modules. Objective-C/IOKit ABI, notify semantics and firmware effects
still require macOS compilation and on-device testing.
"""
import math
import re
import threading
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'DisplayGuard.xm'
RAW_SCALE = 65536
KEYS = {'BLNitsCap': 'cap', 'brightness-nits': 'nits'}


def raw(nits):
    return int(math.floor(nits * RAW_SCALE + 0.5))


def number_raw(value):
    # CFBoolean, strings, data and non-finite/fractional numbers are not raw nits.
    if type(value) not in (int, float):
        return None
    if not math.isfinite(value) or value < 0 or value > 20000 * RAW_SCALE:
        return None
    return int(value) if int(value) == value else None


def panel_cap(model, properties):
    # Table taken from actual patched source so 625/800 regressions are enforced.
    table = dict((k, float(v)) for k, v in re.findall(r'@"(iPhone\d+,\d+)":@(\d+)', SOURCE.read_text()))
    if model in table:
        return table[model]
    best = 0.0
    for key in ('PanelMaxBrightness', 'nitsMax', 'IOMFB_max_brightness', 'IOMFB_brightness_max'):
        n = properties.get(key)
        if type(n) not in (int, float) or not math.isfinite(n):
            continue
        if n > RAW_SCALE and int(n) == n:
            n /= RAW_SCALE
        if 300 <= n <= 3000:
            best = max(best, n)
    return best


class Policy:
    def __init__(self, cap=850.0, slider=0.5):
        self.cap = raw(cap)
        self.slider = slider
        self.locked = 0
        self.blanked = 0
        self.notify_ok = True
        self.time = 0.0
        self.slider_time = -1.0
        self.cached_slider = -1.0
        self.prefs = {'enabled': False}
        self.slider_reads = 0
        self.tls = threading.local()

    def invalidate(self, prefs=False):
            self.slider_time = -1.0

    def user_slider(self):
        if self.slider_time < 0 or self.time - self.slider_time >= 0.2:
            self.slider_reads += 1
            self.cached_slider = self.slider
            self.slider_time = self.time
        return self.cached_slider

    def replacement(self, key, value):
        kind = KEYS.get(key) if type(key) is str else None
        if kind is None:
            return None
        value = number_raw(value)
        if value is None or not self.notify_ok or self.locked != 0 or self.blanked != 0 or self.cap <= 0:
            return None
        slider = self.user_slider()
        if not (0.02 < slider <= 1.0):
            return None
        target = self.cap if kind == 'cap' else raw(self.cap / RAW_SCALE * slider)
        if kind == 'nits' and (value == 0 or target - value <= RAW_SCALE):
            return None
        return target if value < target else None

    def single(self, api, key, value, original):
        if getattr(self.tls, 'depth', 0):
            return original(key, value)
        self.tls.depth = 1
        try:
            replacement = self.replacement(key, value)
            output = value if replacement is None else replacement
            result = original(key, output)
            return result
        finally:
            self.tls.depth = 0

    def many(self, properties, original):
        if getattr(self.tls, 'depth', 0):
            return original(properties)
        self.tls.depth = 1
        try:
            changed = None
            if type(properties) is dict:
                for key, value in properties.items():
                    replacement = self.replacement(key, value)
                    if replacement is not None:
                        if changed is None:
                            changed = properties.copy()
                        changed[key] = replacement
            result = original(properties if changed is None else changed)
            return result
        finally:
            self.tls.depth = 0


class StrategyTests(unittest.TestCase):
    def test_625_800_models_and_unknown_capability(self):
        for model, expected in [('iPhone12,1', 625), ('iPhone12,3', 800), ('iPhone14,2', 850)]:
            with self.subTest(model=model):
                cap = panel_cap(model, {'NitsPhysical': 163, 'BLNitsCap': raw(1060)})
                self.assertEqual(cap, expected)
                self.assertEqual(Policy(cap).replacement('BLNitsCap', raw(400)), raw(expected))
        self.assertEqual(panel_cap('unknown', {'PanelMaxBrightness': raw(800)}), 800)
        self.assertEqual(panel_cap('unknown', {'nitsMax': 625.0}), 625)
        self.assertEqual(panel_cap('unknown', {'NitsPhysical': 850, 'BLNitsCap': raw(1060)}), 0)
        self.assertEqual(panel_cap('unknown', {'nitsMax': 1.0}), 0)

    def test_integer_double_conversions_and_invalid_inputs(self):
        for v in (raw(163), float(raw(163))):
            self.assertEqual(Policy(slider=0.8).replacement('brightness-nits', v), raw(680))
        for v in (True, False, '10682368', b'data', None, {}, float('nan'), float('inf'), -1, 1.5, raw(20001)):
            with self.subTest(v=v):
                self.assertIsNone(Policy().replacement('brightness-nits', v))

    def test_exact_keys_no_slider_reads(self):
        p = Policy()
        for key in (None, 1, 'brightness', 'DisplayBrightness', 'FakeBLNitsCap', 'blnitscap', 'brightness-cap', 'nitsCap', 'IOMFB_brightness_limit'):
            p.single(0, key, raw(100), lambda k, v: -7)
        self.assertEqual(p.slider_reads, 0)

    def test_historic_lower_request_cannot_deadlock_target(self):
        p = Policy(slider=0.8)
        self.assertEqual(p.replacement('brightness-nits', raw(163.3)), raw(680))
        self.assertEqual(p.replacement('brightness-nits', raw(200)), raw(680))
        self.assertLess(raw(680), p.cap)

    def test_slider_zero_low_unknown_and_off_write(self):
        for slider in (0.0, 0.001, 0.02, -1.0, float('nan'), 1.1):
            with self.subTest(slider=slider):
                p = Policy(slider=slider)
                self.assertIsNone(p.replacement('brightness-nits', raw(1)))
                self.assertIsNone(p.replacement('BLNitsCap', raw(100)))
        self.assertIsNone(Policy(slider=1).replacement('brightness-nits', 0))

    def test_manual_lower_slider_does_not_use_old_high_watermark(self):
        p = Policy(slider=0.9)
        self.assertEqual(p.replacement('brightness-nits', raw(100)), raw(765))
        p.slider = 0.1
        p.invalidate()
        self.assertEqual(p.replacement('brightness-nits', raw(30)), raw(85))
        self.assertIsNone(p.replacement('brightness-nits', raw(85)))

    def test_lock_blank_unknown_and_unknown_model_passthrough(self):
        for locked, blanked, ok in ((1, 0, True), (0, 1, True), (2, 0, True), (0, 2, True), (0, 0, False)):
            p = Policy()
            p.locked, p.blanked, p.notify_ok = locked, blanked, ok
            self.assertIsNone(p.replacement('brightness-nits', raw(100)))
            self.assertIsNone(p.replacement('BLNitsCap', raw(100)))
        self.assertIsNone(Policy(cap=0).replacement('BLNitsCap', raw(100)))

    def test_no_lowering_or_small_noise(self):
        p = Policy()
        self.assertIsNone(p.replacement('brightness-nits', raw(424.5)))
        self.assertIsNone(p.replacement('brightness-nits', raw(900)))
        self.assertIsNone(p.replacement('BLNitsCap', raw(1060)))
        self.assertEqual(p.replacement('brightness-nits', raw(423)), raw(425))

    def test_legacy_enabled_false_does_not_disable(self):
        p = Policy()
        self.assertFalse(p.prefs['enabled'])
        self.assertEqual(p.replacement('BLNitsCap', raw(100)), raw(850))

    def test_all_apis_preserve_return_code_and_rewrite(self):
        for api in (0, 1):
            p, calls = Policy(), []
            result = p.single(api, 'brightness-nits', raw(163), lambda k, v: calls.append(v) or -536870206)
            self.assertEqual(result, -536870206)
            self.assertEqual(calls, [raw(425)])
        p, calls = Policy(), []
        data = {'BLNitsCap': raw(100), 'brightness-nits': raw(163), 'Other': object()}
        self.assertEqual(p.many(data, lambda d: calls.append(d) or -7), -7)
        self.assertEqual(calls[0]['BLNitsCap'], raw(850))
        self.assertEqual(calls[0]['brightness-nits'], raw(425))
        self.assertIs(calls[0]['Other'], data['Other'])
        self.assertEqual(data['BLNitsCap'], raw(100))

    def test_unchanged_dictionary_and_non_dictionary_identity(self):
        for data in ({'DisplayBrightness': {'Nits': 163, 'NitsPhysical': 80}}, {'BLNitsCap': raw(1060)}, b'opaque', None):
            p, calls = Policy(), []
            self.assertEqual(p.many(data, lambda d: calls.append(d) or 17), 17)
            self.assertIs(calls[0], data)

    def test_recursion_guard_preserves_inner_value(self):
        p, inner = Policy(), []
        def original(key, value):
            self.assertEqual(value, raw(425))
            return p.single(1, key, raw(100), lambda k, v: inner.append(v) or 88)
        self.assertEqual(p.single(0, 'brightness-nits', raw(100), original), 88)
        self.assertEqual(inner, [raw(100)])
        self.assertEqual(p.tls.depth, 0)

    def test_slider_short_ttl_and_notification(self):
        p = Policy(slider=0.8)
        self.assertEqual(p.user_slider(), 0.8)
        p.slider = 0
        p.time = 0.19
        self.assertEqual(p.user_slider(), 0.8)
        p.time = 0.2
        self.assertEqual(p.user_slider(), 0)
        p.slider = 0.1
        p.invalidate()
        self.assertEqual(p.user_slider(), 0.1)
        self.assertEqual(p.slider_reads, 3)

    def test_power_mode_is_not_a_brightness_policy_input(self):
        values = []
        for mode in ('low-power', 'balanced', 'high-performance'):
            p = Policy(slider=0.6)
            p.cpu_mode = mode
            values.append(p.replacement('brightness-nits', raw(100)))
        self.assertEqual(values, [raw(510)] * 3)


class SourceContracts(unittest.TestCase):
    def test_source_matches_policy_safety_contracts(self):
        s = re.sub(r'//[^\n]*', '', SOURCE.read_text())
        for symbol in ('IOServiceSetProperty', 'IORegistryEntrySetCFProperty', 'IORegistryEntrySetCFProperties'):
            self.assertIn(f'dlsym(iokit, "{symbol}")', s)
        for forbidden in ('getValue:', 'CPUthermalFastBrightnessRestore', 'CPUthermalCommitBrightnessNits', 'CapLearnPhysicalNits', 'gRequestedNits', 'hid.displayStatus', 'IOConnectCall', 'prefs[S("enabled")]', '(0.5 * NSEC_PER_SEC)'):
            self.assertNotIn(forbidden, s)
        for required in ('CFNumberGetValue', 'CFBridgingRelease(copied)', 'static __thread unsigned int gWriteDepth', 'WriteScope scope', 'now - gSliderTime >= 0.2', '3.0 * NSEC_PER_SEC', 'com.apple.springboard.hasBlankedScreen', '&blanked) == NOTIFY_STATUS_OK && blanked == 0', 'CFRelease(value)', 'CFRelease(replacement)', 'CFRelease(changes.changed)'):
            self.assertIn(required, s)
        replacement = s[s.index('static CFNumberRef CopyReplacement'):s.index('static kern_return_t (*OrigServiceSet)')]
        self.assertLess(replacement.index('BrightnessKey(key)'), replacement.index('DesiredRaw(kind'))
        protection = s[s.index('static BOOL BrightnessProtectionEnabled'):s.index('static void InvalidateCaches')]
        self.assertIn('return YES;', protection)


if __name__ == '__main__':
    unittest.main(verbosity=2)
