"""The static auditor must detect unavailable instructions without running them."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('inventory', ROOT / 'Scripts/inspect-toolchain-imports.py')
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class InstructionInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='apelin-instruction-audit-')
        root = Path(cls.workspace.name)
        assembly = root / 'features.s'
        assembly.write_text('.text\n.globl _fixture\n_fixture:\n.rept 16\n'
                            ' ldaprb w0, [x1]\n'
                            ' eor3 v0.16b, v1.16b, v2.16b, v3.16b\n'
                            ' udot v0.4s, v1.16b, v2.16b\n ret\n.endr\n')
        cls.object = root / 'features.o'
        subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macos13.0', '-mcpu=apple-m1',
                        '-c', str(assembly), '-o', str(cls.object)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def test_cpu_decoders_distinguish_each_generation(self):
        report = inventory.instructions(self.object, ['apple-a9', 'apple-a10', 'apple-a11', 'apple-a12', 'apple-a13'])
        self.assertEqual(report['referenceUnknown'], 0)
        self.assertEqual(report['referenceInstructions'], 64)
        self.assertEqual(report['counts'], {'LRCPC:ldaprb': 16, 'SHA3:eor3': 16, 'DotProd:udot': 16})
        for cpu in ['apple-a9', 'apple-a10', 'apple-a11']:
            self.assertEqual(set(report['cpus'][cpu]['unsupportedInstructions']), {'ldaprb', 'eor3', 'udot'})
        self.assertEqual(set(report['cpus']['apple-a12']['unsupportedInstructions']), {'eor3', 'udot'})
        self.assertEqual(report['cpus']['apple-a13']['unsupportedInstructions'], {})
        self.assertTrue(all(item['missingAddresses'] == 0 for item in report['cpus'].values()))

    def test_truncated_image_is_rejected(self):
        invalid = Path(self.workspace.name) / 'truncated'
        invalid.write_bytes(b'\xcf\xfa\xed\xfe')
        with self.assertRaises(subprocess.CalledProcessError):
            inventory.instructions(invalid, ['apple-a12'])

    def test_changed_input_is_not_reported_as_the_reviewed_image(self):
        root = Path(self.workspace.name) / 'tree'
        root.mkdir()
        (root / 'tool').write_bytes(self.object.read_bytes())
        (root / 'manifest.json').write_text(json.dumps({
            'source': {'version': 'fixture'}, 'sourceSHA256': '1' * 64,
            'files': {'tool': '0' * 64}
        }))
        result = subprocess.run(['python3', str(ROOT / 'Scripts/inspect-toolchain-imports.py'), str(root)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no longer matches its manifest', result.stderr)


if __name__ == '__main__':
    unittest.main()
