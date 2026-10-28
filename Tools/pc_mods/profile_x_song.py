"""Private X Song Pack RomFS experiment. Never edits source/base assets.

Classic database structures follow the pinned MikuMikuLibrary readers saved
in Reference/. X Charts Pack remains quarantined until New Classics exists.
"""
import sys, os, re, json, struct, shutil, copy
from pathlib import Path
import profile_model as lib
from profile_model import u,z,Writer,entries,sha,obj_read,obj_write,tex_read,tex_write,properties,propbytes,group,setgroup,farc_write,objset,textures
WORK=lib.WORK
SRC=lib.SOURCE
BASE=lib.BASE
OVER=WORK/'overlay'
outputs=[]
def write(rel,b):
    p=OVER/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
    outputs.append({'path':str(rel),'size':len(b),'sha256':sha(b)})
def db2_read(b,aet=False):
    n,so,m,mo=struct.unpack_from('<4I',b);stride=20 if aet else 16
    sets=[]
    for i in range(n):
        q=so+i*stride
        assert u(b,q+12)==i
        d={'id':u(b,q),'name':z(b,u(b,q+4)),'file':z(b,u(b,q+8)),'members':[]}
        if aet:d['sprite']=u(b,q+16)
        sets.append(d)
    for i in range(m):
        q=mo+i*12;info=u(b,q+8);si=info>>16
        if not aet:si &= 0xfff
        assert si<n
        sets[si]['members'].append({'id':u(b,q),'name':z(b,u(b,q+4)),'index':info&65535,'texture':False if aet else bool(info&0x10000000)})
    return sets
def db2_write(a,aet=False):
    stride=20 if aet else 16;mo=16+len(a)*stride;nn=sum(len(s['members']) for s in a)
    w=Writer(mo+nn*12);w.put(0,len(a),16,nn,mo);j=0
    assert aet or len(a)<4096
    for i,s in enumerate(a):
        vals=[s['id'],w.string(s['name']),w.string(s['file']),i]
        if aet:vals.append(s['sprite'])
        w.put(16+i*stride,*vals)
        for v in s['members']:
            info=(i<<16)|v['index']|(0x10000000 if v['texture'] else 0)
            w.put(mo+j*12,v['id'],w.string(v['name']),info);j+=1
    b=bytes(w.b);assert db2_read(b,aet)==a;return b
def merge_sets(a,delta):
    # No implicit replacement by number: conflicting meanings are rejected.
    ids={s['id']:s for s in a};names={s['name']:s for s in a}
    for s in delta:
        if s['id']==4527 and s['name']=='SPR_SEL_PVTMB' and s['id'] in ids:
            old=ids[s['id']];lookup={v['id']:v for v in s['members']}
            assert all(v['id'] in lookup and lookup[v['id']]['name']==v['name'] for v in old['members'])
            assert s['file']==old['file']
            a[a.index(old)]=s;ids[s['id']]=s;names[s['name']]=s
        elif s['id'] in ids:
            assert ids[s['id']]==s,('id collision',s['id'],s['name'],ids[s['id']]['name'])
        elif s['name'] in names:
            assert names[s['name']]==s,('name collision',s['name'])
        else:a.append(s);ids[s['id']]=s;names[s['name']]=s
    return a
def mot_read(b):
    ver,so,io,n,bo,nb=struct.unpack_from('<6I',b);sets=[]
    for i in range(n):
        q=so+i*16;no,nn,mo=struct.unpack_from('<3I',b,q+4)
        sets.append({'id':u(b,io+i*4),'name':z(b,u(b,q)),'motions':[{'name':z(b,u(b,no+j*4)),'id':u(b,mo+j*4)} for j in range(nn)]})
    return sets,[z(b,u(b,bo+i*4)) for i in range(nb)]
def mot_write(a,bones):
    w=Writer(64+len(a)*16+16);so=64;io=w.align();w.b.extend(b'\0'*(4*len(a)));bo=w.align();w.b.extend(b'\0'*(4*len(bones)))
    w.put(0,1,so,io,len(a),bo,len(bones))
    for i,s in enumerate(a):
        no=w.align(4);w.b.extend(b'\0'*(4*len(s['motions'])));mo=w.align(4);w.b.extend(b'\0'*(4*len(s['motions'])))
        w.put(so+i*16,w.string(s['name']),no,len(s['motions']),mo);w.put(io+i*4,s['id'])
        for j,v in enumerate(s['motions']):w.put(no+j*4,w.string(v['name']));w.put(mo+j*4,v['id'])
    for i,n in enumerate(bones):w.put(bo+i*4,w.string(n))
    b=bytes(w.b);assert mot_read(b)==(a,bones);return b
