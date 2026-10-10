import re, unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
S=(P/'Tweak.x').read_text()
def function(name,next_name):
 return S.split('static void '+name,1)[1].split('static void '+next_name,1)[0]
class FixedFullCPUContracts(unittest.TestCase):
 def test_full_controller_cpu_floor_is_100(self):
  body=function('applyFullPowerBudgetsOnController(id controller) {','applyLowPowerLimitsToTrackedControllers')
  self.assertIn('shouldRequestMaximumFloors()',body)
  self.assertRegex(body,r'setCPUPowerFloor:fromDecisionSource:\), shouldRequestMaximumFloors\(\) \? kUnrestrictedPerformancePercent : 0')
 def test_full_gpu_package_floors_are_100(self):
  body=function('reassertSharedFullPowerBudgets(id object) {','applyExplicitLowPowerBudgets')
  for part in ('GPU','Package'):
   self.assertIn('@selector(set'+part+'PowerFloor:fromDecisionSource:), kUnrestrictedPerformancePercent',body)
  full=function('applyFullPowerBudgetsOnController(id controller) {','applyLowPowerLimitsToTrackedControllers')
  self.assertIn('reassertSharedFullPowerBudgets(controller);',full)
  self.assertNotRegex(full,r'set(?:GPU|Package)PowerFloor:fromDecisionSource:\),\s*0')
 def test_common_product_and_mitigation_cpu_floor_100(self):
  common=function('applyFullPowerToCommonProduct(void) {','applyCurrentPowerModeToRuntime')
  self.assertIn('setRequestedFloors(product, YES, kUnrestrictedPerformancePercent);',common)
  self.assertIn('reassertSharedFullPowerBudgets(product);',common)
  hook=S.split('%hook MitigationController',1)[1].split('%end',1)[0]
  self.assertIn('%orig(kUnrestrictedPerformancePercent, source);',hook.split('- (void)setCPUPowerFloor:',1)[1])
 def test_disabled_and_low_power_floors_zero(self):
  restore=function('restoreNativeRuntimeAfterDisable(void) {','setCommonProductCeiling')
  self.assertEqual(restore.count('setRequestedFloors(controller, YES, 0);'),2)
  self.assertIn('setRequestedFloors(commonProductSnapshot(), YES, 0);',restore)
  low=function('applyExplicitLowPowerBudgets(id controller) {','reassertLowPowerStateWithoutUpdate')
  self.assertIn('setRequestedFloors(controller, NO, 0);',low)
  self.assertIn('setCPUPowerFloor:fromDecisionSource:), 0',low)
 def test_no_old_policy_name_and_visible_title(self):
  self.assertNotIn('shouldApplyHighPerformanceMode',S)
  self.assertNotIn('hardwareLock',S)
  self.assertNotIn('shouldPinCPUAtMaximum',S)
  spec=(P/'Settings/Root.plist').read_text()
  self.assertIn('解除温控',spec)
  self.assertNotIn('稳定高性能',spec)
if __name__=='__main__': unittest.main(verbosity=2)
