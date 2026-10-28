"""One private model package -> inactive, reversible RomFS overlay trial.

No source asset is modified. Default Miku costume 0 is replaced only in the
generated test overlay. This is not the general-purpose MOD importer.
Classic database layouts checked against MikuMikuLibrary's format readers.
"""
import sys, os, re, json, struct, gzip, hashlib, shutil, collections
from pathlib import Path
from archive_reader import entries
from asset_check import objset, textures
WORK=Path(os.environ['PJDV_MOD_OUTPUT'])
SOURCE=Path(os.environ['PJDV_MOD_SOURCE'])
BASE=Path(os.environ['PJDV_MOD_BASE'])
DLC=Path(os.environ['PJDV_MOD_DLC'])
OVER=WORK/'overlay'
def u(b,o):return struct.unpack_from('<I',b,o)[0]
def z(b,o):return b[o:b.index(0,o)].decode('utf-8') if o else ''
def sha(b):return hashlib.sha256(b).hexdigest()
def tex_read(b):
    n,o=struct.unpack_from('<II',b);assert n<1000000 and o+n*8<=len(b)
    return [{'id':u(b,o+i*8),'name':z(b,u(b,o+i*8+4))} for i in range(n)]
def obj_read(b):
    n,mx,o,nn,mo=struct.unpack_from('<5I',b);assert n<65536 and o+n*36<=len(b) and mo+nn*8<=len(b)
    sets=[]
    for i in range(n):
        q=o+i*36
        sets.append({'name':z(b,u(b,q)),'id':u(b,q+4),'file':z(b,u(b,q+8)),'tex':z(b,u(b,q+12)),'archive':z(b,u(b,q+16)),'objects':[]})
    lookup={s['id']:s for s in sets};assert len(lookup)==n
    for i in range(nn):
        q=mo+i*8;oid,sid=struct.unpack_from('<HH',b,q)
        lookup[sid]['objects'].append({'id':oid,'name':z(b,u(b,q+4))})
    return sets
class Writer:
    def __init__(self,n):self.b=bytearray(n);self.strings={}
    def align(self,n=16):self.b.extend(b'\0'*((-len(self.b))%n));return len(self.b)
    def string(self,s):
        if not s:return 0
        if s not in self.strings:self.strings[s]=len(self.b);self.b.extend(s.encode()+b'\0')
        return self.strings[s]
    def put(self,o,*v):struct.pack_into('<'+'I'*len(v),self.b,o,*v)
def tex_write(a):
    w=Writer(16+len(a)*8);w.put(0,len(a),16)
    for i,t in enumerate(a):w.put(16+i*8,t['id'],w.string(t['name']))
    return bytes(w.b)
def obj_write(a):
    nn=sum(len(s['objects']) for s in a);so=32;mo=(so+len(a)*36+15)//16*16
    w=Writer(mo+nn*8);w.put(0,len(a),max(s['id'] for s in a),so,nn,mo)
    j=0
    for i,s in enumerate(a):
        w.put(so+i*36,w.string(s['name']),s['id'],w.string(s['file']),w.string(s['tex']),w.string(s['archive']),0,0,0,0)
        assert s['id']<65536
        for ob in s['objects']:
            struct.pack_into('<HHI',w.b,mo+j*8,ob['id'],s['id'],w.string(ob['name']));j+=1
    return bytes(w.b)
