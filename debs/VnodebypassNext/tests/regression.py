#!/usr/bin/env python3
"""Read-only project regression; no iOS execution, helper launch or kernel access.
Run: python3 tests/regression.py. Only tests/ and ../analysis/test-result.json are written.
Python models check stated invariants, not compiled Objective-C or real kernel behavior.
"""
import hashlib,json,pathlib,plistlib,posixpath,re,subprocess,sys,time
P=pathlib.Path(__file__).resolve().parents[1]; W=P.parent
T=P/'tests'; O=T/'out'; O.mkdir(exist_ok=True)
R=[]; commands=[]
def files():
    return sorted(x for x in subprocess.check_output(['rg','--files','-uuu',str(P)],text=True).splitlines() if not any(c in pathlib.Path(x).relative_to(P).parts for c in ('tests','build','.theos','.git')))
def snapshot():return {str(pathlib.Path(x).relative_to(P)):hashlib.sha256(pathlib.Path(x).read_bytes()).hexdigest() for x in files()}
def check(name,ok,detail=''):
    R.append({'id':name,'pass':bool(ok),'detail':detail});print(('PASS ' if ok else 'FAIL ')+name,flush=True)
def run(name,args,cwd=P):
    p=subprocess.run(args,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (O/(name+'.log')).write_text(p.stdout)
    commands.append({'id':name,'argv':[str(a) for a in args],'exit':p.returncode})
    check(name,p.returncode==0,p.stdout[-1600:] if p.returncode else 'exit=0');return p

def read(n):return (P/n).read_text()
def clean(s):return re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S)
def block(s,needle):
    start=s.index(needle);a=s.index('{',start);depth=0;quote=None;escape=False
    for i in range(a,len(s)):
        c=s[i]
        if quote:
            if escape:escape=False
            elif c=='\\':escape=True
            elif c==quote:quote=None
        elif c in ('"',"'"):quote=c
        elif c=='{':depth+=1
        elif c=='}':
            depth-=1
            if depth==0:return s[a+1:i]
    raise ValueError('unbalanced '+needle)

before=snapshot(); C=clean(read('core/Controller.m')); K=clean(read('core/kernel.m'))
F=clean(read('shared/Frontend.h')); A=clean(read('ui/App.m')); B=clean(read('ui/VBModule.m')); G=clean(read('ui/TouchGate.h'))
D=pathlib.Path('/var/minis/attachments/uploads/kr.xsf1re.vnodebypass_0.4.6-Next_iphoneos-arm64.deb')
expected='b10a915a0b6944481838f8b1ef3979924904ff5be6aa714e3a8f5effadacd7fd'
deb0=hashlib.sha256(D.read_bytes()).hexdigest()
SDK=W/'iPhoneOS16.5.sdk'
flags=['clang','-target','arm64-apple-ios15.0','-isysroot',str(SDK),'-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-Wno-unused-parameter']
for source in ['core/Controller.m','core/kernel.m','ui/App.m','ui/VBModule.m']:
    run('syntax_'+pathlib.Path(source).stem,flags+['-fsyntax-only',source])
run('syntax_fishhook',['clang','-target','arm64-apple-ios15.0','-isysroot',str(SDK),'-fsyntax-only','core/fishhook.c'])
# Real compiler/linker; output is unsigned test-only arm64 Mach-O, never installed.
run('ui_compile_link',['sh','ui/build-check.sh',str(SDK),str(O/'ui')])
for name in ('App','VBModule'):
    binary=O/'ui'/('App.app/vnodebypass' if name=='App' else 'VBModule.bundle/VBModule')
    if not binary.exists():check(name+'_no_kernel_link',False,'missing linked binary');continue
    q=subprocess.run(['llvm-nm','--undefined-only',str(binary)],text=True,capture_output=True)
    imports=subprocess.run(['llvm-objdump','--macho','--dylibs-used',str(binary)],text=True,capture_output=True)
    (O/(name+'-imports.log')).write_text(q.stdout+imports.stdout)
    check(name+'_no_kernel_link',q.returncode==0 and imports.returncode==0 and not re.search(r'\b_(?:kread\w*|kwrite\w*|init_kernel|hide_path|show_path|getVnode\w*|proc_find)\b|libjailbreak',q.stdout+imports.stdout),'fresh linked Mach-O undefined symbols + LC_LOAD_DYLIB')
plists=[]
for filename in subprocess.check_output(['rg','--files',str(P),'-g','*.plist','-g','!tests/**'],text=True).splitlines():
    if '/tests/' in filename:continue
    raw=pathlib.Path(filename).read_bytes();plistlib.loads(raw);plists.append(str(pathlib.Path(filename).relative_to(P)))
