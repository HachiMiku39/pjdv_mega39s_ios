"""Bounded local NCA3/PFS0 reader for metadata and ExeFS only.

Formats and Nintendo XTS/CTR conventions follow SciresM/hactool nca.h,
aes.c, nca.c and pfs0.h. Does not merge BKTR RomFS or execute guest code.
Requires cryptography. Secret key values never enter reports.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from inspect_xci import inspect, FormatError, MAX_TABLE


def load_keys(path):
    keys = {}
    for line in Path(path).read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if '=' not in line:
            continue
        name, value = map(str.strip, line.split('=', 1))
        try:
            keys[name] = bytes.fromhex(value)
        except ValueError:
            continue
    if len(keys.get('header_key', b'')) != 32:
        raise FormatError('Missing usable header_key')
    return keys


def decrypt(key, mode, raw):
    cipher = Cipher(algorithms.AES(key), mode).decryptor()
    return cipher.update(raw) + cipher.finalize()


class Archive:
    def __init__(self, file, entry, keys):
        self.file, self.entry = file, entry
        raw = self.raw(0, 0xc00)
        self.header = b''.join(decrypt(keys['header_key'], modes.XTS(sector.to_bytes(16, 'big')),
                              raw[sector * 512:(sector + 1) * 512]) for sector in range(6))
        header = self.header
        if header[0x200:0x204] != b'NCA3':
            raise FormatError('Not a supported decrypted NCA3 header')
        self.content_type = header[0x205]
        self.title_id = f'{struct.unpack_from("<Q", header, 0x210)[0]:016X}'
        self.key_generation = max(header[0x206], header[0x220])
        declared_size = struct.unpack_from('<Q', header, 0x208)[0]
        if declared_size != entry['size']:
            raise FormatError('NCA declared size differs from container entry')
        self.rights_managed = any(header[0x230:0x240])
        self.section_key = None
        if not self.rights_managed:
            key_index = header[0x207]
            if key_index > 2:
                raise FormatError('Unsupported key-area index')
            category = ['application', 'ocean', 'system'][key_index]
            name = f'key_area_key_{category}_{max(0, self.key_generation - 1):02x}'
            if name in keys:
                self.section_key = decrypt(keys[name], modes.ECB(), header[0x300:0x340])[32:48]
        self.sections = []
        for index in range(4):
            start, end = struct.unpack_from('<II', header, 0x240 + index * 16)
            if not start and not end:
                continue
            if start < 6 or end <= start or end * 512 > declared_size:
                raise FormatError('NCA section outside archive')
            fs = header[0x400 + index * 512:0x600 + index * 512]
            expected = header[0x280 + index * 32:0x2a0 + index * 32]
            if hashlib.sha256(fs).digest() != expected:
                raise FormatError('NCA filesystem-header SHA256 mismatch')
            self.sections.append({'index': index, 'start': start * 512, 'size': (end - start) * 512,
                                  'partition_type': fs[2], 'fs_type': fs[3], 'crypto_type': fs[4], 'fs': fs})

    def raw(self, offset, length):
        if offset < 0 or length < 0 or offset + length > self.entry['size']:
            raise FormatError('Read outside NCA')
        self.file.seek(self.entry['offset'] + offset)
        raw = self.file.read(length)
        if len(raw) != length:
            raise FormatError('Truncated NCA read')
        return raw

    def read(self, section, relative, length):
        if section['crypto_type'] == 4:
            raise FormatError('BKTR requires a virtual section reader')
        return self.read_ctr_data(section, relative, length)

    def read_ctr_data(self, section, relative, length, ctr_value=None):
        """Physical section bytes; BKTR caller supplies each subsection counter."""
        if relative < 0 or relative + length > section['size']:
            raise FormatError('Read outside NCA section')
        offset = section['start'] + relative
        if section['crypto_type'] == 1:
            return self.raw(offset, length)
        if section['crypto_type'] not in (3, 4):
            raise FormatError('Only ordinary AES-CTR/plaintext sections are supported')
        if self.section_key is None:
            raise FormatError('Section key unavailable; a rights-managed archive may need a title key')
        aligned = offset & ~15
        skip = offset - aligned
        nonce = section['fs'][0x140:0x148][::-1] + (aligned // 16).to_bytes(8, 'big')
        if ctr_value is not None:
            nonce = nonce[:4] + ctr_value.to_bytes(4, 'big') + nonce[8:]
        return decrypt(self.section_key, modes.CTR(nonce), self.raw(aligned, skip + length))[skip:]

    def pfs0(self, section):
        fs = section['fs']
        base, size = struct.unpack_from('<QQ', fs, 0x40)
        if size < 16 or base + size > section['size']:
            raise FormatError('PFS0 outside section')
        header = self.read(section, base, 16)
        if header[:4] != b'PFS0':
            raise FormatError('PFS0 decryption/magic check failed')
        count, strings_size = struct.unpack_from('<II', header, 4)
        table_size = 16 + count * 24 + strings_size
        if count > 65536 or table_size > MAX_TABLE or table_size > size:
            raise FormatError('Oversized PFS0 table')
        table = self.read(section, base, table_size)
        strings = table[16 + count * 24:]
        entries, seen = [], set()
        for index in range(count):
            offset, length, name_offset = struct.unpack_from('<QQI', table, 16 + index * 24)
            if name_offset >= len(strings) or strings.find(b'\0', name_offset) < 0:
                raise FormatError('Bad PFS0 filename')
            name = strings[name_offset:strings.find(b'\0', name_offset)].decode('utf-8')
            if not name or Path(name).name != name or name in ['.', '..'] or name in seen:
                raise FormatError('Unsafe or duplicate PFS0 filename')
            seen.add(name)
            if table_size + offset + length > size:
                raise FormatError('PFS0 file outside data')
            entries.append({'name': name, 'relative': base + table_size + offset, 'size': length})
        ranges = sorted((x['relative'], x['relative'] + x['size']) for x in entries if x['size'])
        if any(b[0] < a[1] for a, b in zip(ranges, ranges[1:])):
            raise FormatError('Overlapping PFS0 files')
        return entries, base, size

    def verify_pfs0(self, section, base, size):
        fs = section['fs']
        block_size, levels = struct.unpack_from('<II', fs, 0x28)
        table_offset, table_size = struct.unpack_from('<QQ', fs, 0x30)
        if levels != 2 or not 16 <= block_size <= 4 * 1024 * 1024 or table_size > MAX_TABLE:
            raise FormatError('Unsupported PFS0 integrity hierarchy')
        table = self.read(section, table_offset, table_size)
        if hashlib.sha256(table).digest() != fs[8:40]:
            raise FormatError('PFS0 hash-table master hash mismatch')
        count = (size + block_size - 1) // block_size
        if count * 32 > len(table):
            raise FormatError('PFS0 hash table too short')
        for index in range(count):
            raw = self.read(section, base + index * block_size, min(block_size, size - index * block_size))
            if hashlib.sha256(raw).digest() != table[index * 32:(index + 1) * 32]:
                raise FormatError('PFS0 data-block SHA256 mismatch')


def cnmt(raw):
    if len(raw) < 32:
        raise FormatError('CNMT header truncated')
    title, version = struct.unpack_from('<QI', raw)
    extended, count = struct.unpack_from('<HH', raw, 0xe)
    start = 32 + extended
    if start + count * 56 > len(raw):
        raise FormatError('CNMT entries truncated')
    contents = []
    for index in range(count):
        entry = raw[start + index * 56:start + (index + 1) * 56]
        contents.append({'nca_content_id': entry[32:48].hex(), 'content_type': entry[54],
                         'size': int.from_bytes(entry[48:54], 'little')})
    return {'title_id': f'{title:016X}', 'version': version, 'meta_type': raw[12], 'contents': contents}


def analyze(xci, keys_path, output_root):
    container = inspect(xci)
    keys = load_keys(keys_path)
    secure = next((p for p in container['partitions'] if p['name'] == 'secure'), None)
    if secure is None:
        raise FormatError('No secure partition')
    output_root.mkdir(parents=True, exist_ok=True)
    archives, metadata, extracted = [], [], []
    with Path(xci).open('rb') as file:
        for entry in secure['files']:
            if not entry['name'].endswith('.nca'):
                continue
            archive = Archive(file, entry, keys)
            row = {'name': entry['name'], 'title_id': archive.title_id,
                   'content_type': archive.content_type, 'key_generation': archive.key_generation,
                   'rights_managed': archive.rights_managed, 'section_headers_sha256': 'passed'}
            archives.append(row)
            if archive.content_type not in [0, 1]:
                continue
            for section in archive.sections:
                if section['partition_type'] != 1:
                    continue
                entries, base, size = archive.pfs0(section)
                archive.verify_pfs0(section, base, size)
                row['pfs0_integrity'] = 'all_data_blocks_passed'
                row['pfs0_files'] = [{'name': e['name'], 'size': e['size']} for e in entries]
                if archive.content_type == 1:
                    for item in entries:
                        if item['name'].endswith('.cnmt'):
                            if item['size'] > MAX_TABLE:
                                raise FormatError('Oversized CNMT')
                            data = cnmt(archive.read(section, item['relative'], item['size']))
                            data['source_nca'] = entry['name']
                            metadata.append(data)
                    continue
                if 'main' not in [e['name'] for e in entries]:
                    continue
                destination = output_root / 'ExeFS' / entry['name'].removesuffix('.nca')
                destination.mkdir(parents=True, exist_ok=True)
                for item in entries:
                    if item['size'] > 512 * 1024 * 1024:
                        raise FormatError('ExeFS file exceeds extraction limit')
                    path = destination / item['name']
                    digest = hashlib.sha256()
                    with path.open('xb') as target:
                        for offset in range(0, item['size'], 4 * 1024 * 1024):
                            raw = archive.read(section, item['relative'] + offset, min(4 * 1024 * 1024, item['size'] - offset))
                            target.write(raw); digest.update(raw)
                    extracted.append({'source_nca': entry['name'], 'name': item['name'],
                                      'path': str(path), 'size': item['size'], 'sha256': digest.hexdigest()})
                print(f'Extracted program ExeFS: {entry["name"]}', flush=True)
    report = {'schema_version': 1, 'nca_count': len(archives), 'ncas': archives,
              'content_metadata': metadata, 'extracted': extracted,
              'scope': 'NCA3 headers, metadata PFS0 and program ExeFS; no RomFS merge or guest execution',
              'rsa_signature_validation': 'not_performed'}
    (output_root / 'analysis.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xci', type=Path)
    parser.add_argument('keys', type=Path)
    parser.add_argument('output_root', type=Path)
    args = parser.parse_args()
    try:
        report = analyze(args.xci, args.keys, args.output_root)
        print(json.dumps({'nca_count': report['nca_count'], 'content_meta_count': len(report['content_metadata']),
                          'extracted_files': len(report['extracted'])}, indent=2))
    except (OSError, ValueError, StopIteration) as error:
        print(f'Analysis stopped: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
