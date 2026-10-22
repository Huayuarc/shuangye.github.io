#!/usr/bin/env python3
"""Reproducible conservative subset; no build-host probing or path discovery."""
import plistlib,json,pathlib,posixpath
p=pathlib.Path(__file__).resolve().parents[1]
a=plistlib.loads((p/'upstream-hidePathList.plist').read_bytes())
if not isinstance(a,list):raise ValueError('array required')
# Deliberately omit bootstrap, injection libraries, prefs, package databases,
# SSH, system files, shared parent directories and live data directories.
explicit={'/.bootstrapped_electra','/.cydia_no_stash','/.installed_unc0ver','/var/containers/Bundle/.installed_rootlessJB3','/var/checkra1n.dmg','/var/cache/clutch.plist','/var/cache/clutch_cracked.plist','/var/mobile/Media/.evasi0n7_installed','/var/mobile/Library/.sbinjectSafeMode','/var/mobile/.eksafemode','/var/mobile/.ekenablelogging'}
apps={'Cydia.app','Sileo.app','Zebra.app','Filza.app','NewTerm.app','SBSettings.app','Flex3.app','FlyJB.app','iFile.app','Icy.app','RockApp.app','blackra1n.app','WinterBoard.app','MxTube.app','IntelliScreen.app','FakeCarrier.app'}
explicit.update('/Applications/'+s for s in apps)
prefixes=('/var/mobile/Library/Caches/','/var/mobile/Library/SplashBoard/Snapshots/','/var/mobile/Library/Saved Application State/','/var/mobile/Library/HTTPStorages/','/var/mobile/Library/WebKit/','/var/mobile/Library/Logs/Cydia','/var/log/jailbreakd-','/var/log/pspawn_payload_')
def canon(s):
 if s.startswith('/private/var/'):s=s[len('/private'):]
 return posixpath.normpath(s)
seen=set();good=[];removed=[]
for s in a:
 if not isinstance(s,str) or not s.startswith('/') or any(ord(c)<32 for c in s) or '..' in s.split('/'):
  removed.append({'path':str(s),'reason':'invalid'});continue
 n=canon(s)
 reason='duplicate' if n in seen else 'not-in-reviewed-subset' if not(n in explicit or n.startswith(prefixes)) else None
 if reason:removed.append({'path':s,'reason':reason});continue
 seen.add(n);good.append(n)
(p/'layout/usr/share/vnodebypass/hidePathList.plist').write_bytes(plistlib.dumps(good))
(p/'PATH_AUDIT.json').write_text(json.dumps({'input':len(a),'kept':len(good),'removed':removed,'added':[]},indent=2,ensure_ascii=False)+'\n')
# Compile-time whitelist prevents an edited plist from introducing unreviewed
# critical paths. Runtime realpath/F_GETPATH is checked against this same list.
quoted=',\n'.join('@'+json.dumps(s) for s in good)
header='#import <Foundation/Foundation.h>\nstatic BOOL VBReviewedPath(NSString *s) {\n if([s hasPrefix:@"/private/var/"])s=[s substringFromIndex:8];\n s=[s stringByStandardizingPath];\n return [@['+quoted+'] containsObject:s];\n}\n'
(p/'core/PathPolicy.h').write_text(header)
print(f'Paths: {len(a)} -> {len(good)}; removed {len(removed)}; additions: 0')