check('plist_all_parse',bool(plists),str(len(plists))+' plists parsed using plistlib')
xmlpaths=[p for p in plists if p!='upstream-hidePathList.plist']
check('generated_plists_xml',all((P/p).read_bytes().lstrip().startswith(b'<?xml') for p in xmlpaths),'upstream input may be binary; all project-generated plists are XML')
for n in ('preinst','postinst','prerm'):run('shell_syntax_'+n,['sh','-n','scripts/'+n])
run('prepare_paths_python_syntax',['python3','-c','import ast,pathlib;ast.parse(pathlib.Path("scripts/prepare_paths.py").read_text())'])

# Structural assertions are intentionally source checks, not runtime proofs.
selected=block(B,'- (void)setSelected:')
check('cc_setSelected_presentation_only',not re.search(r'performCommand|VBRunHelper|enable|disable|showUserActions|handleUserTouch',selected),'setter contains rendering only')
check('touch_gate_completed_in_control',all(x in G for x in ('!control','!event','UIEventTypeTouches','UITouchPhaseEnded','isDescendantOfView:control','pointInside:','locationInView:control')))
check('app_enable_real_touch', 'VBRealTouch(sender, event)' in block(A,'- (void)enableTapped:'))
check('app_disable_real_touch','VBRealTouch(sender, event)' in block(A,'- (void)disableTapped:'))
check('cc_real_touch_before_actions','if (!VBRealTouch(control, event)' in block(B,'- (void)handleUserTouchFromControl:(UIControl *)control event:(UIEvent *)event {'))
check('app_cc_touch_event_wiring','@selector(enableTapped:event:)' in A and '@selector(disableTapped:event:)' in A and '@selector(buttonTapped:event:)' in B and 'UIControlEventTouchUpInside' in A and 'UIControlEventTouchUpInside' in B)
check('enable_requires_explicit_alert',all('UIAlertActionStyleDestructive' in s and 'performCommand:@"enable"' in s and 'VBEnableWarning()' in s for s in (A,B)))
check('app_foreground_query_only',block(A,'- (void)becameActive').strip()=='[VBFrontend.shared query];')
check('cc_lifecycle_query_only',all('[VBFrontend.shared query]' in block(B,n) and 'performCommand' not in block(B,n) for n in ('- (void)viewWillAppear:','- (void)controlCenterWillPresent','- (void)willBecomeActive')))
check('darwin_notification_query_only','[client query]' in block(F,'static void VBDarwinChanged') and 'performCommand' not in block(F,'static void VBDarwinChanged'))
check('frontend_query_status_only','VBRunHelper(@"status")' in block(F,'- (void)query {') and 'VBRunHelper(@"enable")' not in block(F,'- (void)query {'))
check('frontend_serial_and_status_after_write','DISPATCH_QUEUE_SERIAL' in F and 'VBRunHelper(command)' in F and 'VBResult *current = VBRunHelper(@"status")' in F)
check('spawn_attr_address','posix_spawn(&pid, VB_HELPER_PATH, &actions, &attr, argv, envp)' in F)
check('spawn_persona_errors_checked',all(re.search(r'rc\s*=\s*'+name+r'\(&attr,',F) for name in ('posix_spawnattr_set_persona_np','posix_spawnattr_set_persona_uid_np','posix_spawnattr_set_persona_gid_np')))
check('spawn_exit_wait_status','WIFEXITED(status)' in F and 'WEXITSTATUS(status)' in F and 'WIFSIGNALED(status)' in F and 'WTERMSIG(status)' in F and 'while (waited < 0 && errno == EINTR)' in F)
check('pipe_fd_safe_and_error_checked','if (pipe(p) != 0)' in F and 'F_DUPFD_CLOEXEC, 3' in F and 'FD_CLOEXEC' in F and 'close(wr); close(nullfd)' in F)
check('pipe_drains_overflow_before_wait',F.index('for (;;)')<F.index('waitpid(pid') and 'else overflow = YES;' in F and 'if (n < 0 && errno == EINTR) continue' in F and 'readError' in F)
check('spawn_clean_environment', 'char *envp[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", NULL }' in F)
check('frontend_protocol_xml_validation','format != NSPropertyListXMLFormat_v1_0' in F and 'VBValidCount(d[@"hidden"])' in F and 'exitCode == 0' in F)
main=block(C,'int main('); en=block(C,'static int enable('); dis=block(C,'static int disable(')
dispatch='int rc=[cmd isEqual:@"status"]?status(j)'
check('helper_root_and_locked_before_dispatch',all(main.index(x)<main.index(dispatch) for x in ('getuid()!=0','geteuid()!=0','getgid()!=0','getegid()!=0','flock(fd,LOCK_EX|LOCK_NB)','loadJournal(&exists)')))
check('helper_boot_before_any_kernel_dispatch',main.index('NSString *boot=bootID()')<main.index('if(j&&![j[@"boot"] isEqual:boot])')<main.index(dispatch) and not re.search(r'kread\d*\(|initBackend\(|init_kernel\(',main[:main.index(dispatch)]))
check('old_boot_status_no_replay','if([cmd isEqual:@"status"]){close(fd);return reply(@"disabled"' in main and 'j=nil;' in main)
check('preparing_restoring_reject_before_dispatch',main.index('if(j&&(![j[@"stage"] isEqual:@"stable"]||!entriesValid(j)))')<main.index(dispatch))
check('preparing_persisted_before_counter_write',en.index('@"stage":@"preparing"')<en.index('if(!writeSecure(j))')<en.index('kwrite32('))
check('restoring_persisted_before_visibility_write',dis.index('j[@"stage"]=@"restoring"')<dis.index('if(!writeSecure(j))')<dis.index('show_path('))
loops=list(re.finditer(r'for\(NSMutableDictionary \*row in j\[@"entries"\]\)',dis))
check('restore_all_show_before_any_release',len(loops)==2 and loops[0].start()<dis.index('show_path(')<loops[1].start()<dis.index('io-1') and 'kwrite32(' not in dis[loops[0].start():loops[1].start()])
check('kernel_write_error_propagates','return kwrite32_(va, v);' in K and 'return kwrite32(vnode + off_vnode_vflags' in K)
check('controller_kernel_write_errors_checked',all(re.search(r'if\('+s+r'\([^;]+!=0',C) for s in ('kwrite32','hide_path','show_path')) and 'u+1)!=0||kwrite32' in en and 'io-1)!=0||kwrite32' in dis)
check('visibility_write_readback','if(!(kread32(v+off_vnode_vflags)&Shadow))return' in en and 'if(kread32(v+off_vnode_vflags)&Shadow)return' in dis)
check('reference_write_readback_enable','kread32(v+off_vnode_usecount)!=u+1' in en and 'kread32(v+off_vnode_iocount)!=io+1' in en)
ws=block(C,'static BOOL writeSecure(')
check('journal_write_checked_and_atomic',all(s in ws for s in ('if(!d)return NO','mkstemp','fchmod(fd,0600)==0','errno==EINTR','if(n<=0)','fsync(fd)==0','rename(name,Journal.fileSystemRepresentation)==0','if(!ok)unlink(name)')))
check('journal_directory_open_failure_checked',bool(re.search(r'if\(dir<0\)|if\(dir>=0\).*?else',ws,re.S)),'strict durability: current open(directory) failure is silently accepted')
check('journal_secure_read','O_RDONLY|O_NOFOLLOW|O_CLOEXEC' in C and 'st.st_uid==0' in C and 'st.st_nlink==1' in C and '4*1024*1024' in C)
check('protocol_stdout_isolated',main.index('dup(STDOUT_FILENO)')<main.index('dup2(STDERR_FILENO,STDOUT_FILENO)')<main.index('loadJournal(') and 'fwrite(d.bytes,1,d.length,protocol)!=d.length' in C and 'fflush(protocol)!=0' in C and not re.search(r'\b(?:printf|puts)\(',C))
check('status_no_kernel_writes',not re.search(r'kwrite|hide_path\(|show_path\(',block(C,'static int status(')+block(C,'static BOOL countHidden(')))

