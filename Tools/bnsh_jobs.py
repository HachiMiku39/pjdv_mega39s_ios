"""Bounded BNSH shader inventory and native NVN-control-key job extraction.

ShaderLibrary's MIT BnshLoader/Structs are the format reference. Resource types
and compute workgroups need independent reflection/runtime evidence; this tool
never treats translator defaults as a verified shader pipeline.
"""
import argparse,hashlib,json,struct
from collections import Counter
from pathlib import Path

STAGES=['vs','tcs','tes','gs','ps','cs']
def records(path):
    d=path.read_bytes()
    def span(at,size):
        if at<0 or size<0 or at+size>len(d):raise ValueError('BNSH range outside file: '+str(path))
        return d[at:at+size]
    def u32(at):return struct.unpack('<I',span(at,4))[0]
    def u64(at):return struct.unpack('<Q',span(at,8))[0]
    if span(0,4)!=b'BNSH' or span(96,4)!=b'grsc':raise ValueError('BNSH/GRSC magic mismatch: '+str(path))
    count=u32(124);array=u64(128)
    if count>32768:raise ValueError('BNSH variation limit')
    span(array,count*64)
    for variation in range(count):
        program=u64(array+variation*64+16);span(program,64)
        for stage_index,stage in enumerate(STAGES):
            descriptor=u64(program+8+stage_index*8)
            if not descriptor:continue
            span(descriptor,64);control_at=u64(descriptor+8);code_at=u64(descriptor+16)
            code_size=u32(descriptor+24);control_size=u32(descriptor+28)
            if not 0x880<=control_size<=1024*1024 or not 0<code_size<=16*1024*1024:raise ValueError('BNSH shader size bound')
            control=span(control_at,control_size);code=span(code_at,code_size)
            if control[:4]!=bytes.fromhex('34127698'):raise ValueError('NVN control magic mismatch')
            start,end=struct.unpack_from('<II',control,0x700)
            if not 0<=start<=end<=len(code):raise ValueError('NVN c1 bounds')
            reflection=u64(program+0x78)
            sampler_slots=None
            if reflection:
                span(reflection,48);reflect_at=u64(reflection+8*stage_index)
                if reflect_at:
                    span(reflect_at,96);dictionary=u64(reflect_at+16)
                    samplers=0
                    if dictionary:
                        if span(dictionary,4)!=b'_DIC':raise ValueError('Sampler dictionary magic')
                        samplers=u32(dictionary+4)
                    first=struct.unpack('<i',span(reflect_at+44,4))[0]
                    slots_at=u32(reflect_at+56);slots_count=u32(reflect_at+76)
                    if samplers>128 or slots_count>1024 or first<0 or first+samplers>slots_count:raise ValueError('Reflection sampler slot bounds')
                    slots=struct.unpack('<'+'i'*slots_count,span(slots_at,slots_count*4)) if slots_count else ()
                    sampler_slots=list(slots[first:first+samplers])
            yield {'sampler_slots':sampler_slots,'stage':stage,'variation':variation,'key':hashlib.sha256(control[:0x880]).hexdigest()[:16],
                   'code':code,'control':control,'c1':code[start:end]}

# GPU replay of captured MEGA39 stage materials found optimized AST alpha
# becoming zero where conservative translation retains texture alpha. Keep
# these authenticated shader identities on the conservative path; do not
# disable alpha testing or force opacity in the generated Metal source.
CONSERVATIVE_AST_KEYS = {'4c0bc48414cb4fad', '9875786769c5bcf6'}

def prepare(source,output):
    output.mkdir(parents=True,exist_ok=True);jobs=[];unique={};rows=[];stats=Counter();files=0
    for path in sorted(source.rglob('*.bnsh')):
        files+=1
        for r in records(path):
            stats[r['stage']]+=1;key=r['key'];digest=hashlib.sha256(r['code']+r['control']).hexdigest()
            if key in unique:
                if unique[key]!=(digest,r['stage']):raise ValueError('NVN key collision with different shader data: '+key)
                continue
            unique[key]=(digest,r['stage']);name=str(path.relative_to(source))
            row={'key':key,'stage':r['stage'],'source':name,'variation':r['variation'],'code_bytes':len(r['code']),'control_bytes':len(r['control']),'c1_bytes':len(r['c1']),'payload_sha256':digest,'reflection_sampler_slots':r['sampler_slots']}
            rows.append(row)
            code=output/(key+'.bin');raw=r['code'] if r['stage']=='cs' else r['code'][0x30:];code.write_bytes(raw)
            (output/(key+'.control.bin')).write_bytes(r['control'])
            if r['stage'] in ('vs','ps'):
                jobs.append({'key':key,'stage':r['stage'],'code':str(code),'tex':{},'img':{},'attr':{},'fout':{},'c1':r['c1'].hex(),'debug':key in CONSERVATIVE_AST_KEYS,'reduced':False,'facts_status':'defaults_pending_runtime_evidence'})
    result={'format':'pjdv-bnsh-inventory-v1','source_files':files,'variation_stage_records':dict(stats),'unique_shaders':len(rows),'shaders':rows,'facts_validation':'pending; texture/image types and compute workgroups require evidence'}
    (output/'inventory.json').write_text(json.dumps(result,indent=2)+'\n');(output/'jobs.json').write_text(json.dumps(jobs,indent=2)+'\n')
    stage_names={'vs':'顶点','ps':'像素','cs':'计算','gs':'几何','tcs':'细分控制','tes':'细分求值'}
    (output/'shader_map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\n'+''.join(f"{r['source']}\t{r['variation']}\t{stage_names[r['stage']]}\t{r['key']}\n" for r in rows))
    print(json.dumps({k:v for k,v in result.items() if k!='shaders'}));return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('output',type=Path);a=p.parse_args();prepare(a.source,a.output)
