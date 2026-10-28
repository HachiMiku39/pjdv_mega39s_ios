"""Pair the pack's already supplied Chinese glyph maps with their atlases.

Only maps 15/17 are replaced; all Switch language-specific maps stay intact.
No external/system font is bundled and original files are never modified.
"""
import importlib.util,struct,json
from pathlib import Path
import profile_x_song as x
OUT=x.WORK/'ui-candidate'
def maps(b):
 return {x.u(b,o):o for i in range(x.u(b,8)) for o in [x.u(b,x.u(b,12)+i*4)]}
pc=next(x.entries(x.SRC/'rom/fontmap.farc'))[1];pm=maps(pc)
needed={ord(c) for k,v in x.properties((x.SRC/'rom/mod_pv_db.txt').read_bytes()).items() if any(t in k for t in ['song_name','lyric.','songinfo']) for c in v}
changed=[]
for p in x.BASE.glob('*/rom/fontmap.farc'):
 es=[]
 for name,raw in x.entries(p):
  b=bytearray(raw);bm=maps(b)
  for mid in [15,17]:
   if mid not in bm:continue
   po=pm[mid];no=bm[mid];count,co=struct.unpack_from('<2I',pc,po+20)
   chars=pc[co:co+count*8];ids={struct.unpack_from('<H',chars,j*8)[0] for j in range(count)}
   assert not needed-ids
   # Same advances/cell geometry: retain original placement and line spacing.
   assert pc[po+4:po+16]==raw[no+4:no+16]
   # Supplied atlases are wider; the paired table's column count must follow.
   struct.pack_into('<I',b,no+16,x.u(pc,po+16))
   b.extend(b'\0'*((-len(b))%16));newco=len(b);b.extend(chars)
   struct.pack_into('<2I',b,no+20,count,newco);changed.append({'file':str(p.relative_to(x.BASE)),'font_map':mid,'glyphs':count,'missing_song_characters':0})
  es.append((name,bytes(b)))
 dst=OUT/p.relative_to(x.BASE);dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(x.farc_write(es))
for name in ['spr_fnt_36.farc','spr_fnt_bold36.farc']:
 p=x.SRC/'rom/2d'/name;dst=OUT/'rom_switch/rom/2d'/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(p.read_bytes())
(x.WORK/'font-candidate-manifest.json').write_text(json.dumps({'source':'font assets already supplied by X Song Pack','external_font_bundled':False,'required_characters':len(needed),'maps':changed,'status':'candidate, requires runtime verification'},ensure_ascii=False,indent=2))
print('Paired atlas/maps:',changed)
