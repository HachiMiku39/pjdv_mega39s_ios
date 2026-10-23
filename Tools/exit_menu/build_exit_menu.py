"""Build local-only eShop label overrides from the user's original game fonts.
Archive/sprite/font formats: MikuMikuLibrary and ReDIVA (read-only references).
No original file is changed; output contains only prepared local overrides.
"""
from pathlib import Path
import struct,gzip,json,hashlib,sys,argparse
from PIL import Image,ImageFilter
import numpy as np
from farc import entries
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--resources',type=Path,required=True,help='Prepared, decrypted original v1.0.9 RomFS root')
parser.add_argument('--output',type=Path,required=True,help='Local-only ExitMenu overlay folder')
parser.add_argument('--previews',type=Path,required=True,help='PNG preview folder')
args=parser.parse_args();R=args.resources;O=args.output;P=args.previews
assert R.is_dir() and R.resolve()!=O.resolve()
O.mkdir(parents=True,exist_ok=True);P.mkdir(parents=True,exist_ok=True)
def u32(b,o):return struct.unpack_from('<I',b,o)[0]
def one(p):
 e=list(entries(p));assert len(e)==1 and e[0][0];return e[0]
def textures(b):
 to=u32(b,4);ts=[]
 for k in range(u32(b,8)):
  t=to+u32(b,to+12+k*4);ps=[]
  for i in range(u32(b,t+4)):
   p=t+u32(b,t+12+i*4);sig,w,h,fmt,ident,size=struct.unpack_from('<6I',b,p);assert sig==0x02505854
   ps.append((p+24,w,h,fmt,size))
  ts.append(ps)
 return ts
FONTMAP=one(R/'rom_switch/rom/fontmap.farc')[1]
def glyphs(path,mid,text):
 _,b=one(R/path);p,w,h,fmt,size=textures(b)[0][0];assert fmt==9
 atlas=Image.frombytes('RGBA',(w,h),b[p:p+size],'bcn',3).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
 font=None
 for i in range(u32(FONTMAP,8)):
  off=u32(FONTMAP,32+4*i)
  if u32(FONTMAP,off)==mid:font=off;break
 assert font is not None
 gw,gh=FONTMAP[font+6:font+8];count,co=struct.unpack_from('<2I',FONTMAP,font+20)
 table={}
 for i in range(count):
  cid,half,pad,col,row,go,width=struct.unpack_from('<H6B',FONTMAP,co+8*i);table[cid]=(half,col,row,go,width)
 masks=[]
 for char in text:
  assert ord(char) in table,(mid,char)
  half,col,row,go,width=table[ord(char)];box=atlas.crop((col*gw,row*gh,col*gw+gw,row*gh+gh))
  # Use the original alpha/outline coverage and original proportional advance.
  advance=18 if half else 36
  crop=box.getchannel('A').crop((0,0,advance+2,gh));masks.append(crop)
 line=Image.new('L',(sum(i.width for i in masks),gh));x=0
 for mask in masks:line.paste(mask,(x,0));x+=mask.width
 box=line.getbbox();assert box;line=line.crop(box)
 scale=min(2.45,650/line.width,96/line.height)
 return line.resize((round(line.width*scale),round(line.height*scale)),Image.Resampling.LANCZOS)
