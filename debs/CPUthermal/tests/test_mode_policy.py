from pathlib import Path
import plistlib
import re
import unittest

P = Path(__file__).parent.parent
S = (P / 'Tweak.x').read_text()


def hook(cls):
    match = re.search(rf'^%hook {re.escape(cls)}\n(.*?)^%end$', S, re.S | re.M)
    if not match:
        raise AssertionError(f'missing %hook {cls}')
    return match.group(1)


def method(body, signature):
    match = re.search(rf'^{re.escape(signature)}(?:[^\n{{]*)\{{', body, re.M)
    if not match:
        raise AssertionError(f'missing method {signature}')
    start = match.end()
    depth = 1
    for index in range(start, len(body)):
        if body[index] == '{':
            depth += 1
        elif body[index] == '}':
            depth -= 1
            if depth == 0:
                return body[start:index]
    raise AssertionError(f'unterminated method {signature}')


def static_function(signature):
    match = re.search(rf'^static void {re.escape(signature)}\s*\{{', S, re.M)
    if not match:
        raise AssertionError(f'missing function {signature}')
    return method(S[match.start():], f'static void {signature}')


class ModeIsolationRegression(unittest.TestCase):
    maxDiff = 200

    def test_low_power_uses_verified_mitigation_paths(self):
        common = hook('CommonProduct')
        self.assertIn('%orig(YES)', method(common, '- (void)setIsCPMSMitigationEnabled:'))
        mitigation = hook('MitigationController')
        self.assertIn('%orig(YES)', method(mitigation, '- (void)setCPMSMitigationsEnabled:'))
        self.assertIn('if (shouldApplyLowPowerLimit()) return YES;',
                      method(mitigation, '- (BOOL)powerSaveActive'))
        helper = static_function('applyLowPowerPerformancePreferenceToController(id controller)')
        self.assertNotIn('setPowerSaveActive:', helper)
        self.assertIn('@selector(updateCPU)', helper)
        self.assertNotIn('- (void)setPowerSaveActive:', mitigation)
        self.assertNotIn('- (void)setCPUMitigationLevel:', mitigation)

    def test_full_power_requests_maximum_floor_without_mw_unit_mixup(self):
        policy = S.split('static BOOL shouldRequestMaximumFloors(void) {', 1)[1].split('\n}', 1)[0]
        self.assertIn('return shouldApplyFullCPUProtection();', policy)
        full = S.split('static void applyFullPowerBudgetsOnController(id controller) {', 1)[1].split(
            'static void applyLowPowerLimitsToTrackedControllers', 1)[0]
        self.assertIn('@selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPerformancePercent', full)
        self.assertNotIn('@selector(setCPUPowerFloor:fromDecisionSource:), kUnrestrictedPowerLimitMW', full)
        common = hook('CommonProduct')
        self.assertNotRegex(common, re.compile(r'^- \(void\)setCPUPowerFloor:', re.M))
        self.assertNotRegex(common, re.compile(r'^- \(void\)setGPUPowerFloor:', re.M))
        self.assertNotRegex(common, re.compile(r'^- \(void\)setPackagePowerFloor:', re.M))

    def test_low_power_execution_chain_is_not_zeroed(self):
        tree = hook('TableDrivenDecisionTree')
        evaluate = method(tree, '- (void)evaluateDecisionTree')
        self.assertIn('shouldApplyFullCPUProtection()', evaluate)
        self.assertNotIn('shouldForceNominalThermalPressure()', evaluate)
        component = hook('ComponentControl')
        cpms = method(component, '- (void)setCPMSMitigationState:')
        self.assertIn('shouldApplyFullCPUProtection()', cpms)
        self.assertNotIn('shouldApplyLowPowerLimit()', cpms)

    def test_no_configuration_scaling(self):
        self.assertNotIn('CPUthermalScaleForLowPower', S)
        self.assertNotIn('CPUthermalApplyLowPowerConfigScaling', S)
        self.assertNotIn('CPUthermalIsScalablePowerKey', S)

    def test_mode_switch_no_self_termination(self):
        self.assertNotIn('kill(getpid()', S)
        self.assertNotIn('CPUthermalMaybeReloadConfigForModeChange', S)

    def test_cpu_budget_retained(self):
        for symbol in ('kLowPowerPowerLimitMW', 'kLowPowerPerformancePercent',
                       'applyExplicitLowPowerBudgets', 'setCPUPowerCeiling:fromDecisionSource:'):
            self.assertIn(symbol, S)

    def test_low_power_is_cpu_only_on_a15(self):
        self.assertNotIn('%hook ApplePPM', S)
        mitigation = hook('MitigationController')
        self.assertIn('%orig(kLowPowerCPULevel);', method(mitigation, '- (void)setCPULevel:'))
        self.assertNotIn('- (void)setCPUMitigationLevel:', mitigation)
        runtime = S.rsplit('static void applyCurrentPowerModeToRuntime(void) {', 1)[1].split(
            'static void restoreUserModeAfterWake', 1)[0]
        apply = runtime.split('if (isLowPowerMode()) {', 1)[1].split('if (isFullPowerMode()) {', 1)[0]
        for forbidden in ('Backlight', 'Brightness', 'CPUthermalApplySimulatedThermalLevel',
                          'GPUPower', 'PackagePower', 'setCPMSMitigationsEnabled'):
            self.assertNotIn(forbidden, apply)

    def test_power_units_not_filled_with_nits(self):
        self.assertNotIn('CPUthermalMaximizeBacklightArray(power)', S)
        self.assertIn('CPUthermalMaximumElementOfBacklightArray(power)', S)

    def test_modes_and_cc_preserved(self):
        panel = (P / 'Settings/FRootListController.m').read_text()
        self.assertGreaterEqual(panel.count('S("powerMode")'), 1)
        self.assertIn('[mode setProperty:@[S("lowPower"), S("fullPower")] forKey:S("validValues")]', panel)
        self.assertTrue((P / 'ControlCenter/CPUthermalCCModuleViewController.m').is_file())

    def test_brightness_policy_not_selected_by_power_mode(self):
        body = S.split('static NSUInteger CPUthermalRaiseExistingBacklightLimits(void) {', 1)[1].split('\n}', 1)[0]
        self.assertIn('if (current + 0.5 < scaled) {', body)
        self.assertIn('IORegistryEntrySetCFProperty(entry, key,', body)
        self.assertNotIn('isLowPowerMode', body)
        self.assertNotIn('g_powerMode', body)
        replacement = S.split('static id backlightReplacementMatchingValue', 1)[1].split(
            '// 判断是否为 thermalmonitord 发出的约束属性。', 1)[0]
        self.assertNotIn('isLowPowerMode', replacement)
        self.assertNotIn('getValue:', replacement)
        self.assertNotIn('CPUthermalFastBrightnessRestore', S)

    def test_all_xml_parse(self):
        for path in P.rglob('*.plist'):
            if path.read_bytes().lstrip().startswith(b'<?xml'):
                plistlib.loads(path.read_bytes())

    def test_no_blind_async_abi(self):
        self.assertNotIn('%hookf(kern_return_t, IOConnectCallAsyncMethod', S)

    def test_package_low_power_does_not_join_cpu_only_mode(self):
        mitigation = hook('MitigationController')
        package = method(mitigation, '- (void)setPackageLowPowerTarget')
        self.assertIn('shouldApplyLowPowerLimit() || shouldApplyFullCPUProtection()', package)
        component = hook('ComponentControl')
        self.assertNotRegex(component, re.compile(r'^- \(void\)setPackageLowPowerTarget', re.M))
        self.assertNotRegex(component, re.compile(r'^- \(void\)updatePackage', re.M))
        update = method(component, '- (void)updatePowerParameters:(id)params')
        self.assertIn('if (shouldApplyFullCPUProtection()) return;', update)


if __name__ == '__main__':
    unittest.main(verbosity=2)
