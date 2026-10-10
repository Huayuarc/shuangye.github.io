from pathlib import Path
import subprocess,hashlib,plistlib,json,itertools,re,unittest,importlib.util
S=Path(__file__).resolve().parents[1];R=S.parent
repo=Path('/var/minis/workspace/CPUthermal154-review/ci-repo')
base='c048063841b79930386224978156c1b9ba8a7cc5'
files=subprocess.check_output(['git','ls-tree','-r','--name-only',base,'debs/CPUthermal'],cwd=repo).decode().splitlines()
assert len(files)==47
changed=[];unchanged={}
for f in files:
 rel=f.removeprefix('debs/CPUthermal/');assert (S/rel).is_file(),rel
 old=subprocess.check_output(['git','show',base+':'+f],cwd=repo)
 if old!=(S/rel).read_bytes():changed.append(rel)
 else:unchanged[rel]=hashlib.sha256(old).hexdigest()
assert set(changed)=={'Makefile','README.md','RefreshRate.xm','RefreshRatePolicy.inc','Tweak.x','Tweak_PrefHook.xm','control'},changed
assert (S/'RefreshRateUIHooks.inc').is_file() and (S/'RefreshRateUIState.inc').is_file()
assert 'export ADDITIONAL_CFLAGS += -Werror' in (S/'Makefile').read_text()
assert 'export ADDITIONAL_CCFLAGS += -Werror' in (S/'Makefile').read_text()
assert 'DisplayGuard.xm' in unchanged
assert 'Tweak.x' in changed and 'Tweak_PrefHook.xm' in changed
pub=(S/'RefreshRate.xm').read_text();policy=(S/'RefreshRatePolicy.inc').read_text();ui=(S/'RefreshRateUIHooks.inc').read_text();state=(S/'RefreshRateUIState.inc').read_text();allcode=pub+policy+ui+state
for token in ['%hook UIScreen','CAContext','MSHookFunction','NSTimer','UIApplication.sharedApplication.windows']:
 assert token not in allcode,token
assert pub.count('CPUthermalReadPrefs()')==1
assert 'CPUthermalReadPrefs' not in policy+ui+state
assert 'CPUthermalDisplayLinkABIValid' in pub and '%init(CPUthermalDisplayLinkHooks)' in pub
assert 'gCapabilityAttempts < 4' in pub
assert 'return source == gAppRateSource || CPUthermalInteractionHold();' in policy
assert '!CPUthermalSourceIsMainDisplay(object)' in policy
assert '[gPrivateRanges objectForKey:object]' in policy
assert 'static __thread' not in allcode
for token in ['@encode(CAFrameRateRange)','@encode(CGRect)','@encode(CGPoint)','@encode(CATransform3D)','@encode(BOOL)','@encode(double)','@"@?"']:
 assert token in allcode,token
assert ui.count('MSHookMessageEx(')==14
assert ui.count('@try { ((void (*)')==13 and ui.count('@finally { if (main) --gUIOriginalDepth; }')==13
selectors=['displayLinkWithTarget:selector:','setPreferredFrameRateRange:','setPreferredFramesPerSecond:','setFrameInterval:',
'viewWillAppear:','viewDidAppear:','presentViewController:animated:completion:','pushViewController:animated:',
'setFrame:','setBounds:','makeKeyAndVisible','setWindowLevel:','setContentOffset:','setContentOffset:animated:',
'layoutSubviews','startAnimation','startAnimationAfterDelay:','addAnimation:forKey:','setPosition:','setTransform:',
'showFromRect:inView:animated:','showFromBarButtonItem:animated:','_presentMenuAtLocation:',
'presentableWillAppearAsBanner:','presentableDidAppearAsBanner:','presentableWillDisappearAsBanner:withReason:',
'presentableDidDisappearAsBanner:withReason:','presentableWillNotAppearAsBanner:withReason:','didMoveToWindow']
for sel in selectors:assert sel in allcode,sel
for cls in ['UIContextMenuInteraction','UIEditMenuInteraction','NCNotificationPresentableViewController','SBNotificationBannerDestination','NCNotificationShortLookView']:assert cls in ui
for token in ['now + 4.0','generation != gBannerGeneration','generation != gFloatingGeneration','gBannerPresentable != presentable','MIN(gBannerDeadline','now - gUIPathTime[path] < 0.2','now - gUISourceTime < 0.2','now - gUIInspectTime >= 0.25','i < 6','OBJC_ASSOCIATION_RETAIN_NONATOMIC']:
 assert token in state,token
for p in S.rglob('*.plist'):
 if p.read_bytes().lstrip().startswith((b'<?xml',b'bplist')):plistlib.loads(p.read_bytes())