def stage_merge(base,delta,objmap,texmap):
    # Retain original payload blobs, relocate only documented absolute pointers.
    out=bytearray(base);out.extend(b'\0'*((-len(out))%16));delta_base=len(out);out.extend(delta)
    records=[];effects=[];counts=[];ids=[];stages=[]
    for raw,bias,is_mod in ((base,0,False),(delta,delta_base,True)):
        n,so,eo,co,ao=struct.unpack_from('<5I',raw)
        for i in range(n):
            row=bytearray(raw[so+i*112:so+(i+1)*112]);assert len(row)==112
            stages.append({'name':z(raw,u(row,0)),'id':u(raw,ao+i*8),'mod':is_mod})
            for q in (0,4,64,76,80):
                old=u(row,q)
                if old:struct.pack_into('<I',row,q,old+bias)
            if is_mod:
                old=u(row,8);assert old in objmap
                struct.pack_into('<I',row,8,objmap[old])
                for q in range(12,36,4):
                    old=struct.unpack_from('<H',row,q+2)[0]
                    if old in objmap:struct.pack_into('<H',row,q+2,objmap[old])
                for q in (36,40,44,56,60):
                    old=u(row,q)
                    if old in texmap:struct.pack_into('<I',row,q,texmap[old])
            records.append(bytes(row));effects.append(raw[eo+i*96:eo+(i+1)*96]);counts.append(u(raw,co+i*4))
            aid,ap=struct.unpack_from('<2I',raw,ao+i*8);ids.append((aid,ap+bias if ap else 0))
    assert len({v['id'] for v in stages})==len(stages),'stage ID collision'
    def append(raw):
        out.extend(b'\0'*((-len(out))%16));p=len(out);out.extend(raw);return p
    so=append(b''.join(records));eo=append(b''.join(effects));co=append(struct.pack('<'+'I'*len(counts),*counts));ao=append(b''.join(struct.pack('<2I',*v) for v in ids))
    struct.pack_into('<5I',out,0,len(records),so,eo,co,ao)
    out[20:22]=b'\1\2'
    return bytes(out),stages
