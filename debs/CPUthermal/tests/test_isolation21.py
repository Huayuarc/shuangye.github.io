import unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
T=(P/'Tweak.x').read_text()
H=(P/'Hello120Hz/Core/H120Hooks.mm').read_text()

class Isolation21Contracts(unittest.TestCase):
 def test_frequency_policy_unchanged(self):
  self.assertIn('kLowPowerCPULevel = 2',T)
  self.assertIn('kLowPowerPowerLimitMW = 2500',T)
  self.assertIn('kLowPowerPerformancePercent = 45',T)
  self.assertIn('kUnrestrictedPerformancePercent = 100',T)
 def test_appleppm_low_power_reasserts_after_orig(self):
  body=T.split('%hook ApplePPMCPU',1)[1].split('%end',1)[0]
  update=body.split('- (void)updateCPU {',1)[1]
  low=update.split('if (shouldApplyLowPowerLimit()) {',1)[1].split('// 解除温控',1)[0]
  self.assertEqual(low.count('[self setCPULevel:kLowPowerCPULevel];'),2)
  self.assertIn('%orig;',low)
  self.assertIn('trackApplePPMInstance(self);',update)
 def test_wake_restarts_bounded_low_power_pulse(self):
  wake=T.split('static void restoreUserModeAfterWake(const char *source) {',1)[1].split('static void handleLockStateToken',1)[0]
  self.assertIn('scheduleLowPowerApplyPulse();',wake)
  pulse=T.split('static void scheduleLowPowerApplyPulse(void) {',1)[1].split('static void runLowPowerApplyPulse',1)[0]
  self.assertIn('runLowPowerApplyPulse(6);',pulse)
  self.assertNotIn('runLowPowerApplyPulse(12);',pulse)
 def test_no_hot_update_bulk_budget_reassert(self):
  gpu=T.split('- (void)updateGPU {',1)[1].split('- (void)updatePackage {',1)[0]
  package=T.split('- (void)updatePackage {',1)[1].split('- (void)setCPULowPowerTarget:',1)[0]
  self.assertNotIn('reassertSharedFullPowerBudgets',gpu+package)
  self.assertIn('%orig;',gpu)
  self.assertIn('%orig;',package)
 def test_h120_policy_work_off_main_thread(self):
  self.assertIn('H120PolicyQueue()',H)
  self.assertNotIn('policyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue())',H)
  notify=H.split('notify_register_dispatch(H120PreferencesNotification.UTF8String',1)[1].split('});',1)[0]
  self.assertIn('H120PolicyQueue()',notify)
 def test_wake_backlight_scans_are_coalesced(self):
  wake=T.split('static void restoreUserModeAfterWake(const char *source) {',1)[1].split('static void handleLockStateToken',1)[0]
  self.assertNotIn('CPUthermalRaiseExistingBacklightLimits();',wake)
  recovery=T.split('static void CPUthermalScheduleBacklightRecovery(void) {',1)[1].split('static BOOL keyIsDisplayLifecycleProperty',1)[0]
  self.assertIn('const double delays[] = {0.50, 3.00};',recovery)
  self.assertIn('QOS_CLASS_UTILITY',recovery)
  self.assertNotIn('QOS_CLASS_USER_INITIATED',recovery)

if __name__=='__main__': unittest.main()
