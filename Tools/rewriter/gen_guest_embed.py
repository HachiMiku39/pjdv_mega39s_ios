"""Generate signed Mach-O sections for sparse guest images, excluding BSS.

The loader reserves anonymous virtual memory for BSS. Only initialized bytes
and rewritten code become app data. Input manifests and segment hashes are
validated before producing assembly; this does not replace CPU equivalence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

PAGE = 0x4000
def rounded(n): return (n + PAGE - 1) & ~(PAGE - 1)

def generate(directory, names):
    directory = Path(directory)
    certificate = json.loads((directory/'cpu-equivalence.json').read_text())
    if certificate['format'] != 'pjdv-cpu-equivalence-v1': raise ValueError('Missing CPU verification certificate')
    assembly = ['// Generated sparse signed guest sections; BSS is virtual.']
    records, declarations, gates = [], [], []
    canonical, aliases = {}, {}
    for name in names:
        if not re.fullmatch('[a-z0-9_]{1,12}', name): raise ValueError('Invalid module name')
        layout = json.loads((directory / (name+'.segments.json')).read_text())
        proof = certificate['modules'][name]
        for file, expected in proof['artifacts'].items():
            if hashlib.sha256((directory/file).read_bytes()).hexdigest()!=expected:
                raise ValueError('Verified guest artifact changed: '+file)
        if layout['format'] != 'pjdv-segmented-nso-v1' or layout['module'] != name:
            raise ValueError('Unexpected segmented image')
        segments = {s['kind']:s for s in layout['segments']}
        if set(segments) != {'text','ro','data','patch','keypage','bss'}:
            raise ValueError('Missing or extra segment')
        for s in segments.values():
            if s['kind']=='bss':
                if s['file'] is not None or s['file_bytes'] != 0: raise ValueError('Serialized BSS rejected')
                continue
            if Path(s['file']).name != s['file']: raise ValueError('Invalid segment path')
            raw = (directory / s['file']).read_bytes()
            if len(raw)!=s['file_bytes'] or hashlib.sha256(raw).hexdigest()!=s['sha256']:
                raise ValueError('Segment length or SHA256 mismatch')
        original = layout['original_nso_sha256']
        signature = [(kind,segments[kind]['guest_offset'],segments[kind]['file_bytes'],segments[kind]['memory_bytes'],segments[kind].get('sha256')) for kind in sorted(segments)]
        if original in canonical:
            kept, previous = canonical[original]
            if previous != signature: raise ValueError('Duplicate NSO produced different rewritten segments')
            aliases[name] = kept
            continue
        canonical[original] = (name, signature)
        text = segments['text']; data = segments['data']; patch = segments['patch']; key = segments['keypage']
        if text['guest_offset'] != 0: raise ValueError('Text must start at zero')
        initialized = data['guest_offset']+data['file_bytes']
        text_pages = rounded(text['file_bytes']); rw_pages = rounded(initialized)-text_pages
        if initialized > 512*1024**2 or rw_pages <= 0: raise ValueError('Invalid initialized image bound')
        image = bytearray(initialized)
        for kind in ('text','ro','data'):
            s=segments[kind];off=s['guest_offset'];raw=(directory/s['file']).read_bytes()
            if off < 0 or off+len(raw)>initialized: raise ValueError('Segment outside initialized image')
            image[off:off+len(raw)]=raw
        init_path = directory/(name+'.initialized.bin');init_path.write_bytes(image)
        prefix=layout['patch_reserve_bytes']; patch_pages=rounded(patch['file_bytes'])
        if list(layout['key_indexes'].values()) != list(range(8)):
            raise ValueError('Thread slot indexes do not match loader')
        if prefix % PAGE or patch['guest_offset']!=-prefix or patch_pages > prefix or key['guest_offset']%PAGE:
            raise ValueError('Invalid patch prefix or keypage alignment')
        for suffix, section, path, start, length, memory in (
                ('text','__TEXT',init_path,0,text_pages,text_pages),
                ('rw','__DATA',init_path,text_pages,max(0,initialized-text_pages),rw_pages),
                ('patch','__TEXT',directory/patch['file'],0,patch['file_bytes'],patch_pages)):
            if suffix=='text': length=min(text_pages,initialized)
            path=str(path.resolve())
            if any(c in path for c in '\n\r"'):raise ValueError('Unsafe assembly path')
            symbol='pjdv_'+name+'_'+suffix
            declarations.append(f'extern const unsigned char {symbol}[];')
            assembly.extend([f'.section {section},__pj{name}{suffix[0]},regular,no_dead_strip',
                             '.p2align 14',f'.globl _{symbol}',f'_{symbol}:',
                             f'.incbin "{path}", {start}, {length}'])
            if memory>length:assembly.append(f'.space {memory-length}')
        records.append('{"%s",pjdv_%s_text,pjdv_%s_rw,pjdv_%s_patch,%d,%d,%d,%d,%d,%d,%d,%d}'%
                       (name,name,name,name,prefix,text_pages,rw_pages,patch_pages,key['guest_offset']+PAGE,
                        text['file_bytes'],segments['ro']['guest_offset'],data['guest_offset']))
        for line in (directory/(name+'.gates.tsv')).read_text().splitlines():
            ret,kind,arg,orig=line.split()
            ret=int(ret,16);arg=int(arg);orig=int(orig,16)
            if kind not in ('svc','cntpct','cntvct') or not -prefix<=ret<-prefix+patch_pages or not 0<=orig<text['file_bytes']:
                raise ValueError('Invalid gate record')
            # Allow only the verified archive call and optional diagnostic
            # judgment call. A generic private SVC remains rejected.
            # Keep rejecting unrelated private SVCs, even with valid segments.
            archive_gate=(kind=='svc' and arg==0x90 and name=='main' and orig==0x1f0850
                and original=='a370a68b4700a63d943a316916eb41ddedea5f5382c5b04eb3f126a9b8614e52'
                and proof.get('archive_gzip',{}).get('service')=='0x90')
            autoplay_gate=(kind=='svc' and arg==0x91 and name=='main' and orig==0x1af6a4
                and original=='a370a68b4700a63d943a316916eb41ddedea5f5382c5b04eb3f126a9b8614e52'
                and proof.get('autoplay',{}).get('service')=='0x91'
                and proof.get('autoplay',{}).get('caller')=='0x1af6a4')
            if (kind=='svc' and not (0<=arg<128 or archive_gate or autoplay_gate)) or (kind!='svc' and not 0<=arg<=30):
                raise ValueError('Unsupported gate argument')
            gates.append('{%d,%d,"%s",%d,%d}'%(len(records)-1,ret,kind,arg,orig))
    header='''#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct {
    const char *name;
    const unsigned char *text, *rw, *patch;
    uint64_t prefix, text_pages, rw_pages, patch_pages, virtual_bytes;
    uint64_t text_end, ro_off, data_off;
} pjdv_guest_layout;
'''+ '\n'.join(declarations)+'\nstatic const pjdv_guest_layout pjdv_layouts[] = {\n'+',\n'.join(records)+'\n};\n'
    header+='typedef struct { unsigned module; int64_t ret; const char *kind; int arg; uint64_t orig; } pjdv_gate_layout;\nstatic const pjdv_gate_layout pjdv_gates[] = {\n'+',\n'.join(gates)+'\n};\n'
    (directory/'GuestImages.S').write_text('\n'.join(assembly)+'\n')
    (directory/'GuestLayout.h').write_text(header)
    (directory/'GuestModules.json').write_text(json.dumps({'canonical_modules':[v[0] for v in canonical.values()], 'byte_identical_module_aliases':aliases},indent=2)+'\n')
    return len(records)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory');p.add_argument('modules',nargs='+');a=p.parse_args()
    print('Generated sparse signed sections for',generate(a.directory,a.modules),'modules')
