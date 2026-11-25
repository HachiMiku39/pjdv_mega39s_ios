#!/usr/bin/env python3
"""Create or apply a PJDV host update. Requires the exact preceding local app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import sys
import tempfile
import zipfile

SCHEMA = "pjdv-host-update-v1"
LANGS = ("en", "ja", "ko", "zh-Hans", "zh-Hant")
GUEST = {"__pj" + module + suffix for module in ("main", "sdk", "subsdk0", "subsdk1") for suffix in ("t", "r", "p")}
LIMIT = 256 * 1024 * 1024


def check(condition, message):
    if not condition:
        raise ValueError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def file_hash(p):
    h = hashlib.sha256()
    with p.open("rb") as stream:
        for piece in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(piece)
    return h.hexdigest()


def settings(platform):
    top = "Contents/" if platform == "mac" else ""
    resources = top + "Resources/" if top else ""
    exe = top + ("MacOS/PJDVM39" if top else "PJDVM39")
    allow = {resources + lang + ".lproj/Localizable.strings" for lang in LANGS}
    allow.update({exe, top + "Info.plist"})
    if top:
        allow.update({top + "_CodeSignature/CodeResources",
                      top + "PlugIns/PJDVMacLifecycle.bundle/Contents/MacOS/PJDVMacLifecycle"})
    return exe, top + "Info.plist", allow


def inventory(folder):
    check(folder.is_dir() and not folder.is_symlink(), "Expected ordinary .app directory")
    output = {}
    for root, dirs, files in os.walk(folder):
        for name in dirs + files:
            p = Path(root) / name
            check(not p.is_symlink(), "Symlink in input: " + name)
        for name in files:
            path = Path(root) / name
            rel = path.relative_to(folder).as_posix()
            check(path.is_file(), "Special file in input: " + rel)
            # macOS Finder may attach housekeeping files on HFS+/exFAT.
            if name == ".DS_Store" or name.startswith("._"):
                continue
            output[rel] = file_hash(path)
    return output


def tree_hash(entries):
    return sha(json.dumps(entries, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode())


def sections(binary):
    check(len(binary) >= 32 and binary[:4] == b"\xcf\xfa\xed\xfe", "Expected a little-endian arm64 Mach-O")
    cpu, = struct.unpack_from("<I", binary, 4)
    check(cpu == 0x100000c, "Unexpected CPU")
    count, total = struct.unpack_from("<II", binary, 16)
    pos = 32
    found = []
    for _ in range(count):
        kind, length = struct.unpack_from("<II", binary, pos)
        check(length >= 8 and pos + length <= total + 32 <= len(binary), "Invalid Mach-O command")
        if kind == 25:
            n, = struct.unpack_from("<I", binary, pos + 64)
            check(72 + n * 80 <= length, "Invalid Mach-O segment")
            for j in range(n):
                name, _, _, size, offset = struct.unpack_from("<16s16sQQI", binary, pos + 72 + 80*j)
                if name.startswith(b"__pj"):
                    label = name.rstrip(b"\0").decode("ascii")
                    check(size > 0 and offset + size <= len(binary), "Guest section bounds")
                    found.append((offset, size, label))
        pos += length
    found.sort()
    check(pos == total + 32 and len(found) == len(GUEST) and {v[2] for v in found} == GUEST, "Unrecognized guest layout")
    end = 32 + total
    for off, size, name in found:
        check(off >= end, "Overlapping guest section: " + name)
        end = off + size
    return found


def split_executable(data):
    packed = bytearray()
    guest = {}
    last = 0
    layout = []
    for offset, size, name in sections(data):
        packed.extend(data[last:offset])
        guest[name] = data[offset:offset + size]
        layout.append([len(packed), name])
        last = offset + size
    packed.extend(data[last:])
    return bytes(packed), guest, layout


def restore(packed, guest, layout):
    check(len(layout) == len(GUEST) and {n for _, n in layout} == GUEST, "Invalid guest placement")
    output = bytearray()
    last = 0
    for offset, name in layout:
        check(isinstance(offset, int) and last <= offset <= len(packed), "Invalid host offset")
        output.extend(packed[last:offset])
        output.extend(guest[name])
        last = offset
    output.extend(packed[last:])
    check(split_executable(output)[2] == layout, "Rebuilt Mach-O layout does not match")
    return output


def version(root, path, build):
    info = plistlib.loads((root/path).read_bytes())
    check((info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"), info.get("CFBundleIdentifier")) ==
          ("0.2.0", build, "com.local.switchioslab"), "Unexpected app version or identifier")


def make(platform, base, target, output):
    exe, info, allow = settings(platform)
    version(base, info, "1")
    version(target, info, "6")
    source, final = inventory(base), inventory(target)
    check(set(source) == set(final), "File list differs")
    changed = sorted(k for k in final if source[k] != final[k])
    check(exe in changed and info in changed and set(changed) <= allow,
          "Differences outside audited host files: " + str(set(changed)-allow))
    host, old_guest, _ = split_executable((base/exe).read_bytes())
    new_host, new_guest, layout = split_executable((target/exe).read_bytes())
    check(old_guest == new_guest, "A game section changed; update cannot be distributed")
    # Only the application-owned intervals are encoded. A bytewise delta avoids
    # republishing unchanged constants in those intervals. The signed game
    # sections themselves never enter the host stream and have no patch opcodes.
    common = min(len(host), len(new_host))
    difference = (int.from_bytes(host[:common], "little") ^ int.from_bytes(new_host[:common], "little")).to_bytes(common, "little")
    payload = difference + new_host[common:]
    manifest = {"schema": SCHEMA, "platform": platform, "old_tree": tree_hash(source),
                "new_tree": tree_hash(final), "changed": {k: final[k] for k in changed},
                "layout": layout, "guest": {k: sha(v) for k,v in old_guest.items()},
                "source_host_bytes": len(host), "target_host_bytes": len(new_host)}
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr("manifest.json", json.dumps(manifest, sort_keys=True, separators=(",", ":")))
        z.writestr("host.xor", payload)
        for name in changed:
            if name != exe:
                z.write(target/name, "files/"+name)
    print(f"{platform}: copied {len(source)-len(changed)} files and all {len(old_guest)} guest sections locally; {len(changed)} updated host files")


def apply(platform, base, patch, target):
    exe, info, allow = settings(platform)
    version(base, info, "1")
    source = inventory(base)
    check(not target.exists() and not target.is_symlink(), "Output exists")
    check(not target.resolve().is_relative_to(base.resolve()), "Output must be outside input")
    with zipfile.ZipFile(patch) as z:
        infos=z.infolist()
        check(len(infos) <= 32 and sum(v.file_size for v in infos) <= LIMIT, "Unexpected patch size")
        names = {e.filename for e in infos}
        check(len(names) == len(infos) and "manifest.json" in names and z.getinfo("manifest.json").file_size <= 65536, "Invalid patch manifest")
        m=json.loads(z.read("manifest.json"))
        check(m["schema"] == SCHEMA and m["platform"] == platform, "Update platform mismatch")
        check(tree_hash(source) == m["old_tree"], "Input files do not match the original unsigned iOS or ad-hoc Mac build 1")
        changed=m["changed"]
        check({info,exe} <= changed.keys() <= allow and changed.keys() <= source.keys(), "Unapproved changed path")
        check(names == {"manifest.json", "host.xor"} | {"files/"+r for r in changed if r!=exe}, "Unexpected update entries")
        old, guest, _ = split_executable((base/exe).read_bytes())
        check({k:sha(v) for k,v in guest.items()} == m["guest"], "Local guest content mismatch")
        payload=z.read("host.xor")
        check(len(payload) == m["target_host_bytes"] and len(old) == m["source_host_bytes"], "Invalid host patch length")
        common=min(len(payload),len(old))
        packed=(int.from_bytes(old[:common],"little") ^ int.from_bytes(payload[:common],"little")).to_bytes(common,"little")+payload[common:]
        executable=restore(packed,guest,m["layout"])
        check(sha(executable) == changed[exe], "Host executable reconstruction failed")
        target.mkdir()
        try:
            for rel, digest in source.items():
                new=target/rel
                new.parent.mkdir(parents=True,exist_ok=True)
                if rel not in changed:
                    shutil.copy2(base/rel,new)
                else:
                    data=executable if rel == exe else z.read("files/"+rel)
                    check(sha(data)==changed[rel], "File digest mismatch: "+rel)
                    new.write_bytes(data)
                    shutil.copymode(base/rel,new)
            version(target,info,"6")
            check(tree_hash(inventory(target)) == m["new_tree"], "Final app digest mismatch")
        except BaseException:
            shutil.rmtree(target)
            raise
    print("Verified build 6 application:",target)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=("make","apply"))
    p.add_argument("platform", choices=("ios","mac"))
    p.add_argument("base", type=Path)
    p.add_argument("input", type=Path, help="Target app for make; published update ZIP for apply")
    p.add_argument("output", type=Path, help="Must not exist")
    args = p.parse_args()
    (make if args.action == "make" else apply)(args.platform,args.base,args.input,args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, struct.error, zipfile.BadZipFile) as e:
        sys.exit(str(e))