paths=plistlib.loads((P/'layout/usr/share/vnodebypass/hidePathList.plist').read_bytes())
def canon(s):
    if s.startswith('/private/var/'):s=s[8:]
    return posixpath.normpath(s)
roots={'/','/System','/bin','/sbin','/usr','/usr/bin','/usr/sbin','/usr/lib','/usr/libexec','/Library','/Applications','/var','/private','/private/var','/var/lib','/var/cache','/var/log','/var/mobile','/var/mobile/Library','/var/mobile/Library/Caches','/var/containers','/var/containers/Bundle','/etc','/tmp','/var/run','/var/tmp'}
blocked=('/System/','/bin/','/sbin/','/usr/bin/','/usr/sbin/','/usr/lib/','/usr/libexec/','/var/jb/','/private/preboot/','/Library/MobileSubstrate/','/Library/PreferenceBundles/','/var/mobile/Library/Preferences/','/var/lib/dpkg/','/var/lib/apt/','/var/run/','/tmp/','/var/tmp/')
def unsafe(s):
    n=canon(s)
    return n in roots or n in {'/var/jb','/private/preboot','/Library/MobileSubstrate','/Library/PreferenceBundles','/var/lib/dpkg','/var/lib/apt','/var/mobile/Library/Preferences'} or n.startswith(blocked) or n.endswith(('.dylib','.framework'))
