#!/usr/bin/env python3
"""Export reviewed worktree source, not history/configuration/build caches."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
DENIED = {'.git', '.env', '.ssh', 'xcuserdata', 'DerivedData', '__pycache__',
          'node_modules', '.build', '.swiftpm'}
# Pinned upstream redaction-test strings and a tiny console test fixture.
# Changed bytes lose the exception and must be reviewed again.
REVIEWED = {
    'vendor/apelin/Documents/Console/fixtures/apelin-smoke_1.0_all.deb': '282c2829cf1f5ffca8a11b4eb2e26f3d8ef0002b454efdc7fc46376c564a107d',
    'vendor/apelin/Packages/ApelinKit/Tests/ApelinCoreTests/LogRedactionTests.swift': 'fc8c5e55a1426639a7a5f341499999a09fbc8625df5bcec350847b32c172bd30',
    'vendor/apelin/Packages/ApelinKit/Tests/ApelinProtocolTests/FeedbackRulesTests.swift': '87d5fe3f86654e97e68bae4b1a213686ab892a4b724d41e1ad1904a7e44c344f',
}
SUFFIXES = {'.pem', '.key', '.p12', '.p8', '.mobileprovision', '.deb', '.ipa', '.log'}
SECRET = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-ant-api\d+-[A-Za-z0-9_-]{30,}')

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Write source tar.gz after checks')
    args = parser.parse_args()
    indexed = git('ls-files', '--stage', '-z').decode().split('\0')
    pins = {}
    for entry in indexed:
        if entry.startswith('160000 '):
            metadata, path = entry.split('\t', 1)
            pins[path] = metadata.split()[1]
    names = sorted(set(git('ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().rstrip('\0').split('\0')))
    manifest, problems = {}, []
    for name in names:
        if not name or name in pins:
            continue
        path = ROOT / name
        parts = Path(name).parts
        reviewed = path.is_file() and not path.is_symlink() and REVIEWED.get(name) == hashlib.sha256(path.read_bytes()).hexdigest()
        if any(p in DENIED or p.startswith('.env.') for p in parts) or (parts and parts[0] == 'Attachments') or (path.suffix in SUFFIXES and not reviewed) or name == 'apelin-project.json':
            problems.append(f'excluded/private candidate: {name}')
            continue
        if name.endswith('ProviderCustomization.xcconfig') or name.endswith('provider-customization.properties'):
            problems.append(f'private customization: {name}')
            continue
        if path.is_symlink() or not path.is_file():
            problems.append(f'unreviewed symlink or missing source: {name}')
            continue
        data = path.read_bytes()
        if SECRET.search(data) and not reviewed:
            problems.append(f'credential pattern: {name}')
        if len(data) > 50 * 1024 * 1024:
            problems.append(f'oversize source: {name}')
        manifest[name] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    report = {'files': len(manifest), 'bytes': sum(v['bytes'] for v in manifest.values()),
              'submodules': pins, 'problems': problems,
              'note': 'Pattern scan is not a guarantee; review public configuration before push.'}
    print(json.dumps(report, indent=2))
    if problems:
        raise SystemExit(1)
    if args.output:
        if args.output.exists():
            raise SystemExit('Refusing to overwrite an existing archive')
        with tarfile.open(args.output, 'w:gz') as archive:
            for name in manifest:
                archive.add(ROOT / name, arcname=name, recursive=False)
            payload = json.dumps({'files': manifest, 'submodules': pins}, indent=2).encode()
            entry = tarfile.TarInfo('ci-source-manifest.json')
            entry.size = len(payload)
            archive.addfile(entry, io.BytesIO(payload))

if __name__ == '__main__':
    main()