def label(mask):
 # Match the original white glyph, teal outline and offset dark-teal shadow.
 canvas=Image.new('RGBA',(720,142),(0,0,0,0));coverage=Image.new('L',canvas.size)
 coverage.paste(mask,((720-mask.width)//2,(142-mask.height)//2))
 outline=coverage.filter(ImageFilter.MaxFilter(13));shadow=Image.new('L',canvas.size);shadow.paste(outline,(6,7))
 for color,m in [((0,82,80),shadow),((0,158,150),outline),((255,255,255),coverage)]:
  layer=Image.new('RGBA',canvas.size,(*color,0));layer.putalpha(m);canvas.alpha_composite(layer)
 return canvas

def bc4(blocks):
 # Encode the edited blocks only. Untouched compressed blocks are byte-identical.
 values=blocks.reshape(-1,16).astype(np.int16);hi=values.max(1);lo=values.min(1)
 pal=np.stack([hi,lo]+[((7-i)*hi+i*lo)//7 for i in range(1,7)],axis=1)
 ix=abs(values[:,:,None]-pal[:,None,:]).argmin(2).astype(np.uint64)
 bits=(ix << (np.arange(16,dtype=np.uint64)*3)).sum(1,dtype=np.uint64)
 out=np.zeros((len(values),8),dtype=np.uint8);out[:,0]=hi;out[:,1]=lo
 for k in range(6):out[:,2+k]=(bits>>(8*k))&255
 return out

def patch_plane(b,info,im,rectangle):
 p,w,h,fmt,size=info;assert fmt==11
 x0,y0,x1,y1=rectangle
 # Work in the asset's bottom-up storage order; align to complete BC5 blocks.
 x0=x0//4*4;x1=(x1+3)//4*4;y0=y0//4*4;y1=(y1+3)//4*4
 ar=np.asarray(im.transpose(Image.Transpose.FLIP_TOP_BOTTOM))[:,:,:2]
 sy0=h-y1;sy1=h-y0;ar=ar[sy0:sy1,x0:x1]
 bh,bw=ar.shape[0]//4,ar.shape[1]//4
 blocks=ar.reshape(bh,4,bw,4,2).transpose(0,2,1,3,4).reshape(-1,16,2)
 red=bc4(blocks[:,:,0]);green=bc4(blocks[:,:,1]);encoded=np.concatenate([red,green],axis=1).reshape(bh,bw,16)
 ranges=[]
 for row in range(bh):
  off=p+((sy0//4+row)*(w//4)+x0//4)*16
  b[off:off+bw*16]=encoded[row].tobytes();ranges.append((off,off+bw*16))
 return {'plane':p,'rect':[x0,y0,x1,y1],'bytes':bh*bw*16,'ranges':ranges}

def menu(raw,newlabel,inactive):
 b=bytearray(raw);count=u32(b,12);so=u32(b,16);sn=u32(b,24);found=[]
 for i in range(count):
  no=u32(b,sn+4*i);name=b[no:b.index(0,no)].decode()
  if name=='SELECTOR_ESHOP_TXT':found.append(i)
 assert len(found)==1;i=found[0]
 tex=u32(b,so+40*i);_,_,_,_,_,_,x,y,w,h=struct.unpack_from('<II8f',b,so+40*i)
 assert (int(w),int(h))==(910,142)
 planes=textures(b)[tex];assert len(planes)==2
 decoded=[]
 for info in planes:
  p,tw,th,fmt,size=info;assert fmt==11
  decoded.append(Image.frombytes('RGB',(tw,th),bytes(b[p:p+size]),'bcn',5).transpose(Image.Transpose.FLIP_TOP_BOTTOM))
 changes=[]
 for sprite_name,art in [('SELECTOR_ESHOP_TXT',newlabel),('SELECTOR_ESHOP',inactive)]:
  indices=[]
  for j in range(count):
   no=u32(b,sn+4*j);name=b[no:b.index(0,no)].decode()
   if name==sprite_name:indices.append(j)
  assert len(indices)==1;j=indices[0]
  texture,_,_,_,_,_,sx,sy,sw,sh=struct.unpack_from('<II8f',b,so+40*j)
  assert texture==tex and (int(sw)-190,int(sh))==art.size
  x0=int(sx)+190;y0=int(sy);rect=(x0,y0,x0+art.width,y0+art.height)
  a=np.asarray(art).astype(float);red,green,blue=a[:,:,0],a[:,:,1],a[:,:,2]
  yy=(16+.257*red+.504*green+.098*blue).clip(0,255).astype('uint8')
  cb=(128-.148*red-.291*green+.439*blue).clip(0,255).astype('uint8')
  cr=(128+.439*red-.368*green-.071*blue).clip(0,255).astype('uint8')
  ya=Image.fromarray(np.stack([yy,a[:,:,3].astype('uint8'),np.zeros_like(yy)],axis=2),'RGB')
  decoded[0].paste(ya,(x0,y0))
  chroma=Image.fromarray(np.stack([cb,cr,np.zeros_like(yy)],axis=2),'RGB').resize((art.width//2,art.height//2),Image.Resampling.BILINEAR)
  decoded[1].paste(chroma,(x0//2,y0//2))
  changes.extend([patch_plane(b,planes[0],decoded[0],rect),patch_plane(b,planes[1],decoded[1],tuple(v//2 for v in rect))])
 changed=changes
 # Every byte outside the eShop text's aligned BC5 blocks stays identical.
 ranges=sorted(r for plane in changed for r in plane.pop('ranges'));end=0
 for start,stop in ranges:assert b[end:start]==raw[end:start];end=stop
 assert b[end:]==raw[end:]
 return bytes(b),changed

def archive(name,data):
 zipped=gzip.compress(data,compresslevel=9,mtime=0);entry=name.encode()+b'\0';headerlen=12+len(entry)+12;offset=(headerlen+15)//16*16
 header=b'FArC'+struct.pack('>II',headerlen-8,16)+entry+struct.pack('>III',offset,len(zipped),len(data))
 return header+b'\0'*(offset-len(header))+zipped

configs={
 'cn':('退出游戏',18,'rom_switch/rom/2d/spr_fnt_bold36cn2.farc','rom_switch_cn','保存进度并退出游戏。'),
 'tw':('退出遊戲',16,'rom_switch_tw/rom/2d/spr_fnt_bold36cn.farc','rom_switch_tw','儲存進度並退出遊戲。'),
 'en':('Exit Game',15,'rom_ps4/rom/2d/spr_fnt_bold36.farc','rom_switch','Save progress and exit the game.'),
 'jp':('ゲーム終了',15,'rom_ps4/rom/2d/spr_fnt_bold36.farc','rom_switch','進行状況を保存してゲームを終了します。'),
 'kr':('게임 종료',19,'rom_switch/rom/2d/spr_fnt_bold36kr.farc','rom_switch','진행 상황을 저장하고 게임을 종료합니다.')}
manifest={'build_id':'179265bd41f7781dac979e77702011241b442ba1','entry':['SELECTOR_ESHOP_TXT','SELECTOR_ESHOP'],'description_id':190,'languages':{}}
for lang,(text,mid,font,variant,description) in configs.items():
 mask=glyphs(font,mid,text);art=label(mask);art.save(P/('exit-label-'+lang+'.png'))
 inactive=Image.new('RGBA',(638,144),(145,146,152,0))
 scale=min(1,72/mask.height,580/mask.width);small=mask.resize((round(mask.width*scale),round(mask.height*scale)),Image.Resampling.LANCZOS)
 coverage=Image.new('L',inactive.size);coverage.paste(small,((638-small.width)//2,(144-small.height)//2));inactive.putalpha(coverage)
 inactive.save(P/('exit-label-inactive-'+lang+'.png'))
 name,raw=one(R/variant/'rom/2d/spr_nswgam_menu.farc');patched,changes=menu(raw,art,inactive)
 dest=O/lang/variant/'rom/2d/spr_nswgam_menu.farc';dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(archive(name,patched))
 # Verify the full archive round trip, with no extra member or format drift.
 assert one(dest)==(name,patched)
 source=R/'rom_switch/rom/lang2'/lang/'str_array.bin';strings=bytearray(source.read_bytes());off=len(strings);strings+=description.encode()+b'\0';struct.pack_into('<I',strings,190*4,off)
 target=O/lang/'rom_switch/rom/lang2'/lang/'str_array.bin';target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(strings)
 manifest['languages'][lang]={'label':text,'archive':str(dest.relative_to(O/lang)),'source_sha256':hashlib.sha256((R/variant/'rom/2d/spr_nswgam_menu.farc').read_bytes()).hexdigest(),'overridden_blocks':changes}
 print(lang,text,dest.stat().st_size)
(O/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