def main():
    OVER.mkdir(exist_ok=True)
    obj_paths=list(BASE.glob('*/rom/objset/*obj_db.bin'))+list(lib.DLC.glob('*/**/rom/objset/*obj_db.bin'))
    tex_paths=list(BASE.glob('*/rom/objset/*tex_db.bin'))+list(lib.DLC.glob('*/**/rom/objset/*tex_db.bin'))
    maxobj=max(s['id'] for p in obj_paths for s in obj_read(p.read_bytes()));maxtex=max(s['id'] for p in tex_paths for s in tex_read(p.read_bytes()))
    modobj=obj_read((SRC/'rom/objset/mod_obj_db.bin').read_bytes());modtex=tex_read((SRC/'rom/objset/mod_tex_db.bin').read_bytes())
    objmap={s['id']:maxobj+1+i for i,s in enumerate(modobj)};texmap={s['id']:maxtex+1+i for i,s in enumerate(modtex)}
    assert max(objmap.values())<65536
    for s in modobj:s['id']=objmap[s['id']]
    for s in modtex:s['id']=texmap[s['id']]
    for p in BASE.glob('*/rom/objset/obj_db.bin'):write(p.relative_to(BASE),obj_write(merge_sets(obj_read(p.read_bytes()),modobj)))
    for p in BASE.glob('*/rom/objset/tex_db.bin'):
        before=tex_read(p.read_bytes());assert not {t['id'] for t in before}&set(texmap.values());write(p.relative_to(BASE),tex_write(before+modtex))
    print('Registered',len(modobj),'object sets',len(modtex),'textures',flush=True)
    changes=[]
    for p in sorted((SRC/'rom').rglob('*')):
        if not p.is_file() or p.name.startswith('.') or '备份' in p.parts:continue
        rel=p.relative_to(SRC/'rom')
        if p.name.startswith(('mod_','spr_fnt_')) or str(rel)=='fontmap.farc' or 'lang2' in rel.parts:continue
        if '--tables-only' in sys.argv:
            dst=OVER/'rom_switch/rom'/rel;assert dst.is_file()
            outputs.append({'path':str(dst.relative_to(OVER)),'size':dst.stat().st_size,'sha256':sha(dst.read_bytes())})
            continue
        if rel.parts[0]=='objset' and p.suffix=='.farc':
            blocks=[]
            for name,raw in entries(p):
                b=bytearray(raw);positions=[]
                if name.endswith('_obj.bin'):
                    objset(raw);n=u(b,4);po=u(b,12);to=u(b,28);nt=u(b,32)
                    positions=[to+i*4 for i in range(nt)]
                    for i in range(n):
                        o=u(b,po+i*4);ma=o+u(b,o+36);nc=u(b,o+32)
                        positions.extend(ma+j*0x4b0+20+k*120+4 for j in range(nc) for k in range(8))
                modified=[]
                for q in positions:
                    old=u(b,q)
                    if old in texmap:struct.pack_into('<I',b,q,texmap[old]);modified.append(q)
                allowed={i for q in modified for i in range(q,q+4)}
                assert all(a==c or i in allowed for i,(a,c) in enumerate(zip(raw,b)))
                if name.endswith('_obj.bin'):objset(b)
                if name.endswith('_tex.bin'):textures(b)
                blocks.append((name,bytes(b)));changes.append({'archive':p.name,'entry':name,'texture_id_changes':len(modified),'size':len(b)})
            write(Path('rom_switch/rom')/rel,farc_write(blocks))
        else:
            # Copy into the private test profile, never into the original tree.
            write(Path('rom_switch/rom')/rel,p.read_bytes())
    print('Copied resource payloads',len(outputs),flush=True)
    for filename,aet in [('spr_db.bin',False),('aet_db.bin',True)]:
        delta=db2_read((SRC/'rom/2d'/('mod_'+filename)).read_bytes(),aet)
        # PC registry includes legacy non-X entries without matching assets,
        # including duplicate names/IDs. Keep the original Switch entries.
        if aet:
            delta=[s for s in delta if (SRC/'rom/2d'/s['file']).is_file()]
            assert len(delta)==32
        for p in BASE.glob('*/rom/2d/'+filename):write(p.relative_to(BASE),db2_write(merge_sets(db2_read(p.read_bytes(),aet),copy.deepcopy(delta)),aet))
    md,bones=mot_read(dict(entries(SRC/'rom/rob/mod_mot_db.farc'))['mot_db.bin'])
    for p in BASE.glob('*/rom/rob/mot_db.farc'):
        before,bb=mot_read(dict(entries(p))['mot_db.bin']);assert bones==bb
        write(p.relative_to(BASE),farc_write([('mot_db.bin',mot_write(merge_sets(before,copy.deepcopy(md)),bb))]))
    stages=None
    for p in BASE.glob('*/rom/stage_data.bin'):
        b,stages=stage_merge(p.read_bytes(),(SRC/'rom/mod_stage_data.bin').read_bytes(),objmap,texmap);write(p.relative_to(BASE),b)
    auth=properties((SRC/'rom/auth_3d/mod_auth_3d_db.bin').read_bytes());delta=group(auth,'uid')
    for p in BASE.glob('*/rom/auth_3d/auth_3d_db.bin'):
        d=properties(p.read_bytes());cats=group(d,'category');seen={v['value'] for v in cats}
        cats.extend(v for v in group(auth,'category') if v['value'] not in seen)
        rows=group(d,'uid');oldlen=len(rows);rows.extend({'value':'D PJDV_UNUSED_'+str(i)} for i in range(oldlen,max(int(v['org_uid']) for v in delta)+1))
        for v in delta:
            i=int(v['org_uid']);assert i>=oldlen;rows[i]={k:x for k,x in v.items() if k!='org_uid'}
        d=setgroup(setgroup(d,'category',cats),'uid',rows);write(p.relative_to(BASE),b'#A3DA__________\n'+propbytes(d))
    pv=properties((SRC/'rom/mod_pv_db.txt').read_bytes());pv_ids=sorted({int(k.split('.')[0][3:]) for k in pv});assert pv_ids==list(range(800,832))
    for name,delta in [('pv_db.txt',pv),('pv_field.txt',properties((SRC/'rom/mod_pv_field.txt').read_bytes()))]:
        for p in BASE.glob('*/rom/'+name):
            d=properties(p.read_bytes());assert not set(d)&set(delta),('PV collision',p);d.update(delta);write(p.relative_to(BASE),propbytes(d))
    p=BASE/'rom_ps4/rom/gm_pv_list_tbl.farc';blocks=[]
    for name,b in entries(p):
        if name=='gm_pv_list.bin':
            d=properties(b);rows=group(d,'pv_list');template=next(v for v in rows if v['id']=='2')
            assert not {int(v['id']) for v in rows}&set(pv_ids)
            for pid in pv_ids:
                r=copy.deepcopy(template);r.update(id=str(pid),name=pv[f'pv_{pid}.song_name'],ignore='0')
                for diff in ('easy','normal','hard','extreme','encore'):
                    for k in list(r):
                        if k.startswith(diff+'.'):del r[k]
                    n=int(pv.get(f'pv_{pid}.difficulty.{diff}.length','0'));r[diff+'.length']=str(n)
                    for j in range(n):
                        r.update({f'{diff}.{j}.'+k:v for k,v in {'edition':str(j),'ver':'1','st_day':'1','st_month':'1','st_year':'2000','ed_day':'1','ed_month':'1','ed_year':'2099'}.items()})
                rows.append(r)
            d=setgroup(d,'pv_list',rows);d.pop('pv_list.length',None);d['pv_list.data_list.length']=str(len(rows));b=propbytes(d)
        blocks.append((name,b))
    write(p.relative_to(BASE),farc_write(blocks))
    manifest={'format':'pjdv-x-song-private-trial-v1','source':str(SRC),'overlay':str(OVER),'pv_ids':pv_ids,'object_id_map':objmap,'texture_id_map':texmap,'archive_changes':changes,'new_stages':[v for v in stages if v['mod']],'outputs':outputs,'x_charts_enabled':False,'x_charts_reason':'Requires New Classics console target/state/score implementation, not a vanilla FT script override','save_requires_isolation':True,'runtime_verified':False,'no_module_or_font_override':True}
    (WORK/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print('Profile ready',len(outputs),'files; X Charts remains disabled',flush=True)
if __name__=='__main__':main()
