"""Retranslate integer vertex inputs proven by NVN draw captures.

Default invocation only reports candidates. --apply preserves original cache
files and rejects shaders whose captured input types vary or bindings change.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

UINT = {0x03, 0x08, 0x0B, 0x0F, 0x14, 0x17, 0x1B, 0x20, 0x23, 0x27, 0x2C, 0x2F}
SINT = {0x04, 0x09, 0x0C, 0x10, 0x15, 0x18, 0x1C, 0x21, 0x24, 0x28, 0x2D, 0x30}
INPUT = r'(\w+)\s+\w+\s*\[\[attribute\((\d+)\)\]\]'
LAYOUT = r'struct spvDescriptorSetBuffer\d+\s*\{.*?\};'


def captured(log):
    facts = {}
    for key, fields in re.findall(r'VATTR ([0-9a-f]{16})_b([^\n]*)', log):
        slots = facts.setdefault(key, {})
        for slot, value in re.findall(r'a(\d+)=0x([0-9a-f]+)', fields):
            fmt = int(value, 16)
            kind = 'uint' if fmt in UINT else 'sint' if fmt in SINT else 'float'
            slots.setdefault(int(slot), set()).add(kind)
    return facts


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--log', type=Path, required=True)
    p.add_argument('--dev-root', type=Path, default=Path('/Volumes/Switch-iOS-Dev'))
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    game = a.dev_root / 'GameBuild/MEGA39-v1.0.9'
    cache = game / 'MetalCache/b-pjdv-e1b840d591cc'
    manifest = Path(__file__).resolve().parents[1] / 'Reports/runtime-attribute-overrides.json'
    jobs = {j['key']: j for j in json.loads((game / 'Shaders/jobs.json').read_text())}
    overrides = {j['key']: j for j in json.loads(manifest.read_text())} if manifest.exists() else {}
    for key, slots in captured(a.log.read_text(errors='replace')).items():
        meta_path = cache / (key + '_b.json')
        source_path = cache / (key + '_b.metallib')
        if not meta_path.exists():
            print(key, 'missing metadata'); continue
        meta = json.loads(meta_path.read_text())
        locations = {v['location'] for v in meta['vertex_inputs']}
        conflicts = {s: sorted(k) for s, k in slots.items() if s in locations and len(k) != 1}
        if conflicts:
            print(key, 'requires format-specific shader variants', conflicts); continue
        attr = {str(s): next(iter(k)) for s, k in slots.items() if s in locations and k != {'float'}}
        expected = {int(s): 'uint' if k == 'uint' else 'int' for s, k in attr.items()}
        if not any(not v['msl_type'].startswith(expected[v['location']])
                   for v in meta['vertex_inputs'] if v['location'] in expected):
            continue
        print(key, 'captured integer inputs', attr, flush=True)
        if not a.apply:
            continue
        job = dict(overrides.get(key, jobs[key]))
        job['attr'] = {**job.get('attr', {}), **attr}
        job['facts_status'] = 'Runtime NVN vertex format capture: ' + json.dumps(attr, sort_keys=True)
        temp = a.dev_root / 'Build/Temp/runtime-attributes' / key
        temp.mkdir(parents=True, exist_ok=True)
        job_path = temp / 'job.json'
        job_path.write_text(json.dumps([job], indent=2) + '\n')
        subprocess.run([str(a.dev_root / 'Toolchain/dotnet/dotnet'),
                        str(a.dev_root / 'Runtime/PJDV/dm/gfx/tools/dmsh_xlate/bin/Release/net10.0/dmsh_xlate.dll'),
                        str(job_path), str(temp)], check=True)
        output = temp / 'source.msl'
        subprocess.run([str(a.dev_root / 'Build/SpirvCross/spirv-cross'), str(temp / (key + '.spv')),
                        '--msl', '--msl-ios', '--msl-version', '20300', '--msl-argument-buffers',
                        '--msl-texture-buffer-native', '--msl-pad-fragment-output', '--output', str(output)], check=True)
        src, old = output.read_text(), source_path.read_text()
        if re.findall(LAYOUT, src, re.S) != re.findall(LAYOUT, old, re.S):
            raise ValueError(key + ': descriptor layout changed; regenerate complete reflection first')
        types = {int(s): t for t, s in re.findall(INPUT, src)}
        if set(types) != locations or any(not types[s].startswith(t) for s, t in expected.items()):
            raise ValueError(key + ': translated vertex inputs differ from captured facts')
        backup = a.dev_root / 'Build/Logs/runtime-attribute-backup' / key
        backup.mkdir(parents=True, exist_ok=True)
        for f in (source_path, meta_path):
            if not (backup / f.name).exists():
                shutil.copy2(f, backup / f.name)
        for v in meta['vertex_inputs']:
            v['msl_type'] = types[v['location']]
        meta['msl_sha256'] = hashlib.sha256(src.encode()).hexdigest()
        meta['notes'].append(job['facts_status'] + '; descriptor layout unchanged')
        source_path.write_text(src)
        meta_path.write_text(json.dumps(meta, indent=2) + '\n')
        overrides[key] = job
        manifest.write_text(json.dumps(list(overrides.values()), indent=2) + '\n')
        print(key, 'updated; restart the app to load', flush=True)


if __name__ == '__main__':
    main()
