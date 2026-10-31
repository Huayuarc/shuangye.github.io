from pathlib import Path
import hashlib,json,plistlib,unittest,subprocess,tempfile,ctypes
P=Path(__file__).resolve().parents[1];H=P/'Hello120Hz';MF=(P/'Makefile').read_text()
class Hello120Port(unittest.TestCase):
 def test_upstream_code_byte_identical(self):
  manifest=json.loads((H/'UPSTREAM_SHA256.json').read_text())
  self.assertEqual(len(manifest),12)
  for rel,digest in manifest.items():self.assertEqual(hashlib.sha256((H/rel).read_bytes()).hexdigest(),digest,rel)
 def test_original_settings_features_present(self):
  s=(H/'Preferences/H120SettingsController.mm').read_text()
  for term in ('wantsEnable','wantsFPS','selectedApps','H120SetGlobalInjection','H120SetHUDEnabled','H120ApplicationListClass','- (void)reset','- (void)respring','- (void)apply'):
   self.assertIn(term,s)
  self.assertIn('@[@10,@30,@60,@80,@120]',s)
 def test_original_filter_default(self):
  a=plistlib.loads((P/'0hello120hz.plist').read_bytes())
  b=plistlib.loads((H/'Preferences/Resources/DefaultInjection.plist').read_bytes())
  self.assertEqual(a,b);f=a['Filter']
  self.assertEqual(f['Executables'],['SpringBoard','backboardd','replayd'])
  self.assertEqual(f['Bundles'],['com.apple.springboard','com.apple.Preferences'])
  self.assertEqual(f['Mode'],'Any')
 def test_build_all_original_units(self):
  for rel in ('Core/H120Hooks.mm','Core/H120Recording.mm','Core/H120Policy.c','Core/H120RangeTrampolines.S','Shared/H120Preferences.mm','Preferences/H120SettingsController.mm','Preferences/Hello120HzPreferences.mm'):
   self.assertIn('Hello120Hz/'+rel,MF)
  self.assertIn('Hello120Hz/Core/H120Recording.mm_CFLAGS = -fno-objc-arc',MF)
  self.assertIn('0hello120hz_LIBRARIES = substrate',MF)
 def test_cpu_panel_link(self):
  s=(P/'Settings/FRootListController.m').read_text()
  self.assertIn('NSClassFromString(S("hello120hzPreRootListController"))',s)
  self.assertIn('cell:PSLinkCell',s)
 def test_upstream_pref_domain_unchanged(self):
  s=(H/'Shared/H120Preferences.mm').read_text()
  self.assertIn('@"cn.zqbb.fix120hz"',s);self.assertIn('@"cn.zqbb.hello.120hz.notif"',s)
  self.assertIn('flock(fd, LOCK_EX)',s)
 def test_resources_staged_without_overwriting_info(self):
  for term in ('Resources/Mode3.plist','Resources/DefaultInjection.plist','Resources/Base.lproj','Resources/zh_CN.lproj','Resources/icon@2x.png'):self.assertIn(term,MF)
  self.assertNotIn('cp Hello120Hz/Preferences/Resources/Info.plist',MF)
 def test_install_filter_symlink(self):
  s=(P/'scripts/postinst.in').read_text()
  self.assertIn('../../../var/mobile/Library/Preferences/cn.zqbb.fix120hz.injection.plist',s)
  self.assertIn('CPUthermalSettings.bundle/DefaultInjection.plist',s)
  self.assertIn('if [ ! -e "$h120preferences" ]',s)
 def test_old_state_reset_before_unpack(self):
  s=(P/'scripts/preinst.in').read_text()
  self.assertIn('upgrade)',s)
  self.assertLess(s.index('launchctl bootout'),s.index('CPUthermalChargeTool" reset'))
  self.assertIn('@JBROOT@/usr/local/bin/CPUthermalChargeTool',s)
 def test_dependency_conflicts(self):
  s=(P/'control').read_text()
  self.assertIn('com.opa334.altlist',s)
  self.assertIn('Conflicts: cn.zqbb.fix120hz,',s)
 def test_policy_compiled_behavior(self):
  with tempfile.TemporaryDirectory() as d:
   lib=Path(d)/'policy.so';subprocess.run(['cc','-shared','-fPIC',str(H/'Core/H120Policy.c'),'-o',str(lib)],check=True)
   f=ctypes.CDLL(str(lib));f.H120NormalizeFPS.argtypes=[ctypes.c_float];f.H120NormalizeFPS.restype=ctypes.c_float
   f.H120SystemAllowsOverride.argtypes=[ctypes.c_bool,ctypes.c_bool,ctypes.c_int];f.H120SystemAllowsOverride.restype=ctypes.c_bool
   for value in (10,30,60,80,120):self.assertEqual(f.H120NormalizeFPS(value),value)
   self.assertEqual(f.H120NormalizeFPS(59),120)
   for enabled in (False,True):
    for low in (False,True):
     for level in range(4):self.assertEqual(f.H120SystemAllowsOverride(enabled,low,level),enabled and not low and level<2)
if __name__=='__main__':unittest.main()
