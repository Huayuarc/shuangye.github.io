from pathlib import Path
import unittest, plistlib, re
R=Path(__file__).parent
P=R.parent
S=(P/'Tweak.x').read_text()

def hook(cls):
    return S.split('%hook '+cls+'\n',1)[1].split('%end',1)[0]
def method(body, signature):
    return body.split(signature,1)[1].split('\n}',1)[0]

class ModeIsolationRegression(unittest.TestCase):
    maxDiff = 200
    def assertNotIn(self, needle, haystack, msg=None):
        self.assertFalse(needle in haystack, msg or ('Unexpected source token: '+repr(needle)))
    def test_mitigation_cpu_power_save_persists_in_low_mode(self):
        thermal=hook('ThermalControl')
        self.assertIn('if (shouldApplyLowPowerLimit()) return YES;',method(thermal,'- (BOOL)powerSaveActive'))
        self.assertIn('%orig(YES)',method(thermal,'- (void)setPowerSaveActive:'))
        mitigation=hook('MitigationController')
        self.assertIn('if (shouldApplyLowPowerLimit()) return YES;',method(mitigation,'- (BOOL)powerSaveActive'))
        self.assertIn('%orig(YES)',method(mitigation,'- (void)setPowerSaveActive:'))
        helper=S.rsplit('static void applyLowPowerPerformancePreferenceToController',1)[1].split('\n}',1)[0]
        self.assertEqual(helper.count('@selector(setPowerSaveActive:)'),4)
        self.assertEqual(helper.count('@selector(setPowerSaveActive:), YES'),2)
        self.assertNotIn('@selector(setPowerSaveActive:), NO',helper)
        self.assertIn('@selector(updateCPU)',helper)
        component=hook('ComponentControl')
        self.assertIn('%orig',method(component,'- (void)setPackageLowPowerTarget'))
        self.assertIn('return %orig',method(component,'- (BOOL)powerSaveActive'))
    def test_full_power_requests_maximum_floor_without_mw_unit_mixup(self):
        policy=S.split('static BOOL shouldRequestMaximumFloors(void) {',1)[1].split('\n}',1)[0]
        self.assertIn('return shouldApplyFullCPUProtection();',policy)
        full=S.split('static void applyFullPowerBudgetsOnController(id controller) {',1)[1].split('static void applyLowPowerLimitsToTrackedControllers',1)[0]
        self.assertIn('@selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPerformancePercent',full)
        common=S.split('static void applyFullPowerToCommonProduct(void) {',1)[1].split('static void applyCurrentPowerModeToRuntime',1)[0]
        self.assertIn('setRequestedFloors(product, YES, kUnrestrictedPerformancePercent);',common)
        self.assertNotIn('@selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW',full)
    def test_low_power_execution_chain_is_not_zeroed(self):
        macros=S.split('#define CT_VOID0',1)[1].split('CT_VOID0(ctTreeEvaluate',1)[0]
        self.assertIn('shouldApplyFullCPUProtection()',macros)
        self.assertNotIn('shouldForceNominalThermalPressure()',macros)
        manager=hook('ThermalManager')
        evaluate=method(manager,'- (void)evaluateDecisionTree')
        cpms=method(manager,'- (void)setCPMSMitigationState:')
        self.assertIn('shouldApplyFullCPUProtection()',evaluate)
        self.assertIn('shouldApplyFullCPUProtection()',cpms)
    def test_no_configuration_scaling(self):
        self.assertNotIn('CPUthermalScaleForLowPower',S)
        self.assertNotIn('CPUthermalApplyLowPowerConfigScaling',S)
        self.assertNotIn('CPUthermalIsScalablePowerKey',S)
    def test_mode_switch_no_self_termination(self):
        self.assertNotIn('kill(getpid()',S)
        self.assertNotIn('CPUthermalMaybeReloadConfigForModeChange',S)
    def test_cpu_budget_retained(self):
        for symbol in ('kLowPowerPowerLimitMW','kLowPowerPerformancePercent','applyExplicitLowPowerBudgets','setCPUPowerCeiling:fromDecisionSource:'):
            self.assertIn(symbol,S)
    def test_low_power_is_cpu_only_on_a15(self):
        apple_ppm=hook('ApplePPM')
        self.assertIn('trackApplePPMInstance(res)',apple_ppm)
        self.assertIn('%orig(kLowPowerCPULevel)',apple_ppm)
        mitigation=hook('MitigationController')
        self.assertIn('- (void)setCPUMitigationLevel:',mitigation)
        self.assertIn('%orig(kLowPowerCPULevel)',mitigation)
        runtime=S.rsplit('static void applyCurrentPowerModeToRuntime(void) {',1)[1].split('static void restoreUserModeAfterWake',1)[0]
        apply=runtime.split('if (isLowPowerMode()) {',1)[1].split('if (isFullPowerMode()) {',1)[0]
        for forbidden in ('Backlight','Brightness','CPUthermalApplySimulatedThermalLevel','GPUPower','PackagePower','setCPMSMitigationsEnabled'):
            self.assertNotIn(forbidden,apply)
    def test_power_units_not_filled_with_nits(self):
        self.assertNotIn('CPUthermalMaximizeBacklightArray(power)',S)
        self.assertIn('CPUthermalMaximumElementOfBacklightArray(power)',S)
    def test_modes_and_cc_preserved(self):
        panel=(P/'Settings/FRootListController.m').read_text()
        self.assertGreaterEqual(panel.count('S("powerMode")'),1)
        self.assertIn('[mode setProperty:@[S("lowPower"), S("fullPower")] forKey:S("validValues")]',panel)
        self.assertTrue((P/'ControlCenter/CPUthermalCCModuleViewController.m').is_file())
    def test_brightness_policy_not_selected_by_power_mode(self):
        # isolation.9：防降亮度并入核心后，亮度限制键路径仍只“抬”不“压”，且不由 powerMode 选择亮度。
        body=S.split('static NSUInteger CPUthermalRaiseExistingBacklightLimits(void) {',1)[1].split('\n}',1)[0]
        self.assertIn('if (current + 0.5 < scaled) {',body)
        self.assertIn('IORegistryEntrySetCFProperty(entry, key,',body)
        self.assertNotIn('isLowPowerMode',body)
        self.assertNotIn('g_powerMode',body)
        replacement=S.split('static id backlightReplacementMatchingValue',1)[1].split('// 判断是否为 thermalmonitord 发出的约束属性。',1)[0]
        self.assertNotIn('isLowPowerMode',replacement)
        self.assertNotIn('getValue:',replacement)
        self.assertNotIn('CPUthermalFastBrightnessRestore',S)
    def test_all_xml_parse(self):
        for f in P.rglob('*.plist'):
            if f.read_bytes().lstrip().startswith(b'<?xml'): plistlib.loads(f.read_bytes())
    def test_no_blind_async_abi(self):
        self.assertNotIn('%hookf(kern_return_t, IOConnectCallAsyncMethod',S)
    def test_component_package_lpm_passthrough(self):
        body=hook('ComponentControl')
        self.assertIn('%orig',method(body,'- (void)setPackageLowPowerTarget'))
        self.assertIn('return %orig',method(body,'- (BOOL)powerSaveActive'))

if __name__=='__main__': unittest.main(verbosity=2)
