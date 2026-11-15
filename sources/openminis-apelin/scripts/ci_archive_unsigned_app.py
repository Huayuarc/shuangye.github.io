import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import sys
import traceback
import zipfile


def main():
    root = pathlib.Path(os.environ['RUNNER_TEMP'])
    app = root / 'openminis-derived/Build/Products/Release-iphoneos/Minis.app'
    log = root / 'openminis-diagnostics/build.log'
    if '** BUILD SUCCEEDED **' not in log.read_text(errors='replace'):
        raise SystemExit('Release BUILD SUCCEEDED evidence missing')
    if not app.is_dir():
        raise SystemExit(f'Built app not found at expected path: {app}')
    expected = {'Minis.app': 'com.openminis.app',
                'PlugIns/MinisShare.appex': 'com.openminis.app.ShareExtension',
                'PlugIns/MinisFileProvider.appex': 'com.openminis.app.FileProvider',
                'PlugIns/AgentWidgetExtension.appex': 'com.openminis.app.AgentWidget'}
    actual_extensions = {str(p.relative_to(app)) for p in app.rglob('*.appex')}
    if actual_extensions != set(expected) - {'Minis.app'}:
        raise SystemExit(f'Unexpected embedded extensions: {sorted(actual_extensions)}')
    for relative, identifier in expected.items():
        bundle = app if relative == 'Minis.app' else app / relative
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != identifier:
            raise SystemExit(f'Bundle identifier mismatch: {relative}: {info.get("CFBundleIdentifier")!r}')
        executable = bundle / info['CFBundleExecutable']
        if not executable.is_file():
            raise SystemExit(f'Missing executable: {relative}: {executable.name}')
        result = subprocess.run(['codesign', '-dv', str(bundle)], capture_output=True, text=True)
        if result.returncode == 0 or 'not signed at all' not in result.stderr:
            raise SystemExit(f'Expected unsigned bundle: {relative}: exit={result.returncode}; {result.stderr.strip()}')
    if any(app.rglob('_CodeSignature')) or any(app.rglob('embedded.mobileprovision')):
        raise SystemExit('Unexpected signature/provisioning payload')
    entries = []
    for path in sorted(app.rglob('*')):
        mode = path.lstat().st_mode
        item = {'path': str(path.relative_to(app.parent)), 'mode': oct(stat.S_IMODE(mode))}
        if path.is_symlink():
            target = os.readlink(path)
            if not path.resolve().is_relative_to(app.resolve()):
                raise SystemExit(f'Symlink escapes app: {path}: {target}')
            item['symlink'] = target
        elif path.is_file():
            item.update(size=path.stat().st_size,
                        sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        elif not path.is_dir():
            raise SystemExit(f'Unsupported file: {path}')
        entries.append(item)
    out = root / 'openminis-unsigned-app'
    out.mkdir(exist_ok=True)
    ipa_root = root / 'openminis-ipa'
    payload = ipa_root / 'Payload'
    if ipa_root.exists():
        shutil.rmtree(ipa_root)
    payload.mkdir(parents=True)
    subprocess.run(['ditto', str(app), str(payload / 'Minis.app')], check=True)
    archive = out / 'Minis-unsigned.ipa'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', str(payload), str(archive)], check=True)
    with zipfile.ZipFile(archive) as z:
        names = set(z.namelist())
        if 'Payload/Minis.app/Info.plist' not in names:
            raise SystemExit('IPA is missing Payload/Minis.app/Info.plist')
        for item in entries:
            zip_path = 'Payload/' + item['path']
            member_name = zip_path + ('/' if 'sha256' not in item and 'symlink' not in item else '')
            member = z.getinfo(member_name)
            if stat.S_IMODE(member.external_attr >> 16) != int(item['mode'], 8):
                raise SystemExit(f'Archive permission mismatch: {item["path"]}: expected {item["mode"]}, got {oct(stat.S_IMODE(member.external_attr >> 16))}')
            if 'sha256' in item and hashlib.sha256(z.read(member_name)).hexdigest() != item['sha256']:
                raise SystemExit(f'Archive content mismatch: {item["path"]}')
            if 'symlink' in item and (not stat.S_ISLNK(member.external_attr >> 16)
                                      or z.read(member).decode() != item['symlink']):
                raise SystemExit(f'Archive symlink mismatch: {item["path"]}')
    summary = {'commit': os.environ['GITHUB_SHA'], 'run': os.environ['GITHUB_RUN_ID'],
               'app_path': 'Payload/Minis.app', 'unsigned': True, 'bundle_ids': expected,
               'app_bytes': sum(e.get('size', 0) for e in entries), 'files': entries}
    (out / 'APP-MANIFEST.json').write_text(json.dumps(summary, indent=2) + '\n')
    (out / 'SHA256SUMS').write_text(''.join(
        hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
        for p in (archive, out / 'APP-MANIFEST.json')))
    print(json.dumps({k: v for k, v in summary.items() if k != 'files'}, indent=2))
    print((out / 'SHA256SUMS').read_text())


if __name__ == '__main__':
    try:
        main()
    except SystemExit as exc:
        print(f'archive step failed: {exc}', file=sys.stderr)
        raise
    except Exception:
        traceback.print_exc()
        raise
