"""Create simulator-only MSL variants preserving float2D sampler borders.

An all-one texture measures the in-bounds filter weight with the same sampler,
coordinates and mip levels. ClampToZero + borderColor * (1 - coverage) preserves
nearest, bilinear, mip and anisotropic filtering. Originals remain unchanged.
"""
import argparse
import copy
import hashlib
import json
import re
from pathlib import Path


def instrument(src, metadata):
    metadata['simulator_source_sha256'] = hashlib.sha256(src.encode()).hexdigest()
    bs = metadata['bindings']
    unused = [b['arg_id'] for b in bs if b['kind'] == 'tex' and
              not re.search(r'spvDescriptorSet0\.' + re.escape(b['msl_name']) + r'\b', src)]
    metadata['simulator_border_unused_texture_args'] = unused
    samplers = {b['msl_name']: b for b in bs if b['kind'] == 'samp_tex'}
    textures = {b['msl_name']: b for b in bs if b['kind'] == 'tex' and b['msl_type'] == 'texture2d<float>'}
    used = {}; changes = []
    for m in re.finditer(r'(spvDescriptorSet0\.(\w+))\.sample\(', src):
        tex = textures.get(m[2])
        if not tex: continue
        start = m.end(); pos = start; depth = 1
        while depth and pos < len(src):
            depth += (src[pos] == '(') - (src[pos] == ')'); pos += 1
        if depth: raise ValueError('Unbalanced sample expression')
        args = src[start:pos - 1]
        sm = re.match(r'spvDescriptorSet0\.(\w+)\s*,', args)
        sampler = samplers.get(sm[1]) if sm else None
        if not sampler or sampler['reg'] != tex['reg']: continue
        used[m[2]] = tex
        original = src[m.start():pos]
        cov = f'spvDescriptorSet0.pjdv_coverage_{tex["arg_id"]}.sample({args}).x'
        value = f'({original} + spvDescriptorSet0.pjdv_borderColors[{tex["arg_id"]}] * (1.0 - {cov}))'
        changes.append((m.start(), pos, value))
    if not changes: return (src, metadata) if unused else None
    for start, end, value in reversed(changes): src = src[:start] + value + src[end:]
    aid = max(b['arg_id'] for b in bs) + 1; declarations = []
    for tex in used.values():
        name = f'pjdv_coverage_{tex["arg_id"]}'
        declarations.append(f'    texture2d<float> {name} [[id({aid})]];')
        bs.append({'msl_name': name, 'msl_type': 'texture2d<float>', 'arg_id': aid,
                   'kind': 'border_coverage', 'reg': tex['reg']})
        aid += 1
    declarations.append(f'    constant float4* pjdv_borderColors [[id({aid})]];')
    bs.append({'msl_name': 'pjdv_borderColors', 'msl_type': 'constant float4*',
               'arg_id': aid, 'kind': 'border_colors'})
    if aid >= 64 or len(bs) > 64: raise ValueError('Simulator border variant exceeds argument limit')
    src = re.sub(r'(struct spvDescriptorSetBuffer0\s*\{.*?)(\};)',
                 lambda m: m[1] + '\n'.join(declarations) + '\n' + m[2], src, count=1, flags=re.S)
    metadata['simulator_border_texture_args'] = [tex['arg_id'] for tex in used.values()]
    metadata['notes'].append('Simulator float2D border coverage compensation; original cache unchanged')
    metadata['msl_sha256'] = hashlib.sha256(src.encode()).hexdigest()
    return src, metadata


def generate(cache, check=False):
    """Derive every variant from current source; never trust copied variants."""
    count = 0
    for source in cache.glob('*_b.metallib'):
        metadata = json.loads(source.with_suffix('.json').read_text())
        if metadata['stage'] not in ('vs', 'ps'): continue
        result = instrument(source.read_text(), copy.deepcopy(metadata))
        sim_source = source.with_name(source.stem + '_sim.metallib')
        sim_metadata = source.with_name(source.stem + '_sim.json')
        if result:
            src, meta = result
            if check:
                if (not sim_source.is_file() or sim_source.read_text() != src or
                        not sim_metadata.is_file() or json.loads(sim_metadata.read_text()) != meta):
                    raise ValueError(f'Stale simulator shader: {source.stem}')
            else:
                sim_source.write_text(src)
                sim_metadata.write_text(json.dumps(meta, indent=2) + '\n')
            count += 1
        elif sim_source.exists() or sim_metadata.exists():
            if check:
                raise ValueError(f'Orphan simulator shader: {source.stem}')
            sim_source.unlink(missing_ok=True)
            sim_metadata.unlink(missing_ok=True)
    return count


def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('cache', type=Path)
    p.add_argument('--check', action='store_true', help='Fail if any variant is stale or missing')
    a = p.parse_args(); count = generate(a.cache, check=a.check)
    print('Simulator border variants:', count)


if __name__ == '__main__': main()
