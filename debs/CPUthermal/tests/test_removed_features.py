import unittest,plistlib,re
from pathlib import Path
P=Path(__file__).resolve().parents[1]
class RemovalContracts(unittest.TestCase):
 def test_no_feature_files_or_build_target(self):
  for name in ('RefreshRate.xm','RefreshRatePolicy.inc','RefreshRateUIHooks.inc','RefreshRateUIState.inc','CPUthermalRefreshRate.plist'):
   self.assertFalse((P/name).exists())
  self.assertNotIn('CPUthermalRefreshRate',(P/'Makefile').read_text())
 def test_no_switches_or_orphan_groups(self):
  spec=plistlib.loads((P/'Settings/Root.plist').read_bytes())['items']
  keys={x.get('key') for x in spec}
  self.assertTrue({'powerMode','smartChargeStopLevel'}.issubset(keys))
  for i,x in enumerate(spec):
   if x.get('cell')=='PSGroupCell':
    self.assertTrue(x.get('label') or (x.get('footerText') and i+1<len(spec) and spec[i+1].get('cell')!='PSGroupCell'))
 def test_no_deleted_symbols_or_file_writes(self):
  prohibited=('force120HzEnable','loggingEnabled','cputhermal-throttle.log','cputhermal-display.log','cputhermal-brightness.log','ProMotion','强制120Hz','生成诊断日志','CPUthermalThrottleLog','CPUthermalBrightnessLog','DLogToFile','LogReplacement','CPUthermalLogPressureStatus')
  for f in P.rglob('*'):
   if f.is_file() and f.suffix in ('.x','.xm','.m','.h','.inc','.plist','.sh','.in','.md') or f.name in ('Makefile','control'):
    text=f.read_text(errors='replace')
    for term in prohibited:self.assertNotIn(term,text,(f,term))
  for f in ('Tweak.x','Tweak_PrefHook.xm','DisplayGuard.xm'):
   text=(P/f).read_text()
   for term in ('createFileAtPath','fileHandleForWritingAtPath'):
    self.assertNotIn(term,text,(f,term))
 def test_retained_notify_and_payload(self):
  settings=(P/'Settings/FRootListController.m').read_text()
  self.assertIn('notify_post(kCPUthermalSettingsChangedNotifC)',settings)
  self.assertEqual(settings.count('notify_post(kCPUthermalSettingsChangedNotifC)'),1)
  for name in ('CPUthermal.plist','CPUthermalDisplay.plist','CPUthermalPrefHook.plist','CPUthermalFaceDownLock.plist','Tools/CPUthermalTool.m','Tools/CPUthermalChargeTool.m'):
   self.assertTrue((P/name).exists())
 def test_version_and_thermal_restart(self):
  self.assertIn('Version: 1.6.2-154+isolation.6',(P/'control').read_text())
  self.assertIn('killall -q thermalmonitord',(P/'scripts/postinst.in').read_text())
  self.assertIn('launchctl bootstrap system @JBROOT@/Library/LaunchDaemons/',(P/'scripts/postinst.in').read_text())
if __name__=='__main__':unittest.main()
