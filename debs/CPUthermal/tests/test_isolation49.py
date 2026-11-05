"""isolation.49 契约：thermalmonitord hook 只能使用已离线核实的 owner 与 ABI。"""
import re
import unittest
from pathlib import Path

P = Path(__file__).resolve().parents[1]
TWEAK = (P / 'Tweak.x').read_text()
CONTROL = (P / 'control').read_text()
PLIST = (P / 'CPUthermal.plist').read_text()


def hook_block(class_name):
    match = re.search(rf'^%hook {re.escape(class_name)}\n(.*?)^%end$', TWEAK, re.S | re.M)
    if not match:
        raise AssertionError(f'missing %hook {class_name}')
    return match.group(1)


class VerifiedOwnersAndABIs(unittest.TestCase):
    def test_thermal_manager_is_unique_and_uses_real_entries(self):
        self.assertEqual(TWEAK.count('%hook ThermalManager'), 1)
        block = hook_block('ThermalManager')
        self.assertIn('- (id)getConfigurationFor:(NSString *)key', block)
        self.assertIn('- (void)hintComponentControlTakeAction', block)
        self.assertIn('- (void)probeAllSupervisorControlLoadingIndex', block)
        self.assertNotIn('evaluateDecisionTree', block)
        self.assertNotIn('setCPMSMitigationState:', block)
        self.assertNotIn('updateThermalNotification:', block)

    def test_decision_tree_uses_integer_release_rate(self):
        block = hook_block('TableDrivenDecisionTree')
        self.assertIn('- (void)evaluateDecisionTree', block)
        self.assertIn('- (void)actionComponentControl', block)
        self.assertIn('- (void)readReleaseRateForAllComponents', block)
        self.assertIn('- (int)getReleaseRateForComponent:(int)component', block)
        self.assertNotRegex(block, r'\((?:float|double)\)getReleaseRateForComponent:')

    def test_supervisor_and_component_use_verified_abis(self):
        supervisor = hook_block('SupervisorControl')
        component = hook_block('ComponentControl')
        self.assertIn('- (void)calculateControlEffort:(float)effort trigger:(float)trigger', supervisor)
        self.assertIn('- (void)setCPMSMitigationState:(BOOL)state', component)

    def test_floor_setters_live_on_mitigation_controller(self):
        block = hook_block('MitigationController')
        self.assertIn('- (void)setGPUPowerFloor:(int)floor fromDecisionSource:(uintptr_t)source', block)
        self.assertIn('- (void)setPackagePowerFloor:(int)floor fromDecisionSource:(uintptr_t)source', block)


class RemovedGuessesStayRemoved(unittest.TestCase):
    def test_no_runtime_abi_candidate_installer(self):
        for forbidden in ('CPUthermalABIHook', 'installCrossVersionThermalAliases',
                          'CT_RELEASE_ENTRIES', 'CT_EFFORT_ENTRIES'):
            self.assertNotIn(forbidden, TWEAK)

    def test_no_fake_device_monitor_configuration_hook(self):
        for forbidden in ('orig_getConfigurationFor', 'new_getConfigurationFor',
                          'DeviceMonitor.framework/DeviceMonitor'):
            self.assertNotIn(forbidden, TWEAK)

    def test_nonexistent_mitigation_setters_are_not_hooked(self):
        block = hook_block('MitigationController')
        self.assertNotRegex(block, r'- \(void\)setPowerSaveActive:')
        self.assertNotRegex(block, r'- \(void\)setCPUMitigationLevel:')

    def test_no_apple_ppm_runtime_path(self):
        for forbidden in ('g_applePPMInstances', 'trackApplePPMInstance',
                          'applyCurrentModeToApplePPMCPU'):
            self.assertNotIn(forbidden, TWEAK)

    def test_no_orphaned_maximum_floor_helper(self):
        self.assertNotIn('shouldRequestMaximumFloors', TWEAK)


class PackageContracts(unittest.TestCase):
    def test_version(self):
        self.assertIn('Version: 1.6.2-170+isolation.57', CONTROL)
        self.assertIn('#define APELIN_BUILD_ID "isolation.56"', TWEAK)

    def test_core_injects_only_thermalmonitord(self):
        executables = re.search(r'Executables\s*=\s*\((.*?)\)', PLIST, re.S)
        self.assertIsNotNone(executables)
        names = re.findall(r'[A-Za-z0-9_.-]+', executables.group(1))
        self.assertEqual(names, ['thermalmonitord'])

    def test_display_level_write_stays_out_of_core(self):
        code = '\n'.join(line.split('//', 1)[0] for line in TWEAK.splitlines())
        for forbidden in ('IOMFBBrightnessLevel', 'CPUthermalStartDisplayLevelTimer',
                          'CPUthermalAssertDisplayBrightnessLevel'):
            self.assertNotIn(forbidden, code)


if __name__ == '__main__':
    unittest.main()
