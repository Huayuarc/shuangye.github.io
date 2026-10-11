import pathlib,sys,plistlib
p=pathlib.Path(__file__).resolve().parent
scheme=sys.argv[1]
if scheme not in ('rootless','roothide'): raise SystemExit('unsupported package scheme')
prefix='/var/jb' if scheme=='rootless' else ''
layout=p/'layout';scripts=layout/'DEBIAN';scripts.mkdir(parents=True,exist_ok=True)
daemon=plistlib.loads((p/'templates/daemon.plist').read_bytes())
daemon['ProgramArguments']=[prefix+'/usr/libexec/sbjetsamguard']
out=layout/'Library/LaunchDaemons/com.huayuarc.sbjetsamguard.plist';out.parent.mkdir(parents=True,exist_ok=True)
out.write_bytes(plistlib.dumps(daemon,sort_keys=False))
template=(p/'templates/maintainer.in').read_text()
for name in ('postinst','prerm'):
    f=scripts/name;f.write_text(template.replace('@SCHEME@',scheme).replace('@MODE@',name));f.chmod(0o755)
control=(p/'control').read_text()
lines=[x for x in control.splitlines() if not x.startswith('Depends:')]
lines.append('Depends: preferenceloader'+(', roothide (>= 0.1.0), launchctl (>= 1:1.2.0)' if scheme=='roothide' else ''))
(p/'control').write_text('\n'.join(lines)+'\n')
print('prepared '+scheme)
