"""Small, deterministic stored RAR4/RAR5 test archives, without an external writer."""
import struct
import sys
import zlib
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
root.mkdir()
title = "0100F3100DA46000"
prefix = "contents/" + title + "/romfs/"
payloads = [("rom_switch/rom/2d/sample.bin", b"synthetic UI"), ("rom/scene/sample.bin", b"synthetic scene")]
entries = [(prefix + name, data) for name, data in payloads]


def number(value):
    chunks = bytearray()
    while value >= 128:
        chunks.append((value & 127) | 128)
        value >>= 7
    chunks.append(value)
    return bytes(chunks)


def rar4(files, flags=0):
    def block(kind, flags, fields):
        header = struct.pack("<BHH", kind, flags, 7 + len(fields)) + fields
        return struct.pack("<H", zlib.crc32(header) & 65535) + header
    result = bytearray(b"Rar!\x1a\x07\x00" + block(0x73, flags, bytes(6)))
    for path, data in files:
        name = path.encode()
        fields = struct.pack("<IIBIIBBHI", len(data), len(data), 3, zlib.crc32(data),
                             0, 20, 0x30, len(name), 0o100644)
        result.extend(block(0x74, 0x8000, fields + name) + data)
    result.extend(block(0x7b, 0, b""))
    return result


def rar5(files, flags=0, encrypted=False):
    def block(fields):
        header = number(len(fields)) + fields
        return struct.pack("<I", zlib.crc32(header)) + header
    result = bytearray(b"Rar!\x1a\x07\x01\x00")
    if encrypted:
        # Header-encryption declaration with version, flags, KDF exponent and salt.
        result.extend(block(bytes([4, 0, 0, 0, 15]) + bytes(16)))
    result.extend(block(bytes([1, 0]) + number(flags)))
    for path, data in files:
        name = path.encode()
        header = (bytes([2, 2]) + number(len(data)) + number(4) + number(len(data)) +
                  number(0o100644) + struct.pack("<I", zlib.crc32(data)) +
                  bytes([0, 1]) + number(len(name)) + name)
        result.extend(block(header) + data)
    result.extend(block(bytes([5, 0, 0])))
    return result


for path, data in entries:
    dest = root / "Directory" / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
with zipfile.ZipFile(root / "Layer.zip", "w", zipfile.ZIP_DEFLATED) as target:
    for path, data in reversed(entries):
        target.writestr(path, data)
(root / "Layer4.rar").write_bytes(rar4(entries))
(root / "Layer5.rar").write_bytes(rar5(reversed(entries)))
(root / "Foreign.rar").write_bytes(rar5([(p.replace(title, "0100000000000000"), b) for p, b in entries]))
(root / "Plugin.rar").write_bytes(rar4([("config.toml", b'dll = ["Plugin.dll"]'), ("rom/model.bin", b"model")]))
(root / "Code.rar").write_bytes(rar5([(prefix + "rom/file.dll", b"unsupported")]))
(root / "Collision.rar").write_bytes(rar4([entries[0], (entries[0][0].upper(), b"different")]))
(root / "Duplicate.rar").write_bytes(rar5([entries[0], entries[0]]))
(root / "Cancel.rar").write_bytes(rar5([(prefix+"rom/large.bin", bytes(256 * 1024))]))
(root / "Split4.rar").write_bytes(rar4(entries, flags=1))
(root / "Split5.rar").write_bytes(rar5(entries, flags=1))
(root / "Encrypted4.rar").write_bytes(rar4(entries, flags=0x80))
(root / "Encrypted5.rar").write_bytes(rar5(entries, encrypted=True))
for name, build in [("4", rar4), ("5", rar5)]:
    source = build(entries)
    pos = source.index(b"synthetic UI")
    corrupt = source.copy()
    corrupt[pos] ^= 1
    (root / ("Corrupt"+name+".rar")).write_bytes(corrupt)
    (root / ("Truncated"+name+".rar")).write_bytes(source[:pos+2])

# Preserve the upstream compressed bitstream for the first regular RAR4
# member. The original archive also contains a symlink, which our installer
# correctly rejects before returning a complete archive.
upstream = Path(__file__).resolve().parents[2] / "ThirdParty/ModRAR/fixtures"
normal = (upstream / "test_read_format_rar_compress_normal.rar").read_bytes()
main_size = struct.unpack_from("<H", normal, 7 + 5)[0]
first = 7 + main_size
header_size, packed_size = struct.unpack_from("<HI", normal, first + 5)
assert normal[first+2] == 0x74 and normal[first+25] == 0x33
single = normal[:first + header_size + packed_size] + rar4([])[-7:]
(root / "UpstreamCompressed4.rar").write_bytes(single)
