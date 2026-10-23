"""Generate coordinate/hash recipes from user-supplied M39 resources.
Output contains no artwork, game strings or keys. Runtime edits host texture
copies only; the original archives, save and input mapping remain untouched.
"""
from pathlib import Path
import struct,sys,json,hashlib,argparse
import numpy as np
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'exit_menu'))
from farc import entries
p=argparse.ArgumentParser();p.add_argument('--resources',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);args=p.parse_args()

def u(b,o):return struct.unpack_from('<I',b,o)[0]
def fnv(b):
 h=1469598103934665603
 for v in b:h=((h^v)*1099511628211)&0xffffffffffffffff
 return f'{h:016x}'
def sample(b):
 n=len(b)//16;return fnv(b''.join(b[((n-1)*i//31)*16:((n-1)*i//31)*16+16] for i in range(32)))
def parse(path):
 a=list(entries(path));assert len(a)==1
 b=a[0][1];to=u(b,4);tex=[]
 for k in range(u(b,8)):
  t=to+u(b,to+12+k*4);mm=[]
  for i in range(u(b,t+4)):
   at=t+u(b,t+12+i*4);sig,w,h,fmt,ident,n=struct.unpack_from('<6I',b,at);assert sig==0x02505854
   mm.append((w,h,fmt,b[at+24:at+24+n]))
  tex.append(mm)
 so,sn=u(b,16),u(b,24);sprites={}
 for i in range(u(b,12)):
  at=u(b,sn+4*i);name=b[at:b.index(0,at)].decode();v=struct.unpack_from('<II8f',b,so+i*40)
  sprites[name]={'tex':v[0],'rect':list(map(round,v[6:]))}
 return tex,sprites

def decode(t):
 w,h,f,b=t
 if f==11:
  a=np.asarray(Image.frombytes('RGB',(w,h),b,'bcn',5).transpose(Image.Transpose.FLIP_TOP_BOTTOM));return Image.fromarray(np.stack([a[:,:,0]]*3+[a[:,:,1]],axis=-1),'RGBA')
 if f==9:return Image.frombytes('RGBA',(w,h),b,'bcn',3).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
 if f==2:return Image.frombytes('RGBA',(w,h),b).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
 raise ValueError(f)
def comps(mask):
 work=mask.copy();H,W=work.shape;out=[]
 for y,x in zip(*np.nonzero(work)):
  if not work[y,x]:continue
  work[y,x]=False;stack=[(int(y),int(x))];x0=x1=int(x);y0=y1=int(y);n=0
  while stack:
   cy,cx=stack.pop();n+=1;x0=min(x0,cx);x1=max(x1,cx);y0=min(y0,cy);y1=max(y1,cy)
   for yy,xx in ((cy-1,cx),(cy+1,cx),(cy,cx-1),(cy,cx+1)):
    if 0<=yy<H and 0<=xx<W and work[yy,xx]:work[yy,xx]=False;stack.append((yy,xx))
  w=x1-x0+1;h=y1-y0+1
  if 25<=w<=56 and .94<=w/h<=1.06 and .72<n/(w*h)<.84:out.append([x0,y0,w,h])
 return out
# Exact original footer samples: KEY_MODULE_01 has +,Y,X,A,B in this order.
ct,cs=parse(args.resources/'rom_switch/rom/2d/spr_nswgam_custom.farc')
s=cs['KEY_MODULE_01'];im=decode(ct[s['tex']][0]);x,y,w,h=s['rect'];row=im.crop((x,y,x+w,y+h));ca=[r for r in comps(np.asarray(row)[:,:,3]>90) if r[2]>=36 and r[3]>=36];assert len(ca)==5,ca
canonical={}
for ch,r in zip('+YXAB',sorted(ca)):
 rx,ry,rw,rh=r;canonical[ch]=np.asarray(row.crop((rx,ry,rx+rw,ry+rh)).resize((40,40)))[:,:,0].astype(float)

def classify(image,r):
 x,y,w,h=r;a=np.asarray(image.crop((x,y,x+w,y+h)).resize((40,40)))[:,:,0].astype(float)
 scores=sorted((float(np.mean((a[6:34,6:34]-v[6:34,6:34])**2)),k) for k,v in canonical.items())
 return scores[0][1] if scores[0][0]<650 and scores[1][0]>scores[0][0]+300 else None,scores[0][0]

atlases={};evidence=[];skips=[]
def atlas(t):
 w,h,f,b=t
 if f not in (2,9,11):raise ValueError(f)
 key=hashlib.sha256(b).hexdigest()
 if key not in atlases:atlases[key]={'width':w,'height':h,'format':{2:0x25,9:0x44,11:0x4b}[f],'sample':sample(b),'sha256':key,'edits':[],'sources':[]}
 return key

def add_edit(tt,dt,rect,source=None,srect=None,footer=None,xbox=None,ps=None,xboxHue=None):
 key=atlas(tt[dt][0]);e={'rect':rect}
 if footer:e['footer']=footer
 else:
  for family,src in [('xbox',xbox),('ps',ps)]:
   if src is None:continue
   st,sr=src;skey=atlas(tt[st][0]);e[family]={'atlas':skey,'rect':sr}
   if family=='xbox' and xboxHue is not None:e[family]['hueRotation']=xboxHue
   # Crops are captured from immutable original guest textures at registration.
   if sr not in atlases[skey]['sources']:atlases[skey]['sources'].append(sr)
 if e not in atlases[key]['edits']:atlases[key]['edits'].append(e)

