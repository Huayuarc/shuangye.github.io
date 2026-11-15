#!/usr/bin/env python3
"""Inventory strong/weak system imports in an Apelin research tree; never executes it."""
import argparse
import collections
import hashlib
import functools
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def imports(data):
    def number(offset, kind='I'):
        return struct.unpack_from('<' + kind, data, offset)[0]
    commands, length = number(16), number(20)
    assert length <= len(data) - 32 and commands <= length // 8
    libraries = []
    symbols = None
    cursor = 32
    for _ in range(commands):
        kind, size = number(cursor), number(cursor + 4)
        assert size >= 8 and size <= 32 + length - cursor
        if kind in (0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023):
            start = cursor + number(cursor + 8)
            end = data.index(0, start, cursor + size)
            libraries.append((data[start:end].decode(), kind == 0x80000018))
        elif kind == 2:
            symbols = struct.unpack_from('<IIII', data, cursor + 8)
        cursor += size
    assert cursor == 32 + length
    result = []
    if not symbols:
        return result
    table, count, strings, strings_size = symbols
    assert table + count * 16 <= len(data) and strings + strings_size <= len(data)
    for index in range(count):
        name, kind, _, description, _ = struct.unpack_from('<IBBHQ', data, table + index * 16)
        if kind & 0xe0 or kind & 0x0e or not kind & 1 or not name:
            continue
        ordinal = description >> 8
        if not 1 <= ordinal <= len(libraries):
            continue
        library, weak_library = libraries[ordinal - 1]
        if not library.startswith(('/usr/lib/', '/System/Library/')):
            continue
        assert name < strings_size
        start = strings + name
        end = data.index(0, start, strings + strings_size)
        result.append((library, data[start:end].decode(), weak_library or bool(description & 0x40)))
    return result


_decoder_directories = []


@functools.lru_cache(maxsize=1)
def decoder_tool():
    """Use LLVM's C decoder without formatting millions of disassembly lines."""
    directory = tempfile.TemporaryDirectory(prefix='apelin-instruction-decoder-')
    _decoder_directories.append(directory)
    executable = Path(directory.name) / 'inventory'
    compiler = Path(subprocess.run(['xcrun', '--find', 'clang'], check=True,
                                   capture_output=True, text=True).stdout.strip())
    library = compiler.parent.parent / 'lib/libLTO.dylib'
    source = Path(__file__).with_name('ToolchainInstructionInventory.c')
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', str(source),
                    '-o', str(executable)], check=True, capture_output=True)
    return executable, library


def instructions(path, cpus=()):
    """Inventory instructions and compare full decodes; this is not reachability analysis.

    An instruction found in a library can belong to a guarded dispatch path.
    Its presence alone does not prove that ordinary compilation reaches it.
    Conversely, an empty difference is meaningful only when the reference
    decoder understood every instruction.
    """
    features = {
        'SHA3': {'eor3', 'bcax', 'rax1', 'xar'},
        'DotProd': {'udot', 'sdot'},
        'SHA512': {'sha512h', 'sha512h2', 'sha512su0', 'sha512su1'},
        'LRCPC': {'ldapr', 'ldaprb', 'ldaprh'},
        'LRCPC2': {'ldapur', 'ldapurb', 'ldapurh', 'ldapursb', 'ldapursh', 'ldapursw', 'stlur', 'stlurb', 'stlurh'},
        'FlagM': {'cfinv', 'rmif', 'setf8', 'setf16'},
        'FHM': {'fmlal', 'fmlal2', 'fmlsl', 'fmlsl2'},
        'FRINTTS': {'frint32x', 'frint32z', 'frint64x', 'frint64z'},
        'BF16': {'bfcvt', 'bfcvtn', 'bfcvtn2', 'bfdot', 'bfmmla'},
        'I8MM': {'smmla', 'ummla', 'usmmla', 'usdot', 'sudot'},
    }
    selected = {name: feature for feature, names in features.items() for name in names}
    counts = collections.Counter()
    examples = []
    executable, library = decoder_tool()
    completed = subprocess.run([str(executable), str(library), str(path), *cpus],
                               check=True, capture_output=True, text=True, timeout=300)
    if completed.stderr.strip():
        raise ValueError('LLVM could not validate the requested CPU: ' + completed.stderr.strip())
    result = json.loads(completed.stdout)
    for mnemonic, count in result.pop('mnemonics').items():
        if mnemonic in selected:
            feature = selected[mnemonic]
            counts[feature + ':' + mnemonic] += count
            if feature != 'LRCPC' and len(examples) < 12:
                examples.append(dict(address=result['firstAddresses'][mnemonic], instruction=mnemonic))
    result.pop('firstAddresses')
    result.update(counts=dict(counts), examples=examples, decoder='LLVM C API')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tree', type=Path)
    parser.add_argument('--instructions', action='store_true', help='also disassemble host images with Apple LLVM')
    parser.add_argument('--cpu', action='append', default=[],
                        help='compare the complete decode for this LLVM CPU (repeatable; implies --instructions)')
    args = parser.parse_args()
    root = args.tree.resolve(strict=True)
    manifest = json.loads((root / 'manifest.json').read_text())
    libraries = collections.defaultdict(lambda: {'strong': set(), 'weak': set()})
    images = []
    decoded = {}
    for relative in sorted(manifest['files']):
        if relative.startswith('usr/lib/clang/'):
            continue
        path = (root / relative).resolve(strict=True)
        assert path.is_relative_to(root)
        with path.open('rb') as source:
            magic = source.read(4)
        if magic != b'\xcf\xfa\xed\xfe':
            continue
        data = path.read_bytes()
        records = imports(data)
        digest = hashlib.sha256(data).hexdigest()
        if digest != manifest['files'][relative]:
            raise ValueError('Image no longer matches its manifest: ' + relative)
        image = {'path': relative, 'sha256': digest, 'systemImports': len(records)}
        if args.instructions or args.cpu:
            print('Inspecting ' + relative, file=sys.stderr, flush=True)
            if digest not in decoded:
                decoded[digest] = instructions(path, args.cpu)
            image['instructions'] = decoded[digest]
        images.append(image)
        for library, symbol, weak in records:
            libraries[library]['weak' if weak else 'strong'].add(symbol)
    dyld_managed = []
    for library, values in libraries.items():
        # This assembler entry is resolved by dyld, and is not discoverable
        # through dlsym on either the macOS control or the iOS host.
        if 'dyld_stub_binder' in values['strong']:
            values['strong'].remove('dyld_stub_binder')
            dyld_managed.append(dict(image=library, symbol='dyld_stub_binder'))
    result = {
        'version': manifest['source']['version'],
        'inventoryOnly': manifest.get('inventoryOnly', False),
        'sourceSHA256': manifest['sourceSHA256'],
        'images': images,
        'dyldManagedSymbols': dyld_managed,
        'libraries': [dict(path=path, strong=sorted(values['strong']), weak=sorted(values['weak']))
                      for path, values in sorted(libraries.items())],
    }
    if args.instructions or args.cpu:
        result['instructionAuditComplete'] = all(
            image['instructions']['referenceUnknown'] == 0
            and all(cpu['missingAddresses'] == 0 for cpu in image['instructions']['cpus'].values())
            for image in images
        )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