check('paths_nonempty_absolute_wellformed',isinstance(paths,list) and 0<len(paths)<=1024 and all(isinstance(s,str) and s.startswith('/') and '..' not in s.split('/') and not any(ord(c)<32 for c in s) for s in paths),str(len(paths))+' final packaged paths')
check('paths_unique_canonical_aliases',len(set(map(canon,paths)))==len(paths),'canonicalizes /private/var aliases')
check('paths_exclude_system_bootstrap_public_roots',not any(unsafe(s) for s in paths),str([s for s in paths if unsafe(s)]))
policy=clean(read('core/PathPolicy.h')) if (P/'core/PathPolicy.h').exists() else ''
reviewed=re.findall(r'@"(/[^"\n]*)"',policy)
reviewed=[s for s in reviewed if s!='/private/var/']
check('runtime_reviewed_whitelist_matches_plist',set(reviewed)==set(paths) and len(reviewed)==len(paths) and 'VBReviewedPath(p)' in block(C,'static BOOL pathAllowed('),'compile-time exact whitelist protects edited plist and resolved paths')
check('runtime_checks_input_realpath_and_open_fd',all(x in en for x in ('pathAllowed(path)','pathAllowed(resolved)','pathAllowed([NSString stringWithUTF8String:actual])','fcntl(held,F_GETPATH,actual)','O_NOFOLLOW|O_NONBLOCK','getVnodeAtFD(held)')))
audit=json.loads(read('PATH_AUDIT.json'))
check('path_audit_counts',audit['kept']==len(paths) and audit['input']==len(paths)+len(audit['removed']) and audit.get('added')==[],str({k:audit[k] for k in ('input','kept','added')}))
check('prepared_paths_no_external_additions',set(paths)<=set(canon(s) for s in plistlib.loads((P/'upstream-hidePathList.plist').read_bytes())) and not any(unsafe(s) for s in reviewed))
scripts={n:read('scripts/'+n) for n in ('preinst','postinst','prerm')}
check('maintainer_no_rm_rf',not any(re.search(r'\brm\s+[^\n]*(?:-[^\s]*[rR]|--recursive)',clean(s)) for s in scripts.values()),'scripts syntax-checked only; never executed')
check('maintainer_no_implicit_enable',not any(re.search(r'/vnodebypass\s+enable\b',s) for s in scripts.values()),'explicit package removal/upgrade may call disable; no maintainer script enables hiding')
check('maintainer_no_broad_bootstrap_delete',not any(re.search(r'\brm\s+[^\n]*(?:/var/jb/basebin|/private/preboot|/var/jb(?:\s|$))',s) for s in scripts.values()),'postinst only removes one fixed orphan filter; chmod/uicache still mutate metadata')
check('preinst_legacy_guard', '/tmp/vnodebypass.txt' in scripts['preinst'] and 'exit 1' in scripts['preinst'])

# This model mirrors the stage admission condition only, not ObjC execution.
# Any crash once counter/flag writes can occur leaves preparing/restoring,
# which main rejects until a full kernel reboot changes the boot ID.
model=[]
for stage in ('preparing','restoring','stable'):
 for oldboot in (False,True):
  for command in ('status','enable','disable'):
   replay=(not oldboot and stage=='stable')
   model.append({'stage':stage,'old_boot':oldboot,'command':command,'replay':replay})
check('model_interrupted_stages_never_replayed',all(not x['replay'] for x in model if x['stage']!='stable'))
check('model_old_boot_never_replayed',all(not x['replay'] for x in model if x['old_boot']))
check('original_deb_unchanged',deb0==expected==hashlib.sha256(D.read_bytes()).hexdigest())
after=snapshot();check('audit_did_not_mutate_project_sources',before==after)
result={'kind':'static source checks + real cross-compilation/link + stage-admission model; NOT iOS runtime test','pass':sum(x['pass'] for x in R),'fail':sum(not x['pass'] for x in R),'checks':R,'commands':commands,'model':model,'source_sha256':after,'remaining':['No target-device testing','Non-atomic upstream kernel reference/flag primitive remains experimental','No comprehensive detection bypass claim','Exact device/OS offsets not validated']}
(W/'analysis').mkdir(exist_ok=True)
(W/'analysis/test-result.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
print('TOTAL',result['pass'],'PASS',result['fail'],'FAIL')
sys.exit(1 if result['fail'] else 0)
