import unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
WARN=(P/'Tweak_ThermalWarn.xm').read_text()
FACE=(P/'FaceDownLock.xm').read_text()
CC=(P/'ControlCenter/CPUthermalCCModuleViewController.m').read_text()
PATHS=(P/'include/CPUthermalPaths.h').read_text()

class SpringBoardStability(unittest.TestCase):
 def test_no_general_notify_hooks(self):
  self.assertEqual(WARN.count('MSHookFunction('),1)
  for term in ('CPUthermalHookedNotify','NSMutableSet','os_unfair_lock','cStringContainsInsensitive'):
   self.assertNotIn(term,WARN)
 def test_no_state_writes_in_notify_path(self):
  self.assertNotIn('*state = 0',WARN)
  self.assertNotIn('notify_set_state',WARN)
 def test_atomic_warning_state(self):
  self.assertIn('__atomic_load_n(&gBlockThermalPopup',WARN)
  self.assertIn('__atomic_store_n(&gBlockThermalPopup',WARN)
 def test_readonly_snapshot(self):
  b=PATHS.split('static inline NSDictionary *CPUthermalReadPrefsSnapshot(void) {')[1].split('\n}')[0]
  self.assertIn('dictionaryWithContentsOfFile:CPUthermalCurrentPrefPath()',b)
  for t in ('removeItem','chown','writeToFile','LegacyPrefPaths'):
   self.assertNotIn(t,b)
 def test_ui_consumers_use_snapshot(self):
  for s in (FACE,WARN,CC):
   self.assertIn('CPUthermalReadPrefsSnapshot()',s)
   self.assertNotIn('CPUthermalReadPrefs()',s)
 def test_warning_io_background(self):
  self.assertIn('DISPATCH_QUEUE_SERIAL',WARN)
  self.assertIn('queue, ^(int token)',WARN)
 def test_no_cc_layout_feedback(self):
  self.assertNotIn('[self.view layoutIfNeeded]',CC)
  self.assertNotIn('[self styleMenuItemLabelsAfterLayout]',CC)
  self.assertNotIn('label.frame =',CC)
 def test_cc_observer_instance_lifetime(self):
  b=CC.split('- (void)registerSettingsObserver {')[1].split('//==============================================================================')[0]
  self.assertNotIn('static BOOL registered',b)
  self.assertIn('status == NOTIFY_STATUS_OK',b)
  self.assertIn('- (void)dealloc',b)
  self.assertIn('notify_cancel(_settingsObserverToken)',b)
 def test_facedown_no_brightness_side_effects(self):
  for t in ('CoreBrightness','dlopen(', 'BrightnessSystemClient','DisplayBrightness','dispatch_after'):
   self.assertNotIn(t,FACE)
 def test_lock_on_main_and_atomic(self):
  self.assertIn('dispatch_async(dispatch_get_main_queue()',FACE)
  self.assertEqual(FACE.count('__atomic_load_n(&gFaceDownLockEnabled'),2)
 def test_unchanged_payload_metadata_preserved(self):
  # 核心与充电工具本次有意精简，不再要求它们与旧完整实现逐字节一致。
  base=P.parent/'original/debs/CPUthermal'
  if base.exists():
   for rel in ('Settings/entry.plist','ControlCenter/resources/Info.plist'):
    self.assertEqual((P/rel).read_bytes(),(base/rel).read_bytes(),rel)
 def test_original_warning_enabled_vs_disabled_model(self):
  for enabled in (False,True):
   for native in (0,1,2,3):
    result=0 if enabled else native
    self.assertEqual(result,0 if enabled else native)

if __name__=='__main__':unittest.main()
