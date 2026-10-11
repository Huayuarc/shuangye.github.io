import unittest,plistlib,re
from pathlib import Path
P=Path(__file__).resolve().parents[1]
# 被移除模块的名称在测试里也拼装书写，保证“全仓库无该字面引用”的扫描可以覆盖测试自身。
REMOVED_MODULE='CPUthermal'+'Display'
REMOVED_SRC='Display'+'Guard'
REMOVED_INJECTS=('back'+'boardd','bright'+'nessd','CPUthermal'+'Display.dylib')
class RemovalContracts(unittest.TestCase):
 def test_no_feature_files_or_build_target(self):
  for name in ('RefreshRate.xm','RefreshRatePolicy.inc','RefreshRateUIHooks.inc','RefreshRateUIState.inc','CPUthermalRefreshRate.plist'):
   self.assertFalse((P/name).exists())
  self.assertNotIn('CPUthermalRefreshRate',(P/'Makefile').read_text())
 def test_display_module_removed_everywhere(self):
  # isolation.9：原独立显示模块彻底移除，不得以任何名义回归，也不得恢复对
  # 显示/外壳进程（BRD/BRD2 类后台守护）的亮度注入。
  for name in (REMOVED_SRC+'.xm',REMOVED_MODULE+'.plist',REMOVED_SRC+'.x'):
   self.assertFalse((P/name).exists(),name)
  for f in P.rglob('*'):
   if not f.is_file():continue
   if f.name in ('Makefile','control') or f.suffix in ('.x','.xm','.m','.h','.inc','.plist','.sh','.in','.md','.py','.json','.txt'):
    text=f.read_text(errors='replace')
    for term in (REMOVED_MODULE,REMOVED_SRC)+REMOVED_INJECTS:
     self.assertNotIn(term,text,(str(f),term))
  make=(P/'Makefile').read_text()
  self.assertNotIn(REMOVED_MODULE,make)
  self.assertNotIn(REMOVED_SRC,make)
  core_text=(P/'CPUthermal.plist').read_text()
  self.assertNotIn('Bundles',core_text)          # 不注入任何外壳/显示进程
  executables=re.findall(r'\(\s*([^)]*)\)',core_text.split('Executables',1)[1])[0]
  self.assertEqual(re.findall(r'[A-Za-z0-9_.\-]+',executables),['thermalmonitord'])
  self.assertNotIn('%hook SpringBoard',(P/'Tweak.x').read_text())
 def test_no_switches_or_orphan_groups(self):
  spec=plistlib.loads((P/'Settings/Root.plist').read_bytes())['items']
  keys={x.get('key') for x in spec}
  self.assertTrue({'powerMode','smartChargeStopLevel','currentGuardEnabled'}.issubset(keys))
  for i,x in enumerate(spec):
   if x.get('cell')=='PSGroupCell':
    self.assertTrue(x.get('label') or (x.get('footerText') and i+1<len(spec) and spec[i+1].get('cell')!='PSGroupCell'))
 def test_no_deleted_symbols_or_file_writes(self):
  prohibited=('force120HzEnable','loggingEnabled','cputhermal-throttle.log','cputhermal-display.log','cputhermal-brightness.log','ProMotion','强制120Hz','生成诊断日志','CPUthermalThrottleLog','CPUthermalBrightnessLog','DLogToFile','LogReplacement','CPUthermalLogPressureStatus')
  for f in P.rglob('*'):
   if f.is_file() and f.suffix in ('.x','.xm','.m','.h','.inc','.plist','.sh','.in','.md') or f.name in ('Makefile','control'):
    text=f.read_text(errors='replace')
    for term in prohibited:self.assertNotIn(term,text,(f,term))
  for f in ('Tweak.x','Tweak_PrefHook.xm'):
   text=(P/f).read_text()
   for term in ('createFileAtPath','fileHandleForWritingAtPath'):
    self.assertNotIn(term,text,(f,term))
 def test_core_tweak_targets_retained(self):
  make=(P/'Makefile').read_text()
  self.assertRegex(make,r'(?m)^TWEAK_NAME\s*=\s*CPUthermal CPUthermalPrefHook CPUthermalFaceDownLock\s*$')
  self.assertEqual(len(re.findall(r'(?m)^TWEAK_NAME\s*=',make)),1)
  names=re.findall(r'(?m)^TWEAK_NAME\s*=\s*(.+)$',make)[0].split()
  self.assertEqual(names,['CPUthermal','CPUthermalPrefHook','CPUthermalFaceDownLock'])
  for name in names:
   self.assertIn(name+'_FILES =',make)
 def test_retained_notify_and_payload(self):
  settings=(P/'Settings/FRootListController.m').read_text()
  self.assertIn('notify_post(kCPUthermalSettingsChangedNotifC)',settings)
  self.assertEqual(settings.count('notify_post(kCPUthermalSettingsChangedNotifC)'),1)
  for name in ('CPUthermal.plist','CPUthermalPrefHook.plist','CPUthermalFaceDownLock.plist','Tools/CPUthermalTool.m','Tools/CPUthermalChargeTool.m'):
   self.assertTrue((P/name).exists())
 def test_version_and_thermal_restart(self):
  self.assertIn('Version: 1.6.2-154+isolation.9',(P/'control').read_text())
  self.assertIn('killall -q thermalmonitord',(P/'scripts/postinst.in').read_text())
  self.assertIn('launchctl bootstrap system @JBROOT@/Library/LaunchDaemons/',(P/'scripts/postinst.in').read_text())
if __name__=='__main__':unittest.main()
