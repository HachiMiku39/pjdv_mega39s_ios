#!/usr/bin/env python3
"""Local, bounded-memory resource volumes. Never modifies the input file.

This is a storage format, not an XCI decryptor or a RomFS/BKTR merger.
Use prepared plaintext resources for the eventual game runtime. An opaque XCI
can be transported with this tool but remains encrypted and unplayable by it.
"""
import argparse
import bisect
import hashlib
import json
import os
from pathlib import Path
import re
import stat

FORMAT = 'pjdv-resource-volumes-v1'
BLOCK = 1024 * 1024
MAX_PART = 2 * 1024 ** 3
MAX_TOTAL = (1 << 63) - 1


def plan(size, part_bytes=MAX_PART):
    if type(size) is not int or not 0 <= size <= MAX_TOTAL:
        raise ValueError('Invalid source size')
    if type(part_bytes) is not int or not 1 <= part_bytes <= MAX_PART:
        raise ValueError('Volume size must be 1 byte through 2 GiB')
    if (size + part_bytes - 1) // part_bytes > 4096:
        raise ValueError('Too many volumes; increase the volume size')
    return [{'file': f'resources.{n + 1:05d}.part', 'offset': offset,
             'bytes': min(part_bytes, size - offset)}
            for n, offset in enumerate(range(0, size, part_bytes))]


def encode_manifest(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def pack(source, destination, part_bytes=MAX_PART, content_kind='opaque'):
    source, destination = Path(source), Path(destination)
    if content_kind not in ('romfs', 'opaque'):
        raise ValueError('Unknown content kind')
    with source.open('rb') as src:
        before = os.fstat(src.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('Input must be a regular file')
        parts = plan(before.st_size, part_bytes)
        if len(parts) > 4096:
            raise ValueError('Too many volumes; increase the volume size')
        # Exclusive directory creation protects every pre-existing SSD file.
        destination.mkdir(parents=False, exist_ok=False)
        whole = hashlib.sha256()
        for part in parts:
            digest, left = hashlib.sha256(), part['bytes']
            with (destination / part['file']).open('xb') as dst:
                while left:
                    block = src.read(min(BLOCK, left))
                    if not block:
                        raise ValueError('Source was truncated during packaging')
                    dst.write(block)
                    digest.update(block); whole.update(block); left -= len(block)
                dst.flush(); os.fsync(dst.fileno())
            part['sha256'] = digest.hexdigest()
        after = os.fstat(src.fileno())
        if src.read(1) or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('Source changed during packaging')
        manifest = {'format': FORMAT, 'content_kind': content_kind,
                    'total_bytes': before.st_size, 'sha256': whole.hexdigest(),
                    'parts': parts}
        # No committed manifest on an interrupted or failed packaging run.
        with (destination / 'manifest.json').open('xb') as dst:
            dst.write(encode_manifest(manifest)); dst.flush(); os.fsync(dst.fileno())
        return manifest


class VirtualFile:
    """Random access across volumes; hashes each touched volume before use."""
    def __init__(self, directory):
        self.directory, self.fds, self.verified = Path(directory), [], set()
        manifest_path = self.directory / 'manifest.json'
        if manifest_path.stat().st_size > 4 * BLOCK:
            raise ValueError('Manifest exceeds 4 MiB')
        self.manifest = json.loads(manifest_path.read_bytes())
        m = self.manifest
        if m.get('format') != FORMAT or m.get('content_kind') not in ('romfs', 'opaque'):
            raise ValueError('Unsupported volume format')
        self.size = m.get('total_bytes')
        if type(self.size) is not int or not 0 <= self.size <= MAX_TOTAL:
            raise ValueError('Invalid total size')
        self.parts = m.get('parts')
        if not isinstance(self.parts, list) or len(self.parts) > 4096:
            raise ValueError('Invalid volume count')
        self.offsets = []
        end, names = 0, set()
        try:
            for part in self.parts:
                name, offset, size = part['file'], part['offset'], part['bytes']
                if not isinstance(name, str) or not re.fullmatch(r'resources\.[0-9]{5}\.part', name) or name in names:
                    raise ValueError('Invalid or duplicate volume name')
                if type(offset) is not int or offset != end or type(size) is not int or not 1 <= size <= MAX_PART:
                    raise ValueError('Volumes must be contiguous, ordered and nonempty')
                if not isinstance(part.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', part['sha256']):
                    raise ValueError('Invalid SHA256')
                names.add(name); self.offsets.append(offset); end += size
                fd = os.open(self.directory / name, os.O_RDONLY | os.O_NOFOLLOW)
                self.fds.append(fd)
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_size != size:
                    raise ValueError('Missing, truncated or oversized volume')
            if end != self.size:
                raise ValueError('Volume lengths do not match total size')
            if not isinstance(m.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', m['sha256']):
                raise ValueError('Invalid full-file SHA256')
        except BaseException:
            self.close()
            raise

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.fds.clear()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _verify_part(self, index, whole=None):
        fd, part = self.fds[index], self.parts[index]
        before = os.fstat(fd)
        digest, offset = hashlib.sha256(), 0
        while offset < part['bytes']:
            block = os.pread(fd, min(BLOCK, part['bytes'] - offset), offset)
            if not block:
                raise ValueError('Volume truncated while verifying')
            digest.update(block)
            if whole is not None:
                whole.update(block)
            offset += len(block)
        after = os.fstat(fd)
        if digest.hexdigest() != part['sha256'] or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError(f'Volume integrity failed: {part["file"]}')
        self.verified.add(index)

    def verify(self):
        whole = hashlib.sha256()
        for i in range(len(self.parts)):
            self._verify_part(i, whole)
        if whole.hexdigest() != self.manifest['sha256']:
            raise ValueError('Full-file integrity failed')

    def read_at(self, offset, count):
        if type(offset) is not int or type(count) is not int or offset < 0 or count < 0 or count > 16 * BLOCK or offset > self.size or count > self.size - offset:
            raise ValueError('Read outside resource or above 16 MiB bound')
        result = bytearray()
        while count:
            i = bisect.bisect_right(self.offsets, offset) - 1
            if i not in self.verified:
                self._verify_part(i)
            relative = offset - self.parts[i]['offset']
            take = min(count, self.parts[i]['bytes'] - relative)
            block = os.pread(self.fds[i], take, relative)
            if len(block) != take:
                raise ValueError('Short read from resource volume')
            result.extend(block); offset += take; count -= take
        return bytes(result)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='action', required=True)
    for action in ('plan', 'pack'):
        p = sub.add_parser(action); p.add_argument('source', type=Path)
        p.add_argument('--part-mib', type=int, default=2048)
        if action == 'pack':
            p.add_argument('destination', type=Path)
            p.add_argument('--kind', choices=('romfs', 'opaque'), default='opaque')
    p = sub.add_parser('verify'); p.add_argument('directory', type=Path)
    a = ap.parse_args()
    if a.action == 'plan':
        value = {'format': 'pjdv-volume-plan-v1', 'total_bytes': a.source.stat().st_size,
                 'parts': plan(a.source.stat().st_size, a.part_mib * BLOCK),
                 'input_modified': False, 'volumes_created': False}
        print(encode_manifest(value).decode(), end='')
    elif a.action == 'pack':
        value = pack(a.source, a.destination, a.part_mib * BLOCK, a.kind)
        print(f'Created {len(value["parts"])} volumes, {value["total_bytes"]} bytes')
    else:
        with VirtualFile(a.directory) as f:
            f.verify(); print(f'Verified {len(f.parts)} volumes, {f.size} bytes')


if __name__ == '__main__':
    main()