for variant in ['rom_switch','rom_switch_cn','rom_switch_tw','rom_ps4']:
 folder=args.resources/variant/'rom/2d'
 paths=sorted(folder.glob('spr_nswgam_*.farc'))
 if variant=='rom_switch':paths.append(folder/'spr_gam_cmn.farc')
 for path in paths:
  try:tt,ss=parse(path)
  except (ValueError,AssertionError,IndexError,struct.error):continue
  before=sum(len(a['edits']) for a in atlases.values());decoded={}
  if path.stem=='spr_nswgam_custom':
   # Four physical positions, including the built-in PS preview. Directional
   # arrows and all PS glyph source sprites are deliberately left unchanged.
   ns={'X':14,'Y':15,'B':16,'A':17};xb={'X':'Y','Y':'X','B':'A','A':'B'};ps={'X':2,'Y':3,'B':4,'A':5}
   for ch,n in ns.items():
    d=ss[f'CONFIG_ICON_{n:02d}'];sx=ss[f'CONFIG_ICON_{ns[xb[ch]]:02d}'];sp=ss[f'CONFIG_ICON_{ps[ch]:02d}']
    add_edit(tt,d['tex'],d['rect'],xbox=(sx['tex'],sx['rect']),ps=(sp['tex'],sp['rect']),xboxHue={'A':-46,'B':144,'X':-112,'Y':14}[ch])
   # The melody selector uses precomposed STARTSETTING strips, rather than
   # CONFIG_ICON sprites. Patch only letter cells; keep the built-in PS/arrow
   # strips and all directional cells intact.
   for index,sequence in enumerate(['--BA','X--A','-YB-','XYBA'],1):
    strip=ss[f'STARTSETTING_{index:02d}'];x,y,w,h=strip['rect']
    for cell,ch in enumerate(sequence):
     if ch=='-':continue
     sx=ss[f'CONFIG_ICON_{ns[xb[ch]]:02d}'];sp=ss[f'CONFIG_ICON_{ps[ch]:02d}']
     add_edit(tt,strip['tex'],[x+cell*64,y,min(60,w-cell*64),h],xbox=(sx['tex'],sx['rect']),ps=(sp['tex'],sp['rect']),xboxHue={'A':-46,'B':144,'X':-112,'Y':14}[ch])
   for ch,n in {'X':5,'Y':6,'B':7,'A':8}.items():
    d=ss[f'CONFIG_CTRL_BTN_{n:02d}'];add_edit(tt,d['tex'],d['rect'],footer=ch)
  if path.stem=='spr_gam_cmn':
   for name,d in ss.items():
    # Only explicit face-button tokens. BTN_B/TGT_B mean other shape families.
    token=next((k for k in ['ABTN','BBTN','XBTN','YBTN'] if k in name),None)
    if token:
     ch=token[0];xn=name.replace(token,{'A':'BBTN','B':'ABTN','X':'YBTN','Y':'XBTN'}[ch]);pn=name.replace(token,{'A':'MARU','B':'BATSU','X':'SANKAKU','Y':'SHIKAKU'}[ch])
    elif name in {f'BTN_{c}_{st}' for c in 'ABXY' for st in ['ON','OFF']}:
     ch=name[4];xn=name[:4]+{'A':'B','B':'A','X':'Y','Y':'X'}[ch]+name[5:];pn=name[:4]+{'A':'MARU','B':'BATSU','X':'SANKAKU','Y':'SHIKAKU'}[ch]+name[5:]
    else:continue
    sx=ss.get(xn);sp=ss.get(pn)
    add_edit(tt,d['tex'],d['rect'],xbox=(sx['tex'],sx['rect']) if sx else None,ps=(sp['tex'],sp['rect']) if sp else None,xboxHue={'A':-46,'B':144,'X':-112,'Y':14}[ch])
  for name,s in ss.items():
   if not name.startswith('KEY_'):continue
   t=s['tex'];x,y,w,h=s['rect']
   if w<100 or h>128 or tt[t][0][2]!=11:continue
   if t not in decoded:decoded[t]=decode(tt[t][0])
   row=decoded[t].crop((x,y,x+w,y+h))
   for r in comps(np.asarray(row)[:,:,3]>90):
    ch,score=classify(row,r)
    if ch in 'ABXY' if ch else False:
     rx,ry,rw,rh=r;rr=[x+rx-1,y+ry-1,rw+2,rh+2];add_edit(tt,t,rr,footer=ch);evidence.append({'archive':str(path.relative_to(args.resources)),'sprite':name,'rect':rr,'letter':ch,'score':round(score,2)})
    elif ch is None:skips.append({'archive':str(path.relative_to(args.resources)),'sprite':name,'rect':r,'score':round(score,2)})
  delta=sum(len(a['edits']) for a in atlases.values())-before
  if delta:print(path.relative_to(args.resources),delta,flush=True)
# Keep source-only atlases too; they supply cross-atlas shapes from the original game.
result={'version':1,'gameBuild':'179265bd41f7781dac979e77702011241b442ba1','atlases':list(atlases.values())}
args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,separators=(',',':')))
args.evidence.write_text(json.dumps({'footers':evidence,'unclassified':skips,'atlasCount':len(atlases),'edits':sum(len(a['edits']) for a in atlases.values())},indent=2))
print('atlases',len(atlases),'edits',sum(len(a['edits']) for a in atlases.values()),'footer glyphs',len(evidence),'unclassified',len(skips))
