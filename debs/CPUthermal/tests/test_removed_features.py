import unittest,plistlib,re
from pathlib import Path
P=Path(__file__).resolve().parents[1]
# 被移除模块的名称在测试里也拼装书写，保证“全仓库无该字面引用”的扫描可以覆盖测试自身。
REMOVED_MODULE='CPUthermal'+'Display'
REMOVED_SRC='Display'+'Guard'
REMOVED_INJECTS=('back'+'boardd','bright'+'nessd','CPUthermal'+'Display.dylib')
# isolation.10：第二个（1x1）控制中心模块及其资源目录被彻底移除，同样拼装书写。
REMOVED_CC_SECOND='CPUthermal'+'CC'+'1x1'
REMOVED_CC_SECOND_DIR='resources'+'1x1'
REMOVED_CC_SECOND_FILES=(REMOVED_CC_SECOND+'Module.h',REMOVED_CC_SECOND+'Module.m',
                        REMOVED_CC_SECOND+'ModuleViewController.h',REMOVED_CC_SECOND+'ModuleViewController.m')
# isolation.11：整个 PrefHook 模块（源文件、过滤器 plist、Makefile 引用与面板条目）被移除，同样拼装书写。
REMOVED_HOOK_MODULE='CPUthermal'+'PrefHook'
REMOVED_HOOK_SRC='Tweak_'+'PrefHook'
REMOVED_HOOK_PREF_KEY='suppressBattery'+'ServiceWarnings'
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
 def test_secondary_cc_module_removed_and_remaining_resized(self):
  # isolation.10：第二个（1x1）控制中心模块彻底移除——四个源文件与资源目录均不得存在，
  # 且全仓库文本文件不得再出现该模块名或其资源目录名（测试自身用拼接写法，同样受扫描）。
  for name in REMOVED_CC_SECOND_FILES:
   self.assertFalse((P/'ControlCenter'/name).exists(),name)
  self.assertFalse((P/'ControlCenter'/REMOVED_CC_SECOND_DIR).exists())
  for f in P.rglob('*'):
   if not f.is_file():continue
   if f.name in ('Makefile','control') or f.suffix in ('.x','.xm','.m','.h','.inc','.plist','.sh','.in','.md','.py','.json','.txt'):
    text=f.read_text(errors='replace')
    for term in (REMOVED_CC_SECOND,REMOVED_CC_SECOND_DIR):
     self.assertNotIn(term,text,(str(f),term))
  make=(P/'Makefile').read_text()
  # 保留的 CC bundle 名称必须恰好是那一个，且只 stage 一个 CC bundle。
  self.assertEqual(re.findall(r'(?m)^BUNDLE_NAME\s*=\s*(.+?)\s*$',make),['CPUthermalSettings CPUthermalCC'])
  self.assertEqual(re.findall(r'mkdir -p "\$\(THEOS_STAGING_DIR\)/Library/ControlCenter/Bundles/([A-Za-z0-9_.\-]+)\.bundle"',make),['CPUthermalCC'])
  self.assertEqual(set(re.findall(r'ControlCenter/Bundles/([A-Za-z0-9_.\-]+\.bundle)',make)),{'CPUthermalCC.bundle'})
  self.assertNotIn(REMOVED_CC_SECOND+'_',make)
  # 保留的 CC 模块本身仍在（源码、安装路径、私有框架链接不变）。
  self.assertTrue((P/'ControlCenter/CPUthermalCCModule.m').exists())
  self.assertTrue((P/'ControlCenter/CPUthermalCCModuleViewController.m').exists())
  self.assertTrue((P/'ControlCenter/resources/Info.plist').exists())
  self.assertTrue((P/'ControlCenter/resources/SettingsIcon.png').exists())
 def test_remaining_cc_module_declared_1x1(self):
  # 保留的 CC 模块尺寸声明为 1x1：四处（CCSModuleSize/ModuleSize × 横竖屏）均为 Height=1/Width=1；
  # isolation.11 起显示名与 CFBundleName 改为恰好“CPUthermal”（去掉冗余的 2x1 后缀），
  # 其余键（标识符、主类、运行时尺寸开关等）一律不改。
  cc=plistlib.loads((P/'ControlCenter/resources/Info.plist').read_bytes())
  for section in ('CCSModuleSize','ModuleSize'):
   for orientation in ('Landscape','Portrait'):
    self.assertEqual(cc[section][orientation],{'Height':1,'Width':1},(section,orientation))
  self.assertEqual(cc['CFBundleDisplayName'],'CPUthermal')
  self.assertEqual(cc['CFBundleName'],'CPUthermal')
  self.assertEqual(cc['CFBundleIdentifier'],'com.huayuarc.cputhermal.ccmodule')
  self.assertEqual(cc['CFBundleExecutable'],'CPUthermalCC')
  self.assertEqual(cc['NSPrincipalClass'],'CPUthermalCCModule')
  self.assertIs(cc['CCSGetModuleSizeAtRuntime'],False)
  self.assertIs(cc['GetModuleSizeAtRuntime'],False)
 def test_prefhook_module_removed_everywhere(self):
  # isolation.11：PrefHook 模块整体移除——(a) 源文件与过滤器 plist 不存在；
  # (b) 全仓库文本文件（范围/后缀沿用既有风格，含本测试自身）不得含三个全字面量；
  # (c) Makefile 的 TWEAK_NAME 恰好三名；(d) 设置面板无该开关、标签与页脚说明，
  # 且新增的高温警告开关 blockThermalPopup 就位（默认开启）。
  self.assertFalse((P/(REMOVED_HOOK_SRC+'.xm')).exists(),REMOVED_HOOK_SRC+'.xm')
  self.assertFalse((P/(REMOVED_HOOK_MODULE+'.plist')).exists(),REMOVED_HOOK_MODULE+'.plist')
  for f in P.rglob('*'):
   if not f.is_file():continue
   if f.name in ('Makefile','control') or f.suffix in ('.x','.xm','.m','.h','.inc','.plist','.sh','.in','.md','.py','.json','.txt'):
    text=f.read_text(errors='replace')
    for term in (REMOVED_HOOK_MODULE,REMOVED_HOOK_SRC,REMOVED_HOOK_PREF_KEY):
     self.assertNotIn(term,text,(str(f),term))
  make=(P/'Makefile').read_text()
  self.assertRegex(make,r'(?m)^TWEAK_NAME\s*=\s*CPUthermal CPUthermalFaceDownLock CPUthermalThermalWarn\s*$')
  panel=(P/'Settings/FRootListController.m').read_text()
  self.assertNotIn(REMOVED_HOOK_PREF_KEY,panel)
  self.assertNotIn('屏蔽部件与维修记录',panel)
  self.assertNotIn('部件与服务历史',panel)
  self.assertIn('ITEM("屏蔽高温温度计警告", "blockThermalPopup", PSSwitchCell, [NSNumber numberWithBool:YES])',panel)
 def test_dynamic_panel_core_keys(self):
  panel=(P/'Settings/FRootListController.m').read_text()
  for key in ('powerMode','smartChargeStopLevel','currentGuardEnabled'):
   self.assertIn('"'+key+'"',panel)
  self.assertFalse((P/'Settings/Root.plist').exists())
 def test_no_deleted_symbols_or_file_writes(self):
  prohibited=('force120HzEnable','loggingEnabled','cputhermal-throttle.log','cputhermal-display.log','cputhermal-brightness.log','ProMotion','强制120Hz','生成诊断日志','CPUthermalThrottleLog','CPUthermalBrightnessLog','DLogToFile','LogReplacement','CPUthermalLogPressureStatus')
  for f in P.rglob('*'):
   if f.is_file() and f.suffix in ('.x','.xm','.m','.h','.inc','.plist','.sh','.in','.md') or f.name in ('Makefile','control'):
    text=f.read_text(errors='replace')
    for term in prohibited:self.assertNotIn(term,text,(f,term))
  for f in ('Tweak.x','Tweak_ThermalWarn.xm'):
   text=(P/f).read_text()
   for term in ('createFileAtPath','fileHandleForWritingAtPath'):
    self.assertNotIn(term,text,(f,term))
 def test_core_tweak_targets_retained(self):
  make=(P/'Makefile').read_text()
  self.assertRegex(make,r'(?m)^TWEAK_NAME\s*=\s*CPUthermal CPUthermalFaceDownLock CPUthermalThermalWarn\s*$')
  self.assertEqual(len(re.findall(r'(?m)^TWEAK_NAME\s*=',make)),1)
  names=re.findall(r'(?m)^TWEAK_NAME\s*=\s*(.+)$',make)[0].split()
  self.assertEqual(names,['CPUthermal','CPUthermalFaceDownLock','CPUthermalThermalWarn'])
  for name in names:
   self.assertIn(name+'_FILES =',make)
 def test_retained_notify_and_payload(self):
  settings=(P/'Settings/FRootListController.m').read_text()
  self.assertIn('notify_post(kCPUthermalSettingsChangedNotifC)',settings)
  self.assertEqual(settings.count('notify_post(kCPUthermalSettingsChangedNotifC)'),1)
  for name in ('CPUthermal.plist','CPUthermalFaceDownLock.plist','Tools/CPUthermalTool.m','Tools/CPUthermalChargeTool.m'):
   self.assertTrue((P/name).exists())
 def test_version_and_thermal_restart(self):
  self.assertIn('Version: 1.6.2-154+isolation.13',(P/'control').read_text())
  self.assertIn('killall -q thermalmonitord',(P/'scripts/postinst.in').read_text())
  self.assertIn('launchctl bootstrap system @JBROOT@/Library/LaunchDaemons/',(P/'scripts/postinst.in').read_text())
if __name__=='__main__':unittest.main()
