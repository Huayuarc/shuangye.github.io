#!/usr/bin/env python3
from pathlib import Path
import hashlib,plistlib,re,subprocess,json,sys
p=Path(__file__).parent;o=p.parent/'original/var/jb';r=[]
def ck(n,v,d=''):r.append({'check':n,'pass':bool(v),'detail':d});print(('PASS ' if v else 'FAIL ')+n)
def sha(x):return hashlib.sha256(Path(x).read_bytes()).hexdigest()
ck('desktop_app_exact',sha(p/'layout/Applications/vnodebypass.app/vnodebypass')=='25f457fae040699504082b8ca4e94e5c5238affe18c3fd3147569adba942bf42')
ck('helper_exact',sha(p/'layout/usr/bin/vnodebypass')=='7b5e74eceee07dfc94f8df766eb168a83f0a52faf12af8a48888bca97c93a4f6')
ck('full_list_exact',sha(p/'layout/usr/share/vnodebypass/hidePathList.plist')=='5b3859bf4849f290b4198283ccb5886d3e23aba48dbaca8026e12f0ceae2c07b')
a=plistlib.loads((p/'layout/usr/share/vnodebypass/hidePathList.plist').read_bytes());ck('full_290_entries',len(a)==290 and len(set(a))==276,f'{len(a)}/{len(set(a))}')
s=(p/'VBModule.m').read_text()
setter=s[s.index('- (void)setSelected:'):]
ck('legacy_superclass','@interface VBModule : CCUIToggleModule' in s and '_OBJC_CLASS_$_CCUIToggleModule' in subprocess.check_output(['llvm-nm',str(p/'build/VBModule.arm64')],text=True))
ck('programmatic_setter_returns','if(!VBRealModuleTouch())return;' in setter and setter.index('if(!VBRealModuleTouch())return;')<setter.index('VBRun('))
ck('current_event_touch_gate',all(x in s for x in ('_currentEvent','currentEvent','UIEventTypeTouches','UITouchPhaseEnded')))
ck('no_unsupported_content_controller','contentViewController' not in s and 'VBTouchToken' not in s and 'addGestureRecognizer' not in s)
ck('legacy_commands',all(x in setter for x in ('VBRun(@"-s")','VBRun(@"-h")','VBRun(@"-xr")','VBRun(@"-R")')))
ck('persona_attr_passed','posix_spawn(&pid,p.fileSystemRepresentation,NULL,&a,argv,env)' in s)
ck('spawn_exit_checked',all(x in s for x in ('WIFSIGNALED','WTERMSIG','WIFEXITED','WEXITSTATUS','errno==EINTR')))
ck('concurrency_gate','@synchronized(VBModule.class)' in s and 'VBBusy' in s and 'DISPATCH_QUEUE_SERIAL' in s)
ck('fixed_helper_name','applicationProxyForIdentifier' not in s and 'vnodebypass' in s)
ck('old_probe_unchanged','access("/var/jb/bin/bash",F_OK)!=0' in s)
ck('cc_no_kernel_code',not re.search(r'\b(init_kernel|kread\w*|kwrite\w*|hide_path|show_path|getVnode)\b',s))
for n in ('preinst','postinst','prerm'):
 interp='bash' if (p/'scripts'/n).read_text().startswith('#!/bin/bash') else 'sh'
 ck('shell_'+n,subprocess.run([interp,'-n',str(p/'scripts'/n)]).returncode==0)
ck('local_arm64e_object',subprocess.check_output(['file',str(p/'build/VBModule.arm64e.o')],text=True).find('arm64e')>=0)
ck('resources_valid',plistlib.loads((p/'Resources/Info.plist').read_bytes())['NSPrincipalClass']=='VBModule')
result={'pass':sum(x['pass'] for x in r),'fail':sum(not x['pass'] for x in r),'checks':r,'scope':'static/local compile only; target-device CC touch timing pending'}
(p/'TEST-RESULT.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n');print('TOTAL',result['pass'],'PASS',result['fail'],'FAIL');sys.exit(bool(result['fail']))
