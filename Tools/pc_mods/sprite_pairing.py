"""Compact PC sprite identifiers at documented DB/AET source fields only."""
import importlib.util,struct,json,copy
from pathlib import Path
import profile_x_song as x
OUT=x.WORK/'ui-candidate';OUT.mkdir(exist_ok=True)
def write(rel,b):
 p=OUT/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
all_base=[s for p in list(x.BASE.glob('*/rom/2d/*spr_db.bin'))+list(x.lib.DLC.glob('*/**/rom/2d/*spr_db.bin')) for s in x.db2_read(p.read_bytes())]
byid={s['id']:s for s in all_base};members={v['id']:v for s in all_base for v in s['members']}
sets=x.db2_read((x.SRC/'rom/2d/mod_spr_db.bin').read_bytes());setmap={};sprmap={};mi=max(byid);mm=max(members)
for s in sets:
 old=s['id']
 if old in byid:assert byid[old]['name']==s['name'];setmap[old]=old
 else:mi+=1;setmap[old]=mi
 for v in s['members']:
  old=v['id']
  if old in members:assert members[old]['name']==v['name'];sprmap[old]=old
  elif old not in sprmap:mm+=1;sprmap[old]=mm
assert mi<65536 and mm<65536
for s in sets:
 s['id']=setmap[s['id']]
 for v in s['members']:v['id']=sprmap[v['id']]
for p in list(x.BASE.glob('*/rom/2d/spr_db.bin'))+list(x.lib.DLC.glob('*/**/rom/2d/spr_db.bin')):
 a=x.merge_sets(x.db2_read(p.read_bytes()),copy.deepcopy(sets))
 if p.is_relative_to(x.BASE):rel=p.relative_to(x.BASE)
 else:
  parts=p.parts;start=parts.index('rom_switch_dlc');rel=Path(*parts[start:])
 write(rel,x.db2_write(a))
# The menu opens the language-specific shared thumbnail atlas, independently
# of per-song large covers. Pair every original language path with the same
# expanded sprite DB above; leaving CN/TW on the 262-member atlas drops MOD art.
thumbnail_paths=[]
for p in x.BASE.glob('*/rom/2d/spr_sel_pvtmb.farc'):
 rel=p.relative_to(x.BASE);write(rel,(x.SRC/'rom/2d/spr_sel_pvtmb.farc').read_bytes());thumbnail_paths.append(str(rel))
aets=[s for s in x.db2_read((x.SRC/'rom/2d/mod_aet_db.bin').read_bytes(),True) if (x.SRC/'rom/2d'/s['file']).is_file()]
for s in aets:
 assert s['sprite'] in setmap;s['sprite']=setmap[s['sprite']]
for p in x.BASE.glob('*/rom/2d/aet_db.bin'):write(p.relative_to(x.BASE),x.db2_write(x.merge_sets(x.db2_read(p.read_bytes(),True),copy.deepcopy(aets)),True))
changes=[]
for s in aets:
 p=x.SRC/'rom/2d'/s['file'];raw=p.read_bytes();b=bytearray(raw);allowed=set();count=0
 for i in range(len(b)//4):
  scene=x.u(b,i*4)
  if not scene:break
  assert scene+56<=len(b)
  nv=x.u(b,scene+40);vo=x.u(b,scene+44);assert vo+nv*20<=len(b)
  for j in range(nv):
   q=vo+j*20;ns=x.u(b,q+12);sp=x.u(b,q+16);assert sp+ns*8<=len(b)
   for k in range(ns):
    q=sp+k*8+4;old=x.u(b,q)
    assert old in sprmap or old==0xffffffff,(p.name,old)
    if old in sprmap:
     struct.pack_into('<I',b,q,sprmap[old]);allowed.update(range(q,q+4));count+=1
 assert all(a==c or i in allowed for i,(a,c) in enumerate(zip(raw,b)))
 write(Path('rom_switch/rom/2d')/p.name,bytes(b));changes.append({'file':p.name,'sprite_sources':count})
(x.WORK/'ui-candidate-manifest.json').write_text(json.dumps({'set_map':setmap,'sprite_map':sprmap,'set_range':[min(setmap.values()),max(setmap.values())],'sprite_range':[min(sprmap.values()),max(sprmap.values())],'aet_changes':changes,'thumbnail_atlases':thumbnail_paths,'status':'candidate, requires runtime verification'},ensure_ascii=False,indent=2))
print('Candidate:',len(sets),'sets',len(sprmap),'sprite IDs;',len(aets),'AET files;',sum(v['sprite_sources'] for v in changes),'source fields')
