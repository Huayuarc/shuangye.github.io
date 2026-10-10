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
    def test_no_global_powersave_yes(self):
        self.assertNotRegex(S, r'@selector\(setPowerSaveActive:\), YES')
        for cls in ('ThermalControl','MitigationController'):
            setter=method(hook(cls),'- (void)setPowerSaveActive:')
            self.assertNotIn('%orig(YES)',setter)
            self.assertIn('%orig(NO)',setter)
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
    def test_power_units_not_filled_with_nits(self):
        self.assertNotIn('CPUthermalMaximizeBacklightArray(power)',S)
        self.assertIn('CPUthermalMaximumElementOfBacklightArray(power)',S)
    def test_modes_and_cc_preserved(self):
        d=plistlib.loads((P/'Settings/Root.plist').read_bytes())
        modes=[x for x in d['items'] if x.get('key')=='powerMode']
        self.assertEqual(len(modes),1)
        self.assertEqual(set(modes[0]['validValues']),{'lowPower','fullPower'})
        self.assertTrue((P/'ControlCenter/CPUthermalCCModuleViewController.m').is_file())
    def test_display_independent(self):
        d=(P/'DisplayGuard.xm').read_text()
        self.assertNotIn('powerMode',d)
        self.assertNotIn('isLowPowerMode',d)
        self.assertNotIn('getValue:', '\n'.join(x for x in d.splitlines() if not x.strip().startswith('//')))
        self.assertNotIn('CPUthermalFastBrightnessRestore',d)
    def test_all_xml_parse(self):
        for f in P.rglob('*.plist'):
            if f.read_bytes().lstrip().startswith(b'<?xml'): plistlib.loads(f.read_bytes())
    def test_no_blind_async_abi(self):
        self.assertNotIn('%hookf(kern_return_t, IOConnectCallAsyncMethod',S)
    def test_component_not_package_lpm(self):
        body=hook('ComponentControl')
        self.assertIn('shouldApplyLowPowerLimit()',method(body,'- (void)setPackageLowPowerTarget'))
        self.assertIn('return NO',method(body,'- (BOOL)powerSaveActive'))

if __name__=='__main__': unittest.main(verbosity=2)