def farc_write(data):
    blocks=[(n,gzip.compress(b,compresslevel=6,mtime=0),len(b)) for n,b in data]
    hlen=12+sum(len(n.encode())+1+12 for n,_,_ in blocks)
    offset=(hlen+15)//16*16;head=b'FArC'+struct.pack('>II',hlen-8,16);body=bytearray()
    for n,b,size in blocks:
        head+=n.encode()+b'\0'+struct.pack('>III',offset,len(b),size)
        body.extend(b);pad=(-(offset+len(b)))%16;body.extend(b'\0'*pad);offset+=len(b)+pad
    return head+b'\0'*((hlen+15)//16*16-len(head))+body
def properties(b):return dict(l.split('=',1) for l in b.decode('utf-8-sig').splitlines() if '=' in l and not l.lstrip().startswith('#'))
def propbytes(d):return ('\n'.join(k+'='+v for k,v in sorted(d.items()))+'\n').encode()
def group(d,kind):
    out=collections.defaultdict(dict)
    for k,v in d.items():
        m=re.fullmatch(re.escape(kind)+r'\.(\d+)\.(.+)',k)
        if m:out[int(m[1])][m[2]]=v
    return list(dict(sorted(out.items())).values())
def setgroup(d,kind,rows):
    d={k:v for k,v in d.items() if not k.startswith(kind+'.')}
    for i,row in enumerate(rows):
        for k,v in row.items():d[f'{kind}.{i}.{k}']=v
    d[kind+'.length']=str(len(rows));return d
def write(rel,b):
    p=OVER/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);return {'path':str(p.relative_to(OVER)),'bytes':len(b),'sha256':sha(b)}
