#!/usr/bin/env python3
"""Read bounded XCI/HFS0 metadata. No keys, extraction or full-file reads by default.

Layout references: SciresM/hactool xci.h and hfs0.h. Structural validation only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys

MAX_TABLE = 8 * 1024 * 1024
MAX_FILES = 65536
MAX_PARTITIONS = 16


class FormatError(ValueError):
    pass


def read_at(file, offset, length, limit):
    if offset < 0 or length < 0 or offset + length > limit:
        raise FormatError(f"Range outside container: offset={offset}, length={length}, limit={limit}")
    file.seek(offset)
    result = file.read(length)
    if len(result) != length:
        raise FormatError("File changed or was truncated during inspection")
    return result


def hfs0(file, offset, size):
    limit = offset + size
    header = read_at(file, offset, 16, limit)
    if header[:4] != b'HFS0':
        raise FormatError(f"HFS0 magic missing at 0x{offset:x}")
    count, strings_size = struct.unpack_from('<II', header, 4)
    table_size = 16 + count * 64 + strings_size
    if count > MAX_FILES or table_size > MAX_TABLE:
        raise FormatError("HFS0 metadata exceeds bounded inspection limits")
    table = read_at(file, offset, table_size, limit)
    names = table[16 + count * 64:]
    entries, ranges, seen = [], [], set()
    for index in range(count):
        entry_start = 16 + index * 64
        relative, length, name_offset, hashed_size = struct.unpack_from('<QQII', table, entry_start)
        if name_offset >= len(names):
            raise FormatError("Invalid HFS0 name offset")
        end = names.find(b'\0', name_offset)
        if end < 0:
            raise FormatError("Unterminated HFS0 name")
        try:
            name = names[name_offset:end].decode('utf-8')
        except UnicodeDecodeError as error:
            raise FormatError("Invalid HFS0 UTF-8 name") from error
        if not name or name in seen:
            raise FormatError("Empty or duplicate HFS0 name")
        seen.add(name)
        absolute = offset + table_size + relative
        if absolute + length > limit or hashed_size > length:
            raise FormatError(f"HFS0 entry {name!r} exceeds partition bounds")
        if length:
            ranges.append((absolute, absolute + length))
        entries.append({'name': name, 'offset': absolute, 'size': length,
                        'hashed_prefix_size': hashed_size,
                        'declared_sha256': table[entry_start + 32:entry_start + 64].hex()})
    ranges.sort()
    if any(right[0] < left[1] for left, right in zip(ranges, ranges[1:])):
        raise FormatError("Overlapping HFS0 entries")
    return {'offset': offset, 'metadata_bytes': table_size, 'files': entries}


def inspect(path):
    with Path(path).open('rb') as file:
        file_stat = os.fstat(file.fileno())
        if not stat.S_ISREG(file_stat.st_mode):
            raise FormatError("Expected a regular local file")
        size = file_stat.st_size
        header = read_at(file, 0, 0x200, size)
        if header[0x100:0x104] != b'HEAD':
            raise FormatError("XCI HEAD magic missing; this may be an archive or a different format")
        root_offset, declared_header_size = struct.unpack_from('<QQ', header, 0x130)
        if root_offset < 0x200 or root_offset >= size:
            raise FormatError("Invalid root partition offset")
        if not 16 <= declared_header_size <= MAX_TABLE or root_offset + declared_header_size > size:
            raise FormatError("Invalid root header hash range")
        root = hfs0(file, root_offset, size - root_offset)
        if len(root['files']) > MAX_PARTITIONS:
            raise FormatError("Too many root partitions for bounded inspection")
        if root['metadata_bytes'] > declared_header_size:
            raise FormatError("Root metadata exceeds declared header size")
        partitions = []
        for entry in root['files']:
            partition = hfs0(file, entry['offset'], entry['size'])
            partition['name'] = entry['name']
            partition['size'] = entry['size']
            partitions.append(partition)
        logical_end = max((x['offset'] + x['size'] for x in root['files']),
                          default=root_offset + root['metadata_bytes'])
        return {
            'schema_version': 1, 'path': str(Path(path).absolute()), 'format': 'XCI/HFS0',
            'file_bytes': size, 'file_gib': round(size / 1024**3, 3),
            'root': root, 'partitions': partitions, 'trailing_bytes': size - logical_end,
            'metadata_bytes_read': 0x200 + root['metadata_bytes'] + sum(x['metadata_bytes'] for x in partitions) + 16 * (1 + len(partitions)),
            'structural_check': 'passed', 'content_integrity': 'not_verified',
            'title_and_version': 'require_content_metadata',
            'note': 'No game code executed; no content hashes, signatures or decryption checked.'
        }


def stream_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as file:
        before = os.fstat(file.fileno())
        read = 0
        while chunk := file.read(4 * 1024 * 1024):
            digest.update(chunk)
            read += len(chunk)
        after = os.fstat(file.fileno())
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or read != before.st_size:
        raise FormatError("File changed during SHA256 calculation")
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xci', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--sha256', action='store_true', help='Read the entire file in 4MiB chunks; optional and potentially slow')
    args = parser.parse_args()
    try:
        if args.output and args.output.resolve() == args.xci.resolve():
            raise FormatError("Report path must differ from the input file")
        report = inspect(args.xci)
        if args.sha256:
            report['sha256'] = stream_sha256(args.xci)
        result = json.dumps(report, indent=2, ensure_ascii=False) + '\n'
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(result, encoding='utf-8')
        print(result, end='')
        return 0
    except (OSError, FormatError) as error:
        print(f'Inspection failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
