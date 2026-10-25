from pathlib import Path
import zipfile,struct,stat,json,hashlib,os,sys
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=False)
def make(name,entries):
 p=root/(name+'.zip')
 with zipfile.ZipFile(p,'w',compression=zipfile.ZIP_DEFLATED) as z:
  for path,text in entries:z.writestr(path,text)
 return p
valid=[('Pack/config.toml','enabled = true\ninclude = ["."]\n'),('Pack/rom/objset/example.farc','synthetic asset'),('Pack/rom/mod_pv_db.txt','synthetic database')]
make('plugin',valid)
make('layered',[('atmosphere/contents/0100F3100DA46000/romfs/rom_switch/rom/objset/example.farc','fixture')])
make('foreign',[('atmosphere/contents/01001CC00FA1A000/romfs/rom_switch/rom/objset/example.farc','fixture')])
make('steam',[('Pack/config.toml','enabled = true'),('Pack/rom_steam_en/rom/2d/example.farc','fixture')])
make('mixed',[('atmosphere/contents/0100F3100DA46000/exefs/subsdk9','not executable'),('atmosphere/contents/0100F3100DA46000/romfs/mods/Pack/rom/mod_pv_db.txt','fixture')])
make('code',[('Pack/config.toml','dll = ["test.dll"]'),('Pack/test.dll','not executable')])
make('unknown',[('README.txt','no assets')])
make('config-only',[('config.toml','enabled = true')])
make('deep-metadata', [('rom/n%04d/'%i+'/'.join('layer%d_'%j+'x'*35 for j in range(35))+'/asset.farc','') for i in range(1000)])
make('traversal',[('../rom/objset/example.farc','fixture')])
make('absolute',[('/rom/objset/example.farc','fixture')])
make('drive',[('C:/rom/objset/example.farc','fixture')])
make('case-parent',[('rom/objset/a.farc','one'),('rom/Objset/b.farc','two')])
make('file-directory',[('rom','file'),('rom/objset/a.farc','fixture')])
with zipfile.ZipFile(root/'symlink.zip','w') as z:
 info=zipfile.ZipInfo('rom/objset/link');info.create_system=3;info.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(info,'elsewhere')
base=(root/'plugin.zip').read_bytes();cd=base.index(b'PK\x01\x02');end=base.rindex(b'PK\x05\x06')
for name,offset,fmt,value in [('encrypted',cd+8,'<H',1),('split',end+4,'<H',1),('too-many',end+8,'<HH',None),('huge-directory',end+12,'<I',33*1024*1024),('odd-method',cd+10,'<H',12)]:
 b=bytearray(base)
 if name=='too-many':struct.pack_into(fmt,b,offset,50001,50001)
 else:struct.pack_into(fmt,b,offset,value)
 (root/(name+'.zip')).write_bytes(b)
(root/'truncated.zip').write_bytes(base[:-12]);(root/'notzip.zip').write_bytes(b'not a zip')
(root/'unsupported.7z').write_bytes(b'7z\xbc\xaf\x27\x1c')
# Small synthetic ZIP64 central directory with ZIP64 per-entry size/offset records.
records=[];at=cd;count=0
while at<end:
 h=bytearray(base[at:at+46]);nl,el,cl=struct.unpack_from('<HHH',h,28);compressed,expanded=struct.unpack_from('<II',h,20);local=struct.unpack_from('<I',h,42)[0]
 name=base[at+46:at+46+nl];extra=base[at+46+nl:at+46+nl+el];comment=base[at+46+nl+el:at+46+nl+el+cl]
 extra+=struct.pack('<HHQQQ',1,24,expanded,compressed,local)
 struct.pack_into('<II',h,20,0xffffffff,0xffffffff);struct.pack_into('<I',h,42,0xffffffff);struct.pack_into('<H',h,30,len(extra))
 records.append(bytes(h)+name+extra+comment);at+=46+nl+el+cl;count+=1
central=b''.join(records);zoff=cd+len(central)
z64=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,count,count,len(central),cd)
locator=struct.pack('<IIQI',0x07064b50,0,zoff,1);eocd=struct.pack('<IHHHHIIH',0x06054b50,0,0,0xffff,0xffff,0xffffffff,0xffffffff,0)
(root/'zip64.zip').write_bytes(base[:cd]+central+z64+locator+eocd)
folder=root/'FolderMod';(folder/'rom/objset').mkdir(parents=True);(folder/'config.toml').write_text('enabled = true');(folder/'rom/objset/example.farc').write_text('synthetic fixture')
(root/'EmptyFolder').mkdir();bad=root/'FolderLink';bad.mkdir();(bad/'rom').mkdir();(bad/'rom/link').symlink_to(folder/'rom/objset/example.farc')
(root/'RootLink').symlink_to(folder,target_is_directory=True)
# Deterministic malformed metadata mutations: bounded parsing must never trap.
fuzz=root/'Fuzz';fuzz.mkdir()
for i in range(150):
 b=bytearray(base);position=cd+(i*7919)%(len(base)-cd);b[position]^=(i%255)+1;(fuzz/f'{i:03d}.zip').write_bytes(b)
rows={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
(root/'source-hashes.json').write_text(json.dumps(rows,indent=2)+'\n')
print('Created synthetic fixtures only:',len(rows),'files')
