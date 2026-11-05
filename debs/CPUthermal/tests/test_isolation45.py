"""isolation.45 契约：DisplayShield 会注入 backboardd，加载期绝不能做跨进程调用。

背景：isolation.44 在 %ctor 里实例化 BrightnessSystemClient 取面板最大亮度，
而 backboardd 自身就是亮度 XPC 服务端，加载期同步调用自己的服务 ->
安装/注销后直接黑屏，只能强制重启。这里把契约固化下来，防止再次回归。
"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
SHIELD = (P / 'CPUthermalDisplayShield.xm').read_text()


def block(text, marker, end='\n}'):
    return text.split(marker, 1)[1].split(end, 1)[0]


def strip_comments(text):
    lines = []
    for line in text.splitlines():
        stripped = line.split('//', 1)[0]
        lines.append(stripped)
    return '\n'.join(lines)


class DisplayShieldLoadSafety(unittest.TestCase):
    def test_shield_is_injected_into_backboardd(self):
        plist = (P / 'CPUthermalDisplayShield.plist').read_text()
        self.assertIn('<string>backboardd</string>', plist)

    def test_ctor_has_no_cross_process_calls(self):
        ctor = strip_comments(block(SHIELD, '%ctor {'))
        for forbidden in ('BrightnessSystemClient', 'objc_getClass', 'dlopen(',
                          'CPUthermalRegistryPanelMaximumNits',
                          'CPUthermalDisplayLearnedCap'):
            self.assertNotIn(forbidden, ctor, f'%ctor 不得调用 {forbidden}（blackboardd 加载期自锁）')

    def test_panel_maximum_is_read_locally_from_ioregistry(self):
        self.assertIn('static double CPUthermalRegistryPanelMaximumNits(void)', SHIELD)
        self.assertIn('IOServiceGetMatchingServices', SHIELD)
        # 锚点必须可失败、不阻塞：惰性获取，且包在 @try 里。
        learned = block(SHIELD, 'static double CPUthermalDisplayLearnedCap(void) {')
        self.assertIn('CPUthermalRegistryPanelMaximumNits()', learned)
        self.assertIn('@try', learned)

    def test_cap_writes_still_pass_through_when_shield_off(self):
        hook = block(SHIELD, 'static kern_return_t CPUthermalHookedRegistrySet(')
        self.assertIn('gCPUthermalDisplayShieldEnabled && CPUthermalDisplayCapKey(key)', hook)
        self.assertIn('replacement ? (__bridge CFTypeRef)replacement : value', hook)


if __name__ == '__main__':
    unittest.main()
