"""Build Miku MSL source libraries/reflection from validated BNSH jobs.

This uses MIT-licensed reflection helpers from the pinned d2r-mobile source.
Missing texture/attribute facts remain explicit trial defaults in the manifest;
compilation does not assert visual or game-performance correctness.
"""
import argparse,ast,hashlib,json,re,subprocess
import instrument_simulator_border
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

def initialize_vertex_outputs(source):
    """Restore Ryujinx's (0,0,0,1) defaults lost by standalone translation.

    Without SetNextStage(), the translator sees no consumer input components
    and omits user-output initialization. Do this before original instructions,
    so explicit channel writes retain their exact behavior. The M39 eye shader
    writes modelPos.xy but consumes modelPos.w in its ellipsoid intersection.
    """
    if 'vertex main0_out main0(' not in source:
        return source
    structure = re.search(r'struct main0_out\s*\{(.*?)\};', source, re.S)
    if not structure:
        raise ValueError('Vertex output structure unavailable')
    fields = re.findall(r'\bfloat4\s+(\w+)\s+\[\[user\(locn[0-9]+\)\]\]\s*;', structure.group(1))
    if not fields:
        return source
    initial = 'main0_out out = {};'
    if source.count(initial) != 1:
        raise ValueError('Vertex output initializer changed')
    defaults = ''.join(f'\n    out.{name} = float4(0.0,0.0,0.0,1.0);' for name in fields)
    return source.replace(initial, initial + defaults, 1)

def initialize_screen_quad_origin(source, source_name):
    """Keep native postprocess UVs while adapting clip Y to Metal's top-left.

    Only authenticated full-screen vertex-ID quads with direct clip-XY
    exports qualify. Mesh/UI projections and edge-clearing geometry keep
    their original behavior. The marker prevents a second conversion.
    """
    image_filters = {'imgfilter/esm_gauss_s.bnsh', 'imgfilter/esm_gauss_t.bnsh',
                     'imgfilter/esm_filter_min.bnsh', 'imgfilter/esm_filter_erosion.bnsh',
                     'imgfilter/copy.bnsh', 'imgfilter/box4.bnsh'}
    if source_name in image_filters:
        if '// PJDV top-left screen quad' in source:
            return source
        if ('vertex main0_out main0(' not in source or
                '[[attribute(0)]]' not in source or
                'uint gl_VertexIndex [[vertex_id]]' in source or
                len(re.findall(r'out\.gl_Position\.y = fma\(_[0-9]+, -2\.0, 1\.0\);', source)) != 1):
            raise ValueError('Image-filter quad schema changed')
        position = source.rfind('    return out;')
        if position < 0:
            raise ValueError('Image-filter output unavailable')
        return (source[:position] + '    // PJDV top-left screen quad\n'
                '    out.gl_Position.y = -out.gl_Position.y;\n' + source[position:])
    if not source_name.startswith(('postprocess/', 'postprocess_dof/')) or source_name in (
            'postprocess_dof/dof_extend_right_bottom1.bnsh',
            'postprocess_dof/dof_extend_right_bottom2.bnsh',
            'postprocess/right_bottom_edge.bnsh', 'postprocess/sun.bnsh',
            'postprocess/sun_no_textured.bnsh', 'postprocess/test.bnsh'):
        return source
    if ('vertex main0_out main0(' not in source or
            'uint gl_VertexIndex [[vertex_id]]' not in source or
            '[[attribute(' in source or
            not re.search(r'out\.gl_Position\.x = _\d+;', source) or
            not re.search(r'out\.gl_Position\.y = _\d+;', source) or
            '// PJDV top-left screen quad' in source):
        return source
    position = source.rfind('    return out;')
    if position < 0:
        raise ValueError('Screen quad output unavailable')
    return (source[:position] + '    // PJDV top-left screen quad\n'
            '    out.gl_Position.y = -out.gl_Position.y;\n' + source[position:])

def helpers(reference):
    tree=ast.parse(reference.read_text());names={'decode_tex','reflect','raster_facts','drv_reads','unfillable'}
    selected=ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names],type_ignores=[])
    if {n.name for n in selected.body}!=names:raise ValueError('Reflection helper set mismatch')
    ns={'re':re,'TEX_BASE':0x20,'SAMP_BASE':0x420,'IMG_BASE':0x0,'DRV_FILL':{0:[(0x110,0x410),(0x510,0x610)],2:[(0x168,0x568),(0x568,0x968)]}}
    exec(compile(selected,str(reference),'exec'),ns);return ns

