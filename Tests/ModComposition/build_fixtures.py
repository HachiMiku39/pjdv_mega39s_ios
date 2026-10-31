"""Synthetic classic FARC with a streamed 150 MiB zero texture; no game data."""
import struct,sys,zlib
from pathlib import Path
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
compressor=zlib.compressobj(6,zlib.DEFLATED,31)
blocks=[]
for _ in range(150*16):
    blocks.append(compressor.compress(bytes(65536)))
blocks.append(compressor.flush())
texture=b''.join(blocks)
obj=zlib.compressobj(6,zlib.DEFLATED,31)
small=obj.compress(b'object')+obj.flush()
entries=[('model_obj.bin',small,6),('model_tex.bin',texture,150*1024*1024)]
size=12+sum(len(n)+1+12 for n,_,_ in entries);offset=(size+15)//16*16
head=b'FArC'+struct.pack('>II',size-8,16);body=bytearray()
for name,data,expanded in entries:
    head+=name.encode()+b'\0'+struct.pack('>III',offset,len(data),expanded)
    body.extend(data);pad=(-(offset+len(data)))%16;body.extend(bytes(pad));offset+=len(data)+pad
(root/'opaque-large.farc').write_bytes(head+bytes((size+15)//16*16-len(head))+body)
print('Generated streamed synthetic texture fixture')
