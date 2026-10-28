"""Electric Angel (Rin/Len arrange), PC v2.0.1 -> isolated Switch data overlay.

No executable code or author Switch asset is required. Database layouts reuse
the local X Song converter. This is deliberately a package-specific profile.
"""
import copy,json,struct
from pathlib import Path
import profile_x_song as x
from thumbnail_merge import merge as merge_thumbnail,read as read_thumbnail

def main():
    src=x.SRC/'rom';base=x.BASE;dlc=x.lib.DLC
    pv=x.properties((src/'mod_pv_db.txt').read_bytes())
    assert {k.split('.')[0] for k in pv}=={'pv_237'}
    def variants(pattern):return list(base.glob('*/rom/'+pattern))+list(dlc.glob('*/**/rom/'+pattern))
    def rel(p):
        if p.is_relative_to(base):return p.relative_to(base)
        at=p.parts.index('rom_switch_dlc');return Path(*p.parts[at:])
    # Compact UID table avoids millions of unused slots. Stage object IDs are
    # already compatible: confirmed against the author's Switch metadata.
    auth=x.properties((src/'auth_3d/mod_auth_3d_db.bin').read_bytes())
    delta=x.group(auth,'uid');auth_paths=variants('auth_3d/*auth_3d_db.bin')
    start=max(len(x.group(x.properties(p.read_bytes()),'uid')) for p in auth_paths)
    uidmap={int(v['org_uid']):start+i for i,v in enumerate(delta)}
    for p in variants('auth_3d/auth_3d_db.bin'):
        d=x.properties(p.read_bytes());rows=x.group(d,'uid');cats=x.group(d,'category')
        seen={v['value'] for v in cats};cats.extend(v for v in x.group(auth,'category') if v['value'] not in seen)
        rows.extend({'value':'D PJDV_UNUSED_'+str(i)} for i in range(len(rows),start+len(delta)))
        for v in delta:rows[uidmap[int(v['org_uid'])]]={k:z for k,z in v.items() if k!='org_uid'}
        d=x.setgroup(x.setgroup(d,'uid',rows),'category',cats);d['uid.max']=str(len(rows)-1)
        x.write(rel(p),b'#A3DA__________\n'+x.propbytes(d))
    stage=bytearray((src/'mod_stage_data.bin').read_bytes());n,so,eo,co,ao=struct.unpack_from('<5I',stage)
    assert n==1
    # The PC registration slot 246 already names another Switch stage. Keep
    # the named stage/payload intact and allocate one new registry slot.
    stage_paths=variants('stage_data.bin');used_stage_ids=set();used_stage_names=set()
    for p in stage_paths:
        b=p.read_bytes();bn,bs,_,_,ba=struct.unpack_from('<5I',b)
        used_stage_ids.update(x.u(b,ba+i*8) for i in range(bn))
        used_stage_names.update(x.z(b,x.u(b,bs+i*112)) for i in range(bn))
    assert x.z(stage,x.u(stage,so)) not in used_stage_names
    old_stage_id=x.u(stage,ao);new_stage_id=max(used_stage_ids)+1
    struct.pack_into('<I',stage,ao,new_stage_id)
    for i in range(n):
        count=x.u(stage,co+i*4);ap=x.u(stage,ao+i*8+4);assert ap+count*4<=len(stage)
        for j in range(count):
            q=ap+j*4;old=x.u(stage,q)
            if old in uidmap:struct.pack_into('<I',stage,q,uidmap[old])
            else:assert old==0xffffffff
    objids={s['id'] for p in variants('objset/*obj_db.bin') for s in x.obj_read(p.read_bytes())}
    assert x.u(stage,so+8) in objids
    for p in stage_paths:
        packed,stages=x.stage_merge(p.read_bytes(),stage,{i:i for i in objids},{})
        x.write(rel(p),packed)
    # Register only the two actual cover/HUD sets, retaining original entries.
    raw_sets=x.db2_read((src/'2d/mod_spr_db.bin').read_bytes())
    shared=next(s for s in raw_sets if s['name']=='SPR_SEL_PVTMB')
    new_sets=[s for s in raw_sets if s is not shared]
    allsets=[s for p in variants('2d/*spr_db.bin') for s in x.db2_read(p.read_bytes())]
    maxset=max(s['id'] for s in allsets);maxmember=max(v['id'] for s in allsets for v in s['members'])
    setmap={shared['id']:shared['id']};sprmap={}
    for s in new_sets:
        old=s['id'];maxset+=1;setmap[old]=maxset;s['id']=maxset
        for v in s['members']:
            old=v['id'];maxmember+=1;sprmap[old]=maxmember;v['id']=maxmember
    newthumb=next(v for v in shared['members'] if v['name']=='SPR_SEL_PVTMB_237')
    old_atlas=dict(x.entries(base/'rom_switch/rom/2d/spr_sel_pvtmb.farc'))['spr_sel_pvtmb.bin']
    mod_atlas=dict(x.entries(src/'2d/spr_sel_pvtmb.farc'))['spr_sel_pvtmb.bin']
    assert read_thumbnail(mod_atlas)['names'][newthumb['index']]=='237'
    atlas,si,ti=merge_thumbnail(old_atlas,mod_atlas,['237'],'SPRTEX_SEL_PVTMB_PJDV237_')
    additions=[];maxmember+=1;sprmap[newthumb['id']]=maxmember
    v=copy.deepcopy(newthumb);v.update(id=maxmember,index=si[v['index']]);additions.append(v)
    for old,new in ti.items():
        v=copy.deepcopy(next(v for v in shared['members'] if v['texture'] and v['index']==old))
        old_id=v['id'];maxmember+=1;sprmap[old_id]=maxmember
        v.update(id=maxmember,index=new,name='SPRTEX_SEL_PVTMB_PJDV237_'+str(old));additions.append(v)
    assert maxset<65536 and maxmember<65536
    original_shared=next(s for s in x.db2_read((base/'rom_switch/rom/2d/spr_db.bin').read_bytes()) if s['name']=='SPR_SEL_PVTMB')
    for p in variants('2d/spr_db.bin'):
        rows=x.db2_read(p.read_bytes());target=next((s for s in rows if s['name']=='SPR_SEL_PVTMB'),None)
        if target is None:
            target=copy.deepcopy(original_shared);rows.append(target)
        assert max(v['index'] for v in target['members'] if not v['texture'])<len(read_thumbnail(old_atlas)['sprites'])
        assert not {v['id'] for s in rows for v in s['members']}&{v['id'] for v in additions}
        target['members'].extend(copy.deepcopy(additions));rows=x.merge_sets(rows,copy.deepcopy(new_sets))
        x.write(rel(p),x.db2_write(rows))
    for p in base.glob('*/rom/2d/spr_sel_pvtmb.farc'):
        assert dict(x.entries(p))['spr_sel_pvtmb.bin']==old_atlas
        x.write(rel(p),x.farc_write([('spr_sel_pvtmb.bin',atlas)]))
    # AET embeds sprite IDs in VideoSource records, never patch arbitrary words.
    aets=x.db2_read((src/'2d/mod_aet_db.bin').read_bytes(),True);patched_aet={}
    for s in aets:
        s['sprite']=setmap[s['sprite']];raw=(src/'2d'/s['file']).read_bytes();b=bytearray(raw)
        for i in range(len(b)//4):
            scene=x.u(b,i*4)
            if not scene:break
            assert scene+56<=len(b);nv=x.u(b,scene+40);vo=x.u(b,scene+44);assert vo+nv*20<=len(b)
            for j in range(nv):
                q=vo+j*20;ns=x.u(b,q+12);sp=x.u(b,q+16);assert sp+ns*8<=len(b)
                for k in range(ns):
                    q=sp+k*8+4;old=x.u(b,q)
                    assert old in sprmap or old==0xffffffff
                    if old in sprmap:struct.pack_into('<I',b,q,sprmap[old])
        patched_aet[s['file']]=bytes(b)
    for p in variants('2d/aet_db.bin'):
        x.write(rel(p),x.db2_write(x.merge_sets(x.db2_read(p.read_bytes(),True),copy.deepcopy(aets)),True))
    md,bones=x.mot_read(dict(x.entries(src/'rob/mod_mot_db.farc'))['mot_db.bin'])
    for p in variants('rob/mot_db.farc'):
        blocks=[]
        for name,b in x.entries(p):
            if name=='mot_db.bin':
                before,bb=x.mot_read(b);assert bb==bones
                b=x.mot_write(x.merge_sets(before,copy.deepcopy(md)),bb)
            blocks.append((name,b))
        x.write(rel(p),x.farc_write(blocks))
    for p in variants('pv_db.txt'):
        d=x.properties(p.read_bytes());assert not set(d)&set(pv),'PV237 already registered'
        d.update(pv);x.write(rel(p),x.propbytes(d))
    # The list table resides on the PS4 compatibility mount in this game build.
    p=base/'rom_ps4/rom/gm_pv_list_tbl.farc';blocks=[]
    for name,b in x.entries(p):
        if name=='gm_pv_list.bin':
            d=x.properties(b);rows=x.group(d,'pv_list');r=copy.deepcopy(next(v for v in rows if v['id']=='2'))
            assert not any(v['id']=='237' for v in rows)
            r.update(id='237',name=pv['pv_237.song_name'],ignore='0')
            for diff in ('easy','normal','hard','extreme','encore'):
                for k in list(r):
                    if k.startswith(diff+'.'):del r[k]
                n=int(pv.get('pv_237.difficulty.'+diff+'.length','0'));r[diff+'.length']=str(n)
                for j in range(n):
                    r.update({f'{diff}.{j}.'+k:v for k,v in dict(edition=str(j),ver='1',st_day='1',st_month='1',st_year='2000',ed_day='1',ed_month='1',ed_year='2099').items()})
            rows.append(r);d=x.setgroup(d,'pv_list',rows);d.pop('pv_list.length',None);d['pv_list.data_list.length']=str(len(rows));b=x.propbytes(d)
        blocks.append((name,b))
    x.write(rel(p),x.farc_write(blocks))
    for p in sorted(src.rglob('*')):
        if not p.is_file() or p.name.startswith(('.', 'mod_')):continue
        part=p.relative_to(src)
        if str(part)=='2d/spr_sel_pvtmb.farc':continue
        x.write(Path('rom_switch/rom')/part,patched_aet.get(p.name,p.read_bytes()))
    manifest=dict(format='pjdv-electric-angel-private-trial-v1',pv_ids=[237],auth_uid_map=uidmap,
                  stage_registration_map={old_stage_id:new_stage_id},
                  sprite_set_map=setmap,sprite_map=sprmap,thumbnail_original_sprites=258,
                  source_url='https://gamebanana.com/mods/417011',outputs=x.outputs,
                  only_one_package=True,save_requires_isolation=True,runtime_verified=False)
    (x.WORK/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print('Electric Angel candidate:',len(x.outputs),'files; Auth3D',uidmap,'; all original thumbnails retained')