def build(root,cross,reference,cache,translator):
    h=helpers(reference);jobs=json.loads((root/'jobs-metal.json').read_text())
    # The translator loads the separately built Ryujinx assembly. Its bytecode
    # must participate in the cache identity when control-flow lowering changes.
    dependency=translator.with_name('Ryujinx.Graphics.Shader.dll')
    chain='pjdv-'+hashlib.sha256((Path(__file__).read_bytes()+Path(instrument_simulator_border.__file__).read_bytes()+reference.read_bytes()+cross.read_bytes()+translator.read_bytes()+dependency.read_bytes()+(root/'jobs-metal.json').read_bytes()+(root/'inventory.json').read_bytes())).hexdigest()[:12]
    out=cache/('b-'+chain);out.mkdir(parents=True,exist_ok=True)
    options=['--msl','--msl-ios','--msl-version','20300','--msl-argument-buffers','--msl-texture-buffer-native','--msl-pad-fragment-output']
    inventory={r['key']:r for r in json.loads((root/'inventory.json').read_text())['shaders']}
    def one(j):
        key=j['key'];metal=out/(key+'_b.metallib');spv=root/'SpirvMetal'/(key+'.spv');respath=root/'SpirvMetal'/(key+'.res.json')
        if not spv.is_file() or not respath.is_file():return {'key':key,'status':'missing_spirv'}
        r=subprocess.run([str(cross),*options,str(spv)],capture_output=True,text=True)
        if r.returncode:return {'key':key,'status':'msl_failed','error':r.stderr[:600]}
        src=initialize_vertex_outputs(r.stdout);res=json.loads(respath.read_text());slots=inventory[key]['reflection_sampler_slots']
        src=initialize_screen_quad_origin(src, inventory[key]['source'])
        for t in res['textures']:
            if t['cbuf_slot']!=-1 or t['handle']<8 or t['handle']%2 or (t['handle']-8)//2 not in (slots or []):
                return {'key':key,'status':'reflection_slot_mismatch'}
        bindings=h['reflect'](key,j['stage'],src,res)
        if any(b.get('kind')=='?' or b.get('reg',0) is None for b in bindings):return {'key':key,'status':'unresolved_binding','bindings':bindings}
        entry=re.search(r'(vertex|fragment|kernel)\s+\S+\s+(\w+)\s*\(',src);drv=h['drv_reads'](src);unfillable=h['unfillable'](drv)
        if not entry:return {'key':key,'status':'entry_missing'}
        refl={'key':key+'_b','route':'B','chain':chain,'dm_ctl':key,'source':'local authenticated BNSH','pc_paired':None,'stage':j['stage'],'entry':entry.group(2),'msl_entry_kind':entry.group(1),'threadgroup_size':None,'c1':j['c1'],'notes':res['notes']+['BNSH texture slots checked; visual and input types pending runtime validation'],'drv_reads':drv,'drv_unfillable':unfillable,'bindings':bindings,'vertex_inputs':[{'location':int(m.group(2)),'msl_type':m.group(1)} for m in re.finditer(r'(\w+)\s+\w+\s*\[\[attribute\((\d+)\)\]\]',src)],'raster':h['raster_facts'](j['stage'],src)}
        # Metal requires a depth attachment for a fragment depth output, even
        # when fixed-function depth testing and writing are disabled.
        refl['raster']['depth'] = bool(re.search(r'\[\[depth\(', src))
        metal.write_text(src);(out/(key+'_b.json')).write_text(json.dumps(refl,indent=2)+'\n')
        return {'key':key,'status':'source_ready','msl_sha256':hashlib.sha256(src.encode()).hexdigest(),'translation_notes':res['notes'],'unfillable_driver_reads':unfillable}
    with ThreadPoolExecutor(max_workers=6) as pool:rows=list(pool.map(one,jobs))
    status={'format':'pjdv-msl-trial-v1','chain':chain,'libraries':rows,'metallib_format':'UTF-8 MSL for first-use device compilation','validation':'resource types and visual fidelity pending'}
    status['simulator_variants'] = instrument_simulator_border.generate(out)
    instrument_simulator_border.generate(out, check=True)
    (out/'preparation.json').write_text(json.dumps(status,indent=2)+'\n')
    counts={s:sum(x['status']==s for x in rows)for s in {x['status']for x in rows}}
    print('Miku shader libraries',chain,counts,flush=True)
    return status

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('cache',type=Path);p.add_argument('--cross',type=Path,required=True);p.add_argument('--reference',type=Path,required=True);p.add_argument('--translator',type=Path,required=True);a=p.parse_args();build(a.root,a.cross,a.reference,a.cache,a.translator)
