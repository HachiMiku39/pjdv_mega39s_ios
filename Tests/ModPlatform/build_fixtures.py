"""Generate inert packages for the public importer's Windows-dependency regression."""
from pathlib import Path
import json
import struct
import sys
import zipfile

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=False)
cases = []
asset = {"rom/objset/costume.farc": b"synthetic asset"}
# An inert PE32+ image header, with no code or entry point.
header = bytearray(512)
header[:2] = b"MZ"
struct.pack_into("<I", header, 60, 128)
struct.pack_into("<4sHHIIIHH", header, 128, b"PE\0\0", 0x8664, 1, 0, 0, 0, 240, 0x2022)
struct.pack_into("<H", header, 152, 0x20B)
struct.pack_into("<H", header, 220, 3)  # Windows console subsystem
pe = bytes(header)


def fixture(name, files, expected, zipped=False):
    if zipped:
        source = root / (name + ".zip")
        with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as target:
            for path, payload in files.items():
                target.writestr(name + "/" + path, payload)
    else:
        source = root / name
        for path, payload in files.items():
            dest = source / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(payload.encode() if isinstance(payload, str) else payload)
    cases.append(dict(name=name, source=str(source), expected=expected))
    return source


declared = {**asset, "config.toml": "include = ['.']\ndll = [\n # active entry\n 'Effect.DLL',\n]\n", "Effect.DLL": pe}
fixture("required-mixed", declared, "declaredPlugin")
fixture("wrapped-mixed", declared, "declaredPlugin", zipped=True)
fixture("missing-required", {**asset, "config.toml": 'dll = ["Missing.dll"]\n'}, "declaredPlugin")
fixture("placeholder", {**asset, "config.toml": 'dll = ["", "  "]\n'}, "pass")
fixture("description", {**asset, "config.toml": '# dll = ["doc.dll"]\ndescription = """Example:\ndll = ["doc.dll"]\n"""\n[translations]\ndll = ["doc.dll"]\n'}, "pass")
fixture("older-secondary-metadata", {**asset, "config.toml": 'version = "1.3"\ndll = [""]\n',
        "meta.json": '{"version":[1,0,0],"binaries":["legacy.dll"]}'}, "pass")
fixture("tools-with-assets", {**asset, "tools/converter.exe": pe, "tools/README.md": "offline authors' tool"}, "pass")
fixture("misleading-extension", {"plugin.dll": b"text, no Windows binary header"}, "pass")
fixture("invalid-pe-offset", {"plugin.dll": b"MZ" + bytes(58) + struct.pack("<I", 0x7fffffff)}, "pass")
fixture("equivocal-payload", {**asset, "example.dll": b"arbitrary example"}, "pass")
efi = bytearray(pe)
struct.pack_into("<H", efi, 220, 10)  # An EFI application, not Windows.
fixture("non-windows-pe", {"firmware.dll": bytes(efi)}, "pass")
fixture("windows-tool", {"tool.exe": pe}, "executableOnly")
fixture("many-windows-tools", {f"tools/plugin-{n}.dll": pe for n in range(257)}, "executableOnly")
fixture("renamed-pe", {"tool.bin": pe}, "executableOnly")
fixture("switch-code", {"atmosphere/contents/0100F3100DA46000/exefs/subsdk1": b"NSO0" + bytes(24)}, "pass")
fixture("multi-package-collection", {
    "config.toml": 'include = ["."]\n',
    "OptionalPC/config.toml": 'dll = ["effect.dll"]\n', "OptionalPC/effect.dll": pe,
    "SeparateAssets/config.toml": 'dll = [""]\n', "SeparateAssets/rom/objset/example.farc": b"data",
}, "pass")
fixture("non-root-config", {**asset, "rom/settings/config.toml": 'dll = ["asset-only.dll"]\n'}, "pass")
fixture("prepared-shape", {"0/rom_switch/rom/example.bin": b"data", "runtime.json": '{"format":"pjdv-runtime-mod-v1"}'}, "pass")
fixture("platform-alternatives", {**declared,
        "Switch/atmosphere/contents/0100F3100DA46000/romfs/rom/objset/costume.farc": b"data"}, "pass", zipped=True)
fixture("prepared-alternative", {**declared,
        "Apple/runtime.json": json.dumps({"format":"pjdv-runtime-mod-v1", "layers":["0"],
                                         "id":"529C8845-9873-4241-B4E6-7988F2B42107"}),
        "Apple/0/rom_switch/rom/example.bin": b"data"}, "pass")
fixture("manifest-is-not-proof", {**declared, "runtime.json": '{}'}, "declaredPlugin")
fixture("unknown", {"notes.txt": "empty package"}, "unknownStructure")
# Corrupt compressed data while preserving the directory entry. A short-circuit
# based only on the filename would incorrectly return a Windows classification.
bad = fixture("bad-crc", {"tool.dll": pe}, "archiveError", zipped=True)
content = bytearray(bad.read_bytes())
name_length, extra_length = struct.unpack_from("<HH", content, 26)
content[30 + name_length + extra_length + 3] ^= 0xff
bad.write_bytes(content)
(root / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
