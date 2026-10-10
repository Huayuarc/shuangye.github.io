from pathlib import Path
import re, unittest, subprocess
S=Path(__file__).resolve().parents[1]
core=(S/'Tweak.x').read_text();pref=(S/'Tweak_PrefHook.xm').read_text()
class Isolation5Contracts(unittest.TestCase):
 def test_notify_dispatch_exact_four_arg_forwarding_and_cancel(self):
  self.assertRegex(pref,r'CPUthermalNotifyRegisterDispatchFn\)\(const char \*, int \*, dispatch_queue_t, notify_handler_t\)')
  self.assertIn('gOrigNotifyRegisterDispatch(name, token, queue, handler)',pref)
  self.assertIn('if (result == 0 && token && CPUthermalIsThermalNotifyName(name))',pref)
  self.assertIn('CPUthermalHookedNotifyCancel(int token)',pref)
  self.assertIn('[gThermalNotifyTokens removeObject:@(token)]',pref)
 def test_hotpath_no_periodic_thermal_simulation_and_mode_gate(self):
  self.assertNotIn('CPUthermalThermalLevelTick();',core)
  self.assertNotIn('5ull * NSEC_PER_SEC',core)
  section=core.split('static void handleThermalLevelNotification(int token) {',1)[1].split('static void registerThermalLevelResetObservers',1)[0]
  self.assertIn('!shouldApplyFullCPUProtection()',section)
  self.assertIn('if (!allowed) return;',section)
  self.assertGreaterEqual(core.count('correctNominalStateIfNeeded();\nreturn;'),2)
  self.assertIn('static __thread BOOL g_restoringFullPower',core)
  self.assertIn('g_restoringFullPower = previousRestoring;',core)
 def test_wake_transaction_and_update_count(self):
  self.assertIn('if (now - lastWakeRestore < 0.5) return;',core)
  section=core.split('static void restoreFullPowerToController(id controller) {',1)[1].split('static void restoreFullPowerToTrackedControllers',1)[0]
  self.assertEqual(section.count('@selector(updateCPU)'),2) # responds + invocation, one call
 def test_incident_capture_readonly(self):
  capture=(S/'scripts/capture-runtime.sh').read_text()
  for item in ('CallAssist','thermalmonitord','hw.cpufrequency','hw.cpufrequency_max','ioreg','powerMode','date '):self.assertIn(item,capture)
  for expr in (r'\bsysctl\s+-w\b',r'\bioreg\s+-w\b',r'\bkill\b',r'\blaunchctl\b'):self.assertNotRegex(capture,expr)
  subprocess.run(['sh','-n',str(S/'scripts/capture-runtime.sh')],check=True)
if __name__=='__main__':unittest.main()
