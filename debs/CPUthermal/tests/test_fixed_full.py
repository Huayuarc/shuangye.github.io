import re, unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
S=(P/'Tweak.x').read_text()
class FixedFullCPUContracts(unittest.TestCase):
 def test_full_controller_cpu_floor_is_100(self):
  body=S.split('static void applyFullPowerBudgetsOnController(id controller) {',1)[1].split('static void applyLowPowerLimitsToTrackedControllers',1)[0]
  self.assertRegex(body,r'setCPUPowerFloor:fromDecisionSource:[^;]*100|setCPUPowerFloor:fromDecisionSource:\), shouldPinCPUAtMaximum\(\) \? kUnrestrictedPerformancePercent : 0')
  self.assertIn('shouldPinCPUAtMaximum()',body)
 def test_full_gpu_package_floors_remain_zero(self):
  body=S.split('static void applyFullPowerBudgetsOnController(id controller) {',1)[1].split('static void applyLowPowerLimitsToTrackedControllers',1)[0]
  self.assertRegex(body,r'setGPUPowerFloor:fromDecisionSource:\),0')
  self.assertRegex(body,r'setPackagePowerFloor:fromDecisionSource:\),0')
 def test_common_product_and_mitigation_cpu_floor_100(self):
  self.assertIn('setCommonProductCeiling(product, @selector(setCPUPowerFloor:fromDecisionSource:), shouldPinCPUAtMaximum() ? kUnrestrictedPerformancePercent : 0);',S)
  hook=S.split('%hook MitigationController',1)[1].split('%end',1)[0]
  self.assertIn('%orig(kUnrestrictedPerformancePercent, source);',hook.split('- (void)setCPUPowerFloor:',1)[1])
 def test_disabled_and_low_power_floors_zero(self):
  restore=S.split('static void restoreNativeRuntimeAfterDisable',1)[1].split('static void setCommonProductCeiling',1)[0]
  self.assertIn('setCPUPowerFloor:fromDecisionSource:), 0',restore)
  low=S.split('static void applyExplicitLowPowerBudgets',1)[1].split('static void reassertLowPowerStateWithoutUpdate',1)[0]
  self.assertIn('setCPUPowerFloor:fromDecisionSource:), 0',low)
 def test_no_old_policy_name_and_visible_title(self):
  self.assertNotIn('shouldApplyHighPerformanceMode',S)
  self.assertNotIn('稳定高性能',(P/'Settings/Root.plist').read_text())
  self.assertIn('解除温控',(P/'Settings/Root.plist').read_text())
if __name__=='__main__': unittest.main(verbosity=2)
