import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('inspect_xci', Path(__file__).parents[1] / 'Tools/inspect_xci.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def table(entries):
    names = bytearray()
    records = bytearray()
    for name, offset, size in entries:
        records.extend(struct.pack('<QQIIQ', offset, size, len(names), 0, 0) + bytes(32))
        names.extend(name.encode() + b'\0')
    return b'HFS0' + struct.pack('<III', len(entries), len(names), 0) + records + names


class ContainerTests(unittest.TestCase):
    def fixture(self, directory, sparse_size=None):
        child = table([('content.nca', 0, 3)]) + b'abc'
        root = table([('secure', 0, len(child))])
        header = bytearray(0x200)
        header[0x100:0x104] = b'HEAD'
        struct.pack_into('<QQ', header, 0x130, 0x200, len(root))
        path = Path(directory) / 'fixture.xci'
        with path.open('wb') as file:
            file.write(header + root + child)
            if sparse_size:
                file.truncate(sparse_size)
        return path

    def test_nested_partitions(self):
        with tempfile.TemporaryDirectory() as directory:
            report = module.inspect(self.fixture(directory))
        self.assertEqual(report['partitions'][0]['files'][0]['name'], 'content.nca')
        self.assertEqual(report['structural_check'], 'passed')
        self.assertEqual(report['content_integrity'], 'not_verified')

    def test_40gib_metadata_reads_are_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            report = module.inspect(self.fixture(directory, 40 * 1024**3))
        self.assertEqual(report['file_bytes'], 40 * 1024**3)
        self.assertLess(report['metadata_bytes_read'], 1024)

    def test_truncated_file_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.fixture(directory)
            with path.open('r+b') as file:
                file.truncate(path.stat().st_size - 1)
            with self.assertRaises(module.FormatError):
                module.inspect(path)

    def test_bad_magic_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.fixture(directory)
            with path.open('r+b') as file:
                file.seek(0x100)
                file.write(b'NOPE')
            with self.assertRaises(module.FormatError):
                module.inspect(path)

    def test_bad_name_offset_rejected(self):
        raw = bytearray(table([('file', 0, 1)]) + b'x')
        struct.pack_into('<I', raw, 16 + 16, 999)
        with self.assertRaises(module.FormatError):
            module.hfs0(io.BytesIO(raw), 0, len(raw))

    def test_large_metadata_rejected_before_allocation(self):
        raw = b'HFS0' + struct.pack('<III', 0xffffffff, 0xffffffff, 0)
        with self.assertRaises(module.FormatError):
            module.hfs0(io.BytesIO(raw), 0, len(raw))

    def test_overlapping_entries_rejected(self):
        raw = table([('a', 0, 5), ('b', 4, 2)]) + b'abcdef'
        with self.assertRaises(module.FormatError):
            module.hfs0(io.BytesIO(raw), 0, len(raw))

    def test_streaming_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'small'
            path.write_bytes(b'abc')
            self.assertEqual(module.stream_sha256(path), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')


if __name__ == '__main__':
    unittest.main()
