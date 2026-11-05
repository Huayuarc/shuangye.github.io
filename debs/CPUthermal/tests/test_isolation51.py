"""isolation.51–53 契约：显示守护只补回落差，并且跨机型自适应。

isolation.48 的守护把「用户请求的 nits」当目标，每 2 秒无条件比对；CoreBrightness 自己
还有一层请求→面板级映射（实测 0.86），于是它每次都在系统正常值之上再抬一截，拖动滑块
后就会出现二次跳变。isolation.50 因此整条链路被删除，但用户户外的压暗（请求满值、面板级
只有一半）也就不再有自愈通道。

isolation.51 用「按亮度桶学习系统映射比例 + 只补回落差 + 只升不降 + 冷却 + 分段渐变」恢复
纠正能力；isolation.52 修正满亮度区把被压的 0.80 当健康比例学死的问题；
isolation.53 让节点与单位跨机型自适应（DCP / LCD、16.16 / 毫 nit / nits）。
"""
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TOOL = (P / 'Tools/CPUthermalDisplayTool.m').read_text()
MAKEFILE = (P / 'Makefile').read_text()
POSTINST = (P / 'scripts/postinst.in').read_text()
PRERM = (P / 'scripts/prerm.in').read_text()
SETTINGS = (P / 'Settings/FRootListController.m').read_text()
TWEAK = (P / 'Tweak.x').read_text()
DAEMON = P / 'layout/Library/LaunchDaemons/com.huayuarc.cputhermal.display.plist'


class DaemonIsPackaged(unittest.TestCase):
    def test_tool_and_entitlements_exist(self):
        self.assertTrue((P / 'Tools/CPUthermalDisplayTool.m').exists())
        self.assertTrue((P / 'Tools/CPUthermalDisplayTool.entitlements').exists())

    def test_display_iokit_entitlement_present(self):
        ent = (P / 'Tools/CPUthermalDisplayTool.entitlements').read_text()
        self.assertIn('IOMobileFramebufferUserClient', ent)
        self.assertIn('com.apple.private.security.no-sandbox', ent)

    def test_launch_daemon_declared(self):
        self.assertTrue(DAEMON.exists())
        text = DAEMON.read_text()
        self.assertIn('com.huayuarc.cputhermal.display', text)
        self.assertIn('/usr/local/bin/CPUthermalDisplayTool', text)
        self.assertIn('<key>KeepAlive</key>', text)

    def test_makefile_builds_it(self):
        self.assertIn('CPUthermalDisplayTool', MAKEFILE.split('include $(THEOS_MAKE_PATH)/tool.mk')[0])
        self.assertIn('Tools/CPUthermalDisplayTool.entitlements', MAKEFILE)
        self.assertIn('for n in charge display', MAKEFILE)

    def test_maintenance_scripts_manage_it(self):
        self.assertIn('com.huayuarc.cputhermal.display.plist', POSTINST)
        self.assertIn('launchctl bootout system/com.huayuarc.cputhermal.display', PRERM)


class CorrectionIsRatioBased(unittest.TestCase):
    def test_learns_system_mapping_per_brightness_bucket(self):
        self.assertIn('knownRatio[kDisplayBucketCount]', TOOL)
        self.assertIn('BucketForRequest', TOOL)

    def test_only_corrects_an_abrupt_ratio_drop(self):
        self.assertIn('kDisplayClampRatioFactor', TOOL)
        self.assertIn('ratio < known * kDisplayClampRatioFactor', TOOL)

    def test_requires_a_nearby_healthy_sample(self):
        self.assertIn('sampleReq[kDisplayBucketCount]', TOOL)
        self.assertIn('kDisplaySampleProximity', TOOL)
        self.assertIn('nearby && ratioCollapsed', TOOL)

    def test_target_is_request_times_learned_ratio(self):
        self.assertIn("double target = requested * (hardCollapse ? 0.85 : expected);", TOOL)

    def test_peak_region_targets_the_request_itself(self):
        self.assertIn('BOOL topRegion', TOOL)
        self.assertIn('double expected = topRegion ? 1.0 : known;', TOOL)
        self.assertIn('kDisplayTopRegionRatio', TOOL)

    def test_never_writes_the_raw_request_outside_peak_region(self):
        self.assertNotIn('requested > ceiling ? ceiling : requested', TOOL)
        self.assertNotIn('kDisplayDefaultCeilingNits', TOOL)

    def test_no_hardcoded_panel_ceiling(self):
        self.assertNotRegex(TOOL, r'\b850(\.0)?\b')
        self.assertNotIn('displayNitsCeiling', TOOL)

    def test_requires_stability_before_judging(self):
        self.assertIn('BOOL stable = (now - gState.reqSince) >= kDisplayStableSeconds;', TOOL)

    def test_rate_limited_and_raise_only(self):
        self.assertIn('kDisplayCorrectionCooldown', TOOL)
        self.assertIn('(now - gState.lastCorrection) > kDisplayCorrectionCooldown', TOOL)
        self.assertIn('if (target <= current + kDisplayDeadbandNits) return;', TOOL)
        self.assertIn('if (target > requested * 1.02) target = requested;', TOOL)

    def test_large_gap_is_ramped(self):
        self.assertIn('kDisplayRampThreshold', TOOL)
        self.assertIn('usleep(kDisplayRampDelayMicroseconds)', TOOL)

    def test_cap_is_restored_only_upward(self):
        self.assertIn('cap < gState.maxCapNits * 0.95', TOOL)
        self.assertIn('WriteCapNits(gState.maxCapNits);', TOOL)

    def test_gated_on_full_power_mode_and_switch(self):
        self.assertIn('FullPowerMode(prefs)', TOOL)
        self.assertIn('LevelGuardEnabled(prefs)', TOOL)
        self.assertIn('powerMode', TOOL)

    def test_keeps_off_low_brightness(self):
        self.assertIn('requested < kDisplayFloorNits', TOOL)

    def test_logs_every_correction(self):
        self.assertIn('displayLevel raised', TOOL)
        self.assertIn('displayLevel cap raised', TOOL)
        self.assertIn('displayLevel heartbeat', TOOL)


