#!/usr/bin/env python3
"""Reconstruct archive-omitted gitlinks using exact reviewed commits."""
import configparser
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'ci-source-manifest.json').read_text())
config = configparser.ConfigParser()
config.read(root / '.gitmodules')
expected = {
    'deps/ish': 'https://github.com/OpenMinis/ish-arm64.git',
    'deps/proot': 'https://github.com/OpenMinis/proot.git',
}
assert set(manifest['submodules']) == set(expected)
for relative, url in expected.items():
    section = config[f'submodule "{relative}"']
    assert section['path'] == relative and section['url'] == url
    commit = manifest['submodules'][relative]
    assert re.fullmatch(r'[0-9a-f]{40}', commit)
    destination = root / relative
    if destination.exists():
        raise SystemExit(f'Refusing to overwrite dependency: {relative}')
    subprocess.run(['git', 'clone', '--no-checkout', url, str(destination)], check=True)
    subprocess.run(['git', '-C', str(destination), 'checkout', '--detach', commit], check=True)
    actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == commit
    subprocess.run(['git', '-C', str(destination), 'submodule', 'update', '--init', '--recursive'], check=True)
    print(f'{relative}: {actual}', flush=True)
