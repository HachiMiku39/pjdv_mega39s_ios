import json
import pathlib
import random
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Tools'))
from resource_volumes import VirtualFile, pack, plan


class VolumesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.source = self.root / 'source.bin'
        self.data = random.Random(39).randbytes(1027)
        self.source.write_bytes(self.data)
        self.output = self.root / 'volumes'
        pack(self.source, self.output, 128)

    def tearDown(self):
        self.tmp.cleanup()

    def mutate_manifest(self, fn):
        path = self.output / 'manifest.json'
        m = json.loads(path.read_text()); fn(m); path.write_text(json.dumps(m))

    def test_real_xci_plan_without_allocation(self):
        parts = plan(42716664832)
        self.assertEqual(len(parts), 20)
        self.assertEqual(parts[-1]['bytes'], 1914475520)
        self.assertEqual(sum(p['bytes'] for p in parts), 42716664832)

    def test_cross_volume_random_reads_and_integrity(self):
        with VirtualFile(self.output) as f:
            f.verify()
            self.assertEqual(f.read_at(0, len(self.data)), self.data)
            rng = random.Random(1)
            for _ in range(200):
                start = rng.randrange(len(self.data)); count = rng.randrange(len(self.data) - start + 1)
                self.assertEqual(f.read_at(start, count), self.data[start:start + count])
            self.assertEqual(f.read_at(f.size, 0), b'')
            for start, count in ((-1, 1), (0, -1), (f.size, 1), (0, 17 * 1024 ** 2)):
                with self.assertRaises(ValueError): f.read_at(start, count)
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_corruption_rejected_before_read(self):
        p = self.output / 'resources.00001.part'; p.write_bytes(b'x' * 128)
        with VirtualFile(self.output) as f:
            with self.assertRaisesRegex(ValueError, 'integrity'): f.read_at(0, 1)

    def test_truncation_and_symlink_rejected(self):
        p = self.output / 'resources.00001.part'; p.write_bytes(b'x')
        with self.assertRaises(ValueError): VirtualFile(self.output)
        p.unlink(); p.symlink_to(self.source)
        with self.assertRaises(OSError): VirtualFile(self.output)

    def test_manifest_gaps_and_traversal_rejected(self):
        self.mutate_manifest(lambda m: m['parts'][1].update(offset=127))
        with self.assertRaises(ValueError): VirtualFile(self.output)
        self.mutate_manifest(lambda m: m['parts'][0].update(file='../source.bin'))
        with self.assertRaises(ValueError): VirtualFile(self.output)

    def test_existing_files_never_overwritten(self):
        sentinel = self.output / 'keep.txt'; sentinel.write_text('keep')
        with self.assertRaises(FileExistsError): pack(self.source, self.output, 128)
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_empty_and_boundary_sizes(self):
        self.assertEqual(plan(0), [])
        self.assertEqual([p['bytes'] for p in plan(256, 128)], [128, 128])
        self.assertEqual([p['bytes'] for p in plan(257, 128)], [128, 128, 1])
        with self.assertRaises(ValueError): plan((1 << 63) - 1, 1)


if __name__ == '__main__': unittest.main()
