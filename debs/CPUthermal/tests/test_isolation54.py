"""isolation.54 契约：CPMS 缓解的转发不能吞掉系统自己的降频决策。

背景：MitigationController 的 setCPMSMitigationsEnabled: 在旧版里写成
    if (shouldApplyLowPowerLimit()) %orig(YES);
    if (shouldApplyFullCPUProtection()) %orig(NO);
    %orig(enabled);
两个分支都没命中时（有限温控模式 enabled 本来就可能是 NO）落到 %orig(enabled)，
表面看是转发，实际把系统在“未要求解除温控”时自己发起的 CPMS 缓解请求也一并
按 NO 写下去，CLPC 只能靠固定功率目标跑，表现为用着用着掉到低频、几十秒再爬回。

这里把契约固化：该钩子只有两个允许改写方向——低功耗强制 YES、解除温控强制 NO，
其它情况必须原样 %orig(enabled)，不得对 enabled 做任何其它替换。
"""
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TWEAK = (P / 'Tweak.x').read_text()


def hook_body(name):
    """取同名方法的实现体（粗略按花括号配平），void/BOOL 返回都支持。"""
    pattern = re.compile(r'^-[ ]*\((?:void|BOOL)\)[ ]*' + re.escape(name) + r'\b', re.M)
    m = pattern.search(TWEAK)
    assert m, 'hook {} not found'.format(name)
    start = TWEAK.index('{', m.end())
    depth = 0
    for i in range(start, len(TWEAK)):
        if TWEAK[i] == '{':
            depth += 1
        elif TWEAK[i] == '}':
            depth -= 1
            if depth == 0:
                return TWEAK[start:i + 1]
    raise AssertionError('unbalanced braces in {}'.format(name))


class CPMSForwardingContract(unittest.TestCase):
    def setUp(self):
        self.body = hook_body('setCPMSMitigationsEnabled')

    def test_passes_through_unmodified(self):
        # 必须存在对原 value 的透传，且不是被 %%orig(NO) 之类替换掉的
        self.assertIn('%orig(enabled)', self.body,
                      'CPMS 缓解必须按原值透传，否则系统原生降频会被吞掉')

    def test_full_power_forces_off(self):
        self.assertRegex(self.body, r'shouldApplyFullCPUProtection\(\)\s*\)\s*\{\s*%orig\(NO\)')

    def test_low_power_forces_on(self):
        self.assertRegex(self.body, r'shouldApplyLowPowerLimit\(\)\s*\)\s*\{\s*%orig\(YES\)')

    def test_no_blanket_disable(self):
        # 不允许出现“无条件 %orig(NO) 然后 return”这种把透传抹掉的写法
        self.assertNotRegex(self.body, r'\n\s*%orig\(NO\);\s*\n\s*return;\s*\n\s*%orig\(enabled\);')

    def test_isCPMS_getter_matches(self):
        getter = hook_body('isCPMSMitigationEnabled')
        self.assertIn('shouldApplyFullCPUProtection', getter)
        self.assertIn('%orig', getter)


if __name__ == '__main__':
    unittest.main()
