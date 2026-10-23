"""Validate NSO segments, enumerate ELF dynamic imports and ARM64 rewrite candidates.

Requires lz4 and capstone. Linear instruction counts are candidates, not a
control-flow proof or a compatibility verdict. Does not rewrite or execute code.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import lz4.block
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

LIMIT = 256 * 1024 * 1024


def analyze(path):
    path = Path(path)
    if path.stat().st_size > LIMIT:
        raise ValueError('Module exceeds inspection limit')
    raw = path.read_bytes()
    if len(raw) < 256 or raw[:4] != b'NSO0':
        raise ValueError('Expected NSO0 module')
    flags = struct.unpack_from('<I', raw, 12)[0]
    decoded, segments, spans, memory_spans = [], [], [], []
    for index, name in enumerate(['text', 'ro', 'data']):
        file_offset, memory_offset, size = struct.unpack_from('<III', raw, 16 + index * 16)
        compressed = bool(flags & (1 << index))
        stored = struct.unpack_from('<I', raw, 0x60 + index * 4)[0] if compressed else size
        if size > LIMIT or file_offset < 256 or file_offset + stored > len(raw):
            raise ValueError('Segment outside file or too large')
        payload = raw[file_offset:file_offset + stored]
        if compressed:
            payload = lz4.block.decompress(payload, uncompressed_size=size)
        if len(payload) != size:
            raise ValueError('Decoded segment length mismatch')
        digest = hashlib.sha256(payload).digest()
        hash_enabled = bool(flags & (1 << (index + 3)))
        if hash_enabled and digest != raw[0xa0 + index * 32:0xc0 + index * 32]:
            raise ValueError('NSO segment SHA256 mismatch')
        decoded.append(payload)
        spans.append((file_offset, file_offset + stored))
        memory_spans.append((memory_offset, memory_offset + size))
        segments.append({'name': name, 'memory_offset': memory_offset, 'bytes': size,
                         'stored_bytes': stored, 'compressed': compressed,
                         'sha256': digest.hex(), 'declared_hash_check': 'passed' if hash_enabled else 'not_present'})
    for ranges in [spans, memory_spans]:
        ranges.sort()
        if any(b[0] < a[1] for a, b in zip(ranges, ranges[1:])):
            raise ValueError('Overlapping NSO segments')
    ro = decoded[1]
    string_offset, string_size = struct.unpack_from('<II', raw, 0x90)
    symbol_offset, symbol_size = struct.unpack_from('<II', raw, 0x98)
    if string_offset + string_size > len(ro) or symbol_offset + symbol_size > len(ro) or symbol_size % 24:
        raise ValueError('Dynamic symbol/string extents invalid')
    strings = ro[string_offset:string_offset + string_size]
    imports, exports = set(), set()
    for offset in range(symbol_offset, symbol_offset + symbol_size, 24):
        name_offset, info, other, section, value, symbol_bytes = struct.unpack_from('<IBBHQQ', ro, offset)
        if name_offset >= len(strings):
            raise ValueError('ELF symbol name outside dynamic string table')
        end = strings.find(b'\0', name_offset)
        if end < 0:
            raise ValueError('Unterminated ELF symbol name')
        name = strings[name_offset:end].decode('utf-8', errors='replace')
        if name:
            (imports if section == 0 else exports).add(name)
    text = decoded[0]
    if len(text) % 4:
        raise ValueError('ARM64 text size is not instruction-aligned')
    counts, svc = Counter(), Counter()
    registers = {0xd53bd040: 'read_tpidr_el0', 0xd51bd040: 'write_tpidr_el0',
                 0xd53bd060: 'read_tpidrro_el0', 0xd53be020: 'read_cntpct_el0',
                 0xd53be040: 'read_cntvct_el0'}
    for offset in range(0, len(text), 4):
        word = struct.unpack_from('<I', text, offset)[0]
        if word & 0xffe0001f == 0xd4000001:
            counts['svc'] += 1; svc[(word >> 5) & 0xffff] += 1
        if word & 0xffffffe0 in registers:
            counts[registers[word & 0xffffffe0]] += 1
    decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    decoder.skipdata = True
    x18 = re.compile(r'\b[wx]18\b')
    for address, length, mnemonic, operands in decoder.disasm_lite(text, segments[0]['memory_offset']):
        if mnemonic == '.byte':
            counts['undecoded_words'] += 1
        elif x18.search(operands):
            counts['x18_or_w18'] += 1
    names = set()
    for payload in decoded:
        names.update(s.decode('ascii') for s in re.findall(rb'\bnvn[A-Z][A-Za-z0-9_]+\x00', payload))
    names = {s.rstrip('\0') for s in names}
    return {'path': str(path), 'file_sha256': hashlib.sha256(raw).hexdigest(),
            'build_id': raw[0x40:0x60].hex(), 'flags': flags, 'segments': segments,
            'bss_bytes': struct.unpack_from('<I', raw, 0x3c)[0],
            'imports': sorted(imports), 'exports': sorted(exports),
            'rewrite_candidates': dict(counts), 'svc_numbers': {str(k): v for k, v in sorted(svc.items())},
            'nvn_symbol_strings': sorted(names), 'scan_scope': 'linear text candidate scan; no code executed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    modules = []
    try:
        for path in sorted(args.directory.iterdir()):
            if path.is_file():
                with path.open('rb') as file:
                    if file.read(4) != b'NSO0':
                        continue
                print(f'Inspecting {path.name}', flush=True)
                modules.append(analyze(path))
        if not modules:
            raise ValueError('No NSO0 modules found')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'modules': modules}, indent=2) + '\n')
        for module in modules:
            print(module['path'].split('/')[-1], 'imports:',len(module['imports']),
                  'candidates:',module['rewrite_candidates'],'NVN names:',len(module['nvn_symbol_strings']))
    except (OSError, ValueError) as error:
        print(f'Inspection stopped: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
