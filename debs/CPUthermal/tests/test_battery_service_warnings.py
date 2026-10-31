import plistlib
import re
import unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
SRC=(P/'CPUthermalBatteryHealth.xm').read_text()
MF=(P/'Makefile').read_text()
PANEL=(P/'Settings/FRootListController.m').read_text()
class BatteryServiceWarningContracts(unittest.TestCase):
 def test_scoped_files_and_filter(self):
  self.assertTrue((P/'CPUthermalBatteryHealth.xm').exists())
  f=plistlib.loads((P/'CPUthermalBatteryHealth.plist').read_bytes())['Filter']
  self.assertEqual(f['Bundles'],['com.apple.Preferences'])
  self.assertEqual(f['Executables'],['Preferences'])
 def test_default_off_and_snapshot_only(self):
  self.assertIn('static BOOL gCPUthermalSuppressBatteryServiceWarning = NO;',SRC)
  self.assertIn('suppressBatteryServiceWarnings',SRC)
  self.assertIn('CPUthermalReadPrefsSnapshot()',SRC)
  for term in ('CPUthermalWritePrefs','CPUthermalReadMutablePrefs','AppleSmartBattery','thermalmonitord','SpringBoard'):
   self.assertNotIn(term,SRC)
 def test_hooks_are_switchable_and_restore_orig(self):
  for sel in ('getManagementState','genuineBatteryStatus','getBatteryHealthServiceState'):
   self.assertIn(sel,SRC)
  self.assertIn('if (CPUthermalBatteryWarningSuppressionEnabled()) return 1;',SRC)
  self.assertIn('if (CPUthermalBatteryWarningSuppressionEnabled()) return 0;',SRC)
  self.assertIn('if (CPUthermalBatteryWarningSuppressionEnabled()) return nil;',SRC)
  self.assertIn('dispatch_once(&onceToken',SRC)
  self.assertIn('kCPUthermalSettingsChangedNotifC',SRC)
 def test_makefile_and_panel(self):
  self.assertIn('TWEAK_NAME = CPUthermal CPUthermalSpringBoard CPUthermalBatteryHealth CPUthermalBatteryComponent 0hello120hz',MF)
  self.assertIn('CPUthermalBatteryHealth_FILES = CPUthermalBatteryHealth.xm',MF)
  self.assertIn('CPUthermalBatteryHealth_PRIVATE_FRAMEWORKS = Preferences',MF)
  self.assertIn('CPUthermalBatteryHealth_LDFLAGS += $(ROOTHIDE_LDFLAGS)',MF)
  self.assertIn('ITEM("隐藏电池维修提示", "suppressBatteryServiceWarnings", PSSwitchCell, [NSNumber numberWithBool:NO])',PANEL)
if __name__=='__main__': unittest.main()
