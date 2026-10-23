"""Small synthetic containers; no commercial resources or production keys.

Exercise full NCA-header, CNMT, PFS0, IVFC and streaming import paths using
deterministic dummy payloads. These are format tests, not gameplay evidence.
"""
from pathlib import Path
import ctypes
import hashlib
import json
import struct
import sys

APP = 0x0100F3100DA46000
HEADER_KEY = bytes(range(32))
COMMON = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib')
COMMON.CCCrypt.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p,
                         ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                         ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
COMMON.CCCrypt.restype = ctypes.c_int


def aes(data, key):
    out = ctypes.create_string_buffer(len(data) + 16)
    used = ctypes.c_size_t()
    assert COMMON.CCCrypt(0, 0, 2, key, len(key), None, data, len(data), out, len(out), ctypes.byref(used)) == 0
    assert used.value == len(data)
    return out.raw[:used.value]


def xts(data):
    out = bytearray()
    for sector in range(6):
        tweak = bytearray(aes(sector.to_bytes(16, 'big'), HEADER_KEY[16:]))
        for at in range(sector * 512, (sector + 1) * 512, 16):
            block = aes(bytes(x ^ y for x, y in zip(data[at:at + 16], tweak)), HEADER_KEY[:16])
            out.extend(x ^ y for x, y in zip(block, tweak))
            carry = 0
            for i in range(16):
                next_carry = tweak[i] >> 7
                tweak[i] = ((tweak[i] << 1) & 255) | carry
                carry = next_carry
            if carry:
                tweak[0] ^= 0x87
    return bytes(out)


def align(n, unit=512):
    return (n + unit - 1) // unit * unit


def sha(data):
    return hashlib.sha256(data).digest()


def romfs(files):
    nodes = {'': {'parent': '', 'dirs': [], 'files': []}}
    for path in sorted(files):
        parent = ''
        parts = path.split('/')
        for part in parts[:-1]:
            child = (parent + '/' + part).lstrip('/')
            if child not in nodes:
                nodes[child] = {'parent': parent, 'dirs': [], 'files': []}
                nodes[parent]['dirs'].append(child)
            parent = child
        nodes[parent]['files'].append(path)
    doff, foff, dsize, fsize = {}, {}, 0, 0
    for path in nodes:
        doff[path] = dsize
        dsize += align(24 + len(path.rsplit('/', 1)[-1].encode()), 4)
    for path in sorted(files):
        foff[path] = fsize
        fsize += align(32 + len(path.rsplit('/', 1)[-1].encode()), 4)
    dirs, rows, payload = bytearray(dsize), bytearray(fsize), bytearray()
    absent = 0xffffffff
    for path, node in nodes.items():
        label = path.rsplit('/', 1)[-1].encode()
        siblings = nodes[node['parent']]['dirs'] if path else []
        i = siblings.index(path) if path else 0
        nxt = doff[siblings[i + 1]] if path and i + 1 < len(siblings) else absent
        struct.pack_into('<6I', dirs, doff[path], doff[node['parent']], nxt,
                         doff[node['dirs'][0]] if node['dirs'] else absent,
                         foff[node['files'][0]] if node['files'] else absent, absent, len(label))
        dirs[doff[path] + 24:doff[path] + 24 + len(label)] = label
        for i, file in enumerate(node['files']):
            label = file.rsplit('/', 1)[-1].encode()
            nxt = foff[node['files'][i + 1]] if i + 1 < len(node['files']) else absent
            struct.pack_into('<IIQQII', rows, foff[file], doff[path], nxt, len(payload), len(files[file]), absent, len(label))
            rows[foff[file] + 32:foff[file] + 32 + len(label)] = label
            payload.extend(files[file])
    dt, ft = 84, 88 + len(dirs)
    data_start = align(ft + len(rows), 16)
    header = struct.pack('<10Q', 80, 80, 4, dt, len(dirs), dt + len(dirs), 4, ft, len(rows), data_start)
    prefix = header + bytes(4) + dirs + bytes(4) + rows
    return prefix + bytes(data_start - len(prefix)) + payload


def rom_section(files):
    levels = [b''] * 6
    levels[5] = romfs(files)
    for i in range(4, -1, -1):
        levels[i] = b''.join(sha(levels[i + 1][p:p + 512].ljust(512, b'\0')) for p in range(0, len(levels[i + 1]), 512))
    section, fs = bytearray(), bytearray(512)
    fs[2:5] = bytes([0, 3, 1])
    fs[8:12] = b'IVFC'
    struct.pack_into('<I', fs, 20, 7)
    for i, level in enumerate(levels):
        struct.pack_into('<QQI', fs, 24 + i * 24, len(section), len(level), 9)
        section.extend(level.ljust(align(len(level)), b'\0'))
    fs[0xc8:0xe8] = sha(levels[0].ljust(512, b'\0'))
    return bytes(section), fs


def pfs(files):
    names, rows, payload = bytearray(), bytearray(), bytearray()
    for label, data in files.items():
        rows.extend(struct.pack('<QQII', len(payload), len(data), len(names), 0))
        names.extend(label.encode() + b'\0')
        payload.extend(data)
    return b'PFS0' + struct.pack('<III', len(files), len(names), 0) + rows + names + payload


