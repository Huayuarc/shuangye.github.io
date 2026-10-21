from pathlib import Path
import re, unittest, subprocess, plistlib
S=Path(__file__).resolve().parents[1]
core=(S/'Tweak.x').read_text();pref=(S/'Tweak_ThermalWarn.xm').read_text()
class Isolation5Contracts(unittest.TestCase):
 def test_no_process_wide_notify_interposition(self):
  for name in ('notify_register_check','notify_register_dispatch','notify_cancel','notify_get_state'):
   self.assertNotIn('dlsym(RTLD_DEFAULT, "'+name+'")',pref)
  self.assertNotIn('os_unfair_lock_lock',pref)
  self.assertNotIn('NSMutableSet',pref)
 def test_thermal_warn_module_retained_standalone(self):
  # isolation.11：高温警告抑制迁入独立模块（仅注入 SpringBoard），并新增面板开关
  # isolation.15：默认关闭、偏好缺失默认 NO、经设置变更通知即时重载。
  # 断言源文件与过滤器存在、过滤器恰为 SpringBoard，并确认新文件未带入被移除的
  # 部件/维修记录屏蔽代码与三个被禁全字面量（一律拼接书写）。
  self.assertTrue((S/'Tweak_ThermalWarn.xm').exists())
  tfilter=plistlib.loads((S/'CPUthermalThermalWarn.plist').read_bytes())
  self.assertEqual(tfilter['Filter'].get('Bundles'),['com.apple.springboard'])
  self.assertEqual(tfilter['Filter'].get('Executables'),['SpringBoard'])
  for term in ('CPUthermal'+'PrefHook','Tweak_'+'PrefHook','suppressBattery'+'ServiceWarnings'):
   self.assertNotIn(term,pref,term)
  for term in ('BatteryService','Specifier','CPUthermalHookKind','PSListController','PSTableCell','NSUserDefaults','notify_post','CFNotificationCenter'):
   self.assertNotIn(term,pref,term)
  self.assertIn('static BOOL gBlockThermalPopup = NO;',pref)
  self.assertIn('blockThermalPopup',pref)
  self.assertIn('__atomic_store_n(&gBlockThermalPopup, enabled, __ATOMIC_RELEASE);',pref)   # 偏好缺失默认关闭
  self.assertIn('notify_register_dispatch(kCPUthermalSettingsChangedNotifC',pref)
  self.assertIn('ReloadThermalWarnPreference();',pref)
  self.assertEqual(pref.count('CPUthermalInstallThermalStateSpoof();'),1)   # 仅 %ctor 调用
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