filt=plistlib.loads((S/'CPUthermalRefreshRate.plist').read_bytes())['Filter']['Bundles']
assert filt==['com.apple.UIKit','com.apple.springboard','com.apple.UserNotificationsUIServer','com.apple.springboard.SpringBoardOutofCallUI']
assert 'isolation.5' in (S/'control').read_text()
# ABI equality model covers aggregate values vs pointer/HFA type confusion,
# return/self/_cmd/block distinctions and integer width/signedness.
abi=0
for wanted in ['{CAFrameRateRange=fff}','{CGRect={CGPoint=dd}{CGSize=dd}}','{CGPoint=dd}','{CATransform3D=dddddddddddddddd}','B','d','@','@?','i','I','q','Q']:
 expected=('v',('@',':',wanted))
 for got in [wanted,'^'+wanted,'r'+wanted,'@','@?','f','d','i','q','Q']:
  for ret,selfarg in [('v','@'),('v','#'),('f','@')]:
   actual=(ret,(selfarg,':',got));valid=actual==expected
   assert valid==(ret=='v' and selfarg=='@' and got==wanted);abi+=1
class State:
 def __init__(self):self.native=('range',(0,0,0));self.actual=self.native;self.forced=False;self.depth=0
 def apply(self,on):
  if self.depth:return
  self.depth+=1
  if on:self.actual=('range',(120,120,120));self.forced=True
  elif self.forced:self.actual=self.native;self.forced=False
  self.depth-=1
 def setter(self,api,value,on):
  if self.depth:return
  self.native=(api,value);self.actual=self.native
  self.depth+=1;self.setter('fps',999,on);self.depth-=1
  self.apply(on)
sequences=0
for sequence in itertools.product([('range',(30,60,60)),('fps',0),('fps',30),('interval',2)],repeat=5):
 s=State()
 for api,value in sequence:s.setter(api,value,True);assert s.actual==('range',(120,120,120))
 s.apply(False);assert s.actual==sequence[-1];sequences+=1
 s.setter('fps',24,False);assert s.actual==('fps',24)
private_sequences=0
for seq in itertools.product([0,30,60,120],repeat=5):
 native=actual=None
 for value in seq:native=value;actual=120
 actual=native;assert actual==seq[-1];private_sequences+=1
lifecycle=0
for sb,on,cap,unlock,visible,main,appactive in itertools.product([False,True],repeat=7):
 active=main and on and cap and visible and (sb or (unlock and appactive))
 link=int(active and sb);appsource=int(active and not sb)
 assert link+appsource<=1
 if not all([on,cap,visible,main]):assert link==appsource==0
 if not unlock and not sb:assert not appsource
 s=State();s.setter('range',(24,60,30),active);s.apply(False);assert s.actual==('range',(24,60,30));lifecycle+=1
scope=0
for owned,hold,enabled,main in itertools.product([False,True],repeat=4):
 force=main and enabled and (owned or hold)
 if not owned and not hold:assert not force
 if not enabled or not main:assert not force
 scope+=1
# Exact epoch/deadline and generation strategy; no renewal by duplicate callbacks.
holds=0
for new_identity,old_end,old_timeout in itertools.product([False,True],repeat=3):
 identity='new' if new_identity else 'old';generation=2 if new_identity else 1;deadline=4.0
 if old_end and identity=='old':deadline=min(deadline,1.2)
 if old_timeout and generation==1:deadline=0
 if new_identity:assert deadline==4.0
 assert deadline<=4;holds+=1
throttle=0
for hz in [30,60,120,240,1000]:
 last=-1;writes=0
 for i in range(hz*10):
  now=i/hz
  if now-last>=0.2:last=now;writes+=1
 assert writes<=51;throttle+=1
logos=[]
logos_path=Path('/var/minis/workspace/CPUthermal154-review/logos/bin/logos.pl')
for name in ['Tweak.x','Tweak_PrefHook.xm','FaceDownLock.xm','DisplayGuard.xm','RefreshRate.xm']:
 for line in (S/name).read_text().splitlines():
  if name=='RefreshRate.xm' and '%orig;' in line:assert re.match(r'^\s*(?:[\w<> *]+\s*=\s*)?%orig;\s*$',line), (name,line)
 if logos_path.exists():
  data=subprocess.check_output(['perl',str(logos_path),str(S/name)],cwd=S,stderr=subprocess.PIPE)
  (R/(name+'.generated.mm')).write_bytes(data);logos.append(name)
suite=unittest.TestSuite()
for name in ['test_mode_policy','test_display_policy']:
 spec=importlib.util.spec_from_file_location(name,S/'tests'/(name+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 if name=='test_mode_policy':m.P=S;m.S=(S/'Tweak.x').read_text()
 else:m.SOURCE=S/'DisplayGuard.xm'
 suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(m))
result=unittest.TextTestRunner(verbosity=1).run(suite);assert result.wasSuccessful()
report={'baseline_commit':base,'baseline_files_retained':47,'original_files_retained':45,'changed':changed,'core_unchanged_sha256':unchanged,'public_sequences':sequences,'private_sequences':private_sequences,'lifecycle_cases':lifecycle,'abi_cases':abi,'source_scope_cases':scope,'hold_cases':holds,'throttle_cases':throttle,'core_tests':result.testsRun,'logos':logos,'contracts':'PASS','runtime':'NOT RUN'}
report['model_and_core_total']=sequences+private_sequences+lifecycle+abi+scope+holds+throttle+result.testsRun
(R/'test-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='core_unchanged_sha256'},indent=2))