def meta_section(data):
    payload = pfs({'Application.cnmt': data})
    hashes = b''.join(sha(payload[p:p + 512]) for p in range(0, len(payload), 512))
    fs = bytearray(512)
    fs[2:5] = bytes([1, 2, 1])
    fs[8:40] = sha(hashes)
    struct.pack_into('<IIQQQQ', fs, 0x28, 512, 2, 0, len(hashes), align(len(hashes)), len(payload))
    section = hashes.ljust(align(len(hashes)), b'\0') + payload
    return section.ljust(align(len(section)), b'\0'), fs


def nca(title, kind, section, fs):
    header = bytearray(0xc00)
    header[0x200:0x204] = b'NCA3'
    header[0x205] = kind
    struct.pack_into('<QQ', header, 0x208, len(header) + len(section), title)
    struct.pack_into('<II', header, 0x240, 6, 6 + len(section) // 512)
    header[0x280:0x2a0] = sha(fs)
    header[0x400:0x600] = fs
    return xts(header) + section


def meta(title, kind, version, archive):
    extended = 16 if kind in (0x80, 0x82) else 24
    head = bytearray(32 + extended)
    struct.pack_into('<QIBBHHH', head, 0, title, version, kind, 0, extended, 1, 0)
    struct.pack_into('<Q', head, 32, APP + 0x800 if kind == 0x80 else APP)
    content_id = sha(archive)[:16]
    row = sha(archive) + content_id + len(archive).to_bytes(6, 'little') + bytes([2 if kind == 0x82 else 1, 0])
    return nca(title, 1, *meta_section(head + row + bytes(32)))


def bundle(entries):
    names, records, payload = bytearray(), bytearray(), bytearray()
    for label, data in entries.items():
        records.extend(struct.pack('<QQIIQ', len(payload), len(data), len(names), 0, 0) + bytes(32))
        names.extend(label.encode() + b'\0')
        payload.extend(data)
    return b'HFS0' + struct.pack('<III', len(entries), len(names), 0) + records + names + payload


def xci(entries):
    secure = bundle(entries)
    root = bundle({'secure': secure})
    header = bytearray(512)
    header[0x100:0x104] = b'HEAD'
    root_header = len(root) - len(secure)
    struct.pack_into('<QQ', header, 0x130, 512, root_header)
    return header + root


def game_files(chinese=False):
    files = {'rom_switch/rom/pv_db.txt': b'fixture-pv-db\n', 'rom_switch/rom/gm_module_tbl.farc': b'fixture-modules',
             'rom_switch/rom/lang2/jp/str_array.bin': b'fixture-japanese',
             'rom_switch/rom/lang2/en/str_array.bin': b'fixture-english-strings-only'}
    menu = ['spr_nswgam_menu.farc', 'spr_nswgam_option.farc', 'spr_nswgam_game.farc',
            'aet_nswgam_menu.bin', 'aet_nswgam_option.bin', 'aet_nswgam_game.bin']
    for name in menu:
        files['rom_switch/rom/2d/' + name] = b'fixture-menu'
    if chinese:
        files['rom_switch/rom/lang2/cn/str_array.bin'] = b'fixture-chinese'
        for name in menu:
            files['rom_switch_cn/rom/2d/' + name] = b'fixture-chinese-menu'
    return files


def add(entries, data):
    entries[sha(data)[:16].hex() + '.nca'] = data


def main():
    out = Path(sys.argv[1]);out.mkdir(parents=True, exist_ok=False)
    (out / 'fixture.keys').write_text('header_key = ' + HEADER_KEY.hex() + '\n')
    base = nca(APP, 0, *rom_section(game_files()))
    base_entries = {};add(base_entries, base);add(base_entries, meta(APP, 0x80, 0, base))
    (out / 'base-only.xci').write_bytes(xci(base_entries))
    renamed = dict(base_entries)
    renamed['repacked-base.nca'] = renamed.pop(sha(base)[:16].hex() + '.nca')
    (out / 'renamed.xci').write_bytes(xci(renamed))
    (out / 'metadata-free.xci').write_bytes(xci({'arbitrary-name.nca': base}))
    mixed = dict(base_entries)
    add(mixed, meta(APP + 0x800, 0x81, 0, base))
    patch = nca(APP, 0, *rom_section(game_files(True)))
    add(mixed, patch);add(mixed, meta(APP + 0x800, 0x81, 65536, patch))
    for index in [2, 23, 99]:
        title = APP + 0x1000 + index
        dlc = nca(title, 4, *rom_section({'rom/fixture.txt': f'dlc-{index}'.encode()}))
        add(mixed, dlc);add(mixed, meta(title, 0x82, 1, dlc))
    (out / 'update-subset.xci').write_bytes(xci(mixed))
    missing = dict(mixed);missing.pop(sha(patch)[:16].hex() + '.nca')
    (out / 'missing-update.xci').write_bytes(xci(missing))
    wrong = nca(APP + 0x1000000, 0, *rom_section(game_files()))
    (out / 'wrong-game.xci').write_bytes(xci({'wrong.nca': wrong}))
    (out / 'ambiguous.xci').write_bytes(xci({'one.nca': base, 'two.nca': patch}))
    corrupt = dict(base_entries)
    for name, value in list(corrupt.items()):
        if value != base:
            bad = bytearray(value);bad[-512] ^= 1;corrupt[name] = bytes(bad)
    (out / 'corrupt-meta.xci').write_bytes(xci(corrupt))
    (out / 'expected.json').write_text(json.dumps({'base': game_files(), 'update': game_files(True)}, default=lambda b: b.decode()))
    print('Generated eight bounded synthetic XCI fixtures')


if __name__ == '__main__':
    main()
