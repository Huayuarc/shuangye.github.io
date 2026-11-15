#!/usr/bin/env python3
"""Build the versioned, reproducible zstd template archive published by CI."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/Packages')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?', args.version):
        parser.error('version must be a semantic version')
    subprocess.run(['python3', '-I', '-B', str(ROOT / 'Extensions/Development/check-templates.py'), '--no-build'], check=True)
    source = ROOT / 'Extensions/Development'
    files = {}
    extensions = []
    for manifest in sorted(source.glob('*/manifest.json')):
        directory = manifest.parent
        description = json.loads(manifest.read_text())
        extensions.append({'id': description['id'], 'version': description['version'], 'templates': description['templates']})
        for file in sorted(directory.rglob('*')):
            if file.is_symlink():
                raise ValueError('template archives must not contain symbolic links')
            if file.is_file():
                files[file.relative_to(source).as_posix()] = file.read_bytes()
    files['catalog.json'] = (json.dumps({
        'formatVersion': 1, 'appVersion': args.version,
        'builtinTemplates': [{'id': 'wiki.qaq.apelin.workspace/empty', 'displayName': 'Empty'}],
        'extensions': extensions,
    }, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / ('Apelin_' + args.version + '_Templates.tar.zst')
    with tempfile.TemporaryDirectory(prefix='apelin-templates-') as work:
        archive = Path(work) / 'templates.tar'
        with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT) as tar:
            for name, data in sorted(files.items()):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                info.mtime = 0
                tar.addfile(info, io.BytesIO(data))
        compressed = Path(work) / 'templates.tar.zst'
        with compressed.open('wb') as output:
            subprocess.run(['zstd', '-q', '-T1', '-19', '-c', str(archive)], stdout=output, check=True)
        decoded = subprocess.check_output(['zstd', '-q', '-d', '-c', str(compressed)])
        if decoded != archive.read_bytes():
            raise ValueError('the compressed template archive did not round-trip')
        with tarfile.open(fileobj=io.BytesIO(decoded)) as tar:
            actual = {entry.name: tar.extractfile(entry).read() for entry in tar.getmembers()}
        if actual != files:
            raise ValueError('the archive does not contain exactly the template sources and licenses')
        staging = destination.with_name(destination.name + '.tmp')
        staging.write_bytes(compressed.read_bytes())
        os.replace(staging, destination)
    print('Packaged and verified ' + str(destination))


if __name__ == '__main__':
    main()