def main():
    assert (SOURCE/'rom/objset/mikitm6065.farc').is_file(), 'This profile supports Rage Winter 2020 Miku only'
    OVER.mkdir(exist_ok=True)
    base_obj_paths=list(BASE.glob('*/rom/objset/*obj_db.bin'))+list(DLC.glob('*/**/rom/objset/*obj_db.bin'))
    base_tex_paths=list(BASE.glob('*/rom/objset/*tex_db.bin'))+list(DLC.glob('*/**/rom/objset/*tex_db.bin'))
    all_objects=[s for p in base_obj_paths for s in obj_read(p.read_bytes())]
    all_tex=[t for p in base_tex_paths for t in tex_read(p.read_bytes())]
    pc_obj=obj_read((SOURCE/'rom/objset/mod_obj_db.bin').read_bytes());pc_tex=tex_read((SOURCE/'rom/objset/mod_tex_db.bin').read_bytes())
    existing_obj={s['id'] for s in all_objects};existing_tex={t['id'] for t in all_tex}
    objmap={s['id']:max(existing_obj)+1+i for i,s in enumerate(pc_obj)}
    texmap={t['id']:max(existing_tex)+1+i for i,t in enumerate(pc_tex)}
    assert not set(objmap.values())&existing_obj and not set(texmap.values())&existing_tex
    assert max(objmap.values())<65536
    original_obj=json.loads(json.dumps(pc_obj));original_tex=json.loads(json.dumps(pc_tex))
    for s in pc_obj:s['id']=objmap[s['id']]
    for t in pc_tex:t['id']=texmap[t['id']]
    outputs=[];changes=[]
    # Merge into each original DB variant without shadowing unrelated entries.
    for p in list(BASE.glob('*/rom/objset/obj_db.bin')):
        before=obj_read(p.read_bytes());merged=before+pc_obj;b=obj_write(merged);assert obj_read(b)==merged
        outputs.append(write(p.relative_to(BASE),b))
    for p in list(BASE.glob('*/rom/objset/tex_db.bin')):
        before=tex_read(p.read_bytes());merged=before+pc_tex;b=tex_write(merged);assert tex_read(b)==merged
        outputs.append(write(p.relative_to(BASE),b))
    # Retain geometry, materials, skin and textures byte-for-byte, apart from
    # the explicitly remapped texture-ID words in object sets/material slots.
    for p in sorted((SOURCE/'rom/objset').glob('*.farc')):
        data=[];allowed=set();source_objects={}
        for name,raw in entries(p):
            b=bytearray(raw);changed=[]
            if name.endswith('_obj.bin'):
                objset(raw);n=u(b,4);po=u(b,12);to=u(b,28);nt=u(b,32)
                positions=[to+i*4 for i in range(nt)]
                for i in range(n):
                    o=u(b,po+i*4);ma=o+u(b,o+36);nc=u(b,o+32)
                    positions.extend(ma+j*0x4b0+20+k*120+4 for j in range(nc) for k in range(8))
                for pos in positions:
                    old=u(b,pos)
                    if old in texmap:struct.pack_into('<I',b,pos,texmap[old]);changed.append(pos)
                allowed={j for q in changed for j in range(q,q+4)}
                assert all(x==y or i in allowed for i,(x,y) in enumerate(zip(raw,b)))
                objset(b)
            if name.endswith('_tex.bin'):textures(raw)
            data.append((name,bytes(b)));source_objects[name]=sha(bytes(b))
            changes.append({'archive':p.name,'entry':name,'changed_texture_id_words':len(changed),'bytes':len(b),'sha256':sha(bytes(b))})
        packed=farc_write(data);dst=OVER/'rom_switch/rom/objset'/p.name;outputs.append(write(dst.relative_to(OVER),packed))
        assert {n:sha(b) for n,b in entries(dst)}==source_objects
    # Bind the four PC parts to the isolated default costume, avoiding the
    # PC's high module/item identifiers in the unmodified guest save arrays.
    mod_chritm=dict(entries(SOURCE/'rom/mod_chritm_prop.farc'))
    pcprops=properties(mod_chritm['mikitm_tbl.txt']);pcitems=group(pcprops,'item')
    item_map=None
    for p in BASE.glob('*/rom/*chritm_prop.farc'):
        data=[]
        for name,b in entries(p):
            if name=='mikitm_tbl.txt':
                d=properties(b);rows=group(d,'item');used={int(v['no']) for v in rows};maximum=max(used)
                if item_map is None:
                    free=[i for i in range(1,maximum) if i not in used];assert len(free)>=len(pcitems)
                    item_map={int(v['no']):free[i] for i,v in enumerate(pcitems)}
                assert not set(item_map.values())&used
                newitems=json.loads(json.dumps(pcitems))
                for it in newitems:it['no']=str(item_map[int(it['no'])])
                d=setgroup(d,'item',rows+newitems)
                costumes=group(d,'cos');found=False
                for co in costumes:
                    if co['id']=='0':
                        co.clear();co.update({'id':'0','item.length':str(len(newitems))})
                        for i,it in enumerate(newitems):co[f'item.{i}']=it['no']
                        found=True
                assert found;d=setgroup(d,'cos',costumes);b=propbytes(d)
            data.append((name,b))
        outputs.append(write(p.relative_to(BASE),farc_write(data)))
    # Supply model-specific skin/physics and merge the osage lookup table.
    for rel in ('skin_param','osage_play_data'):
        for p in (SOURCE/'rom'/rel).glob('*'):
            if p.name.startswith('.') or not p.is_file() or p.name=='mod_osage_setting.txt':continue
            outputs.append(write(Path('rom_switch/rom')/rel/p.name,p.read_bytes()))
    p=BASE/'rom_switch/rom/skin_param/osage_setting.txt';d=properties(p.read_bytes());delta=properties((SOURCE/'rom/skin_param/mod_osage_setting.txt').read_bytes())
    for kind in ('cat','obj'):
        rows=group(d,kind);lookup={v['name']:i for i,v in enumerate(rows)}
        for row in group(delta,kind):
            if row['name'] in lookup:rows[lookup[row['name']]]=row
            else:lookup[row['name']]=len(rows);rows.append(row)
        d=setgroup(d,kind,rows)
    outputs.append(write(p.relative_to(BASE),propbytes(d)))
    manifest={'format':'pjdv-single-model-trial-v1','source':str(SOURCE),'overlay':str(OVER),'test_costume':{'character':'MIKU','id':0,'mode':'isolated default costume replacement, not additive registration'},'object_id_map':objmap,'texture_id_map':texmap,'item_id_map':item_map,'objects':pc_obj,'source_objects':original_obj,'source_textures':original_tex,'archive_changes':changes,'outputs':outputs,'base_db_inputs':[{'path':str(p),'sha256':sha(p.read_bytes())} for p in base_obj_paths+base_tex_paths],'only_one_package':True,'save_requires_isolation':True,'runtime_verified':False}
    (WORK/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print(json.dumps({'overlay':str(OVER),'objects':len(pc_obj),'textures':len(pc_tex),'outputs':len(outputs),'objmap':objmap,'texture_range':[min(texmap.values()),max(texmap.values())],'item_map':item_map},ensure_ascii=False))
if __name__=='__main__':main()