class CrossDeviceAdaptation(unittest.TestCase):
    """iPhone 8–15：LCD 背光与 DCP 面板走不同节点、不同单位，必须运行时发现。"""

    def test_covers_dcp_and_lcd_service_nodes(self):
        for cls in ('AppleCLCD2', 'AppleCLCD', 'AppleDCP',
                    'IOMobileFramebuffer', 'AppleARMBacklight', 'AppleBacklightDisplay'):
            self.assertIn('"%s"' % cls, TOOL)

    def test_brightness_keys_for_both_pipelines(self):
        self.assertIn('"IOMFBBrightnessLevel"', TOOL)   # DCP / OLED
        self.assertIn('"CurrentNits"', TOOL)            # LCD 背光
        self.assertIn('"BrightnessMilliNits"', TOOL)    # LCD 参数字典

    def test_units_are_inferred_not_hardcoded(self):
        self.assertIn('kDisplayScaleCandidates', TOOL)
        self.assertIn('65536.0, 1000.0, 1.0', TOOL)
        self.assertIn('InferScale', TOOL)

    def test_no_single_service_hardcoded_for_reads(self):
        self.assertNotIn('IOServiceMatching("AppleCLCD2")', TOOL)

    def test_lcd_parameters_write_rewrites_the_dictionary(self):
        self.assertIn('IODisplayParameters', TOOL)
        self.assertIn('BrightnessMilliNits"] = number', TOOL)

    def test_missing_node_is_never_written_to(self):
        self.assertIn('displayLevel backend unavailable', TOOL)
        self.assertIn('if (!gBackend.valid) return;', TOOL)
        self.assertIn('kDisplayRediscoverSeconds', TOOL)

    def test_backend_is_rediscovered_after_idle_reads(self):
        self.assertIn('kDisplayIdleTicksBeforeRediscover', TOOL)
        self.assertIn('ReleaseBackend();', TOOL)


class SettingsStayMinimal(unittest.TestCase):
    def test_settings_no_longer_offer_brightness_lock(self):
        for forbidden in ('displayNitsLockEnabled', 'displayNitsCeiling',
                          '屏幕亮度锁定', '启用亮度锁定', '最高亮度 (nits)'):
            self.assertNotIn(forbidden, SETTINGS)


class CoreStaysOut(unittest.TestCase):
    def test_core_never_writes_the_panel_level(self):
        # 代码行（去掉 // 注释后）不得直接写面板级亮度；注释里允许解释这条约束。
        code = '\n'.join(line.split('//', 1)[0] for line in TWEAK.splitlines())
        for forbidden in ('IOMFBBrightnessLevel', 'CPUthermalStartDisplayLevelTimer',
                          'CPUthermalAssertDisplayBrightnessLevel'):
            self.assertNotIn(forbidden, code)


class DisplayShieldStaysSafe(unittest.TestCase):
    def test_shield_remains_packaged(self):
        self.assertIn('CPUthermalDisplayShield', MAKEFILE)
        self.assertTrue((P / 'CPUthermalDisplayShield.xm').exists())
        self.assertTrue((P / 'CPUthermalDisplayShield.plist').exists())

    def test_shield_ctor_still_has_no_cross_process_calls(self):
        shield = (P / 'CPUthermalDisplayShield.xm').read_text()
        ctor = shield.split('%ctor {', 1)[1].split('\n}', 1)[0]
        ctor = '\n'.join(line.split('//', 1)[0] for line in ctor.splitlines())
        for forbidden in ('BrightnessSystemClient', 'objc_getClass', 'dlopen('):
            self.assertNotIn(forbidden, ctor)


if __name__ == '__main__':
    unittest.main()
