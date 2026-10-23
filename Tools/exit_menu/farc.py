"""Read-only FARC inspection, format reference: MikuMikuLibrary/Archives/FarcArchive.cs."""
import struct,gzip,zlib
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
KEY=bytes.fromhex('1372d57b6e9e31eba239b83c1557c6bb')
def decrypt(raw,iv):
 d=Cipher(algorithms.AES(KEY),modes.CBC(iv)).decryptor();return d.update(raw[:len(raw)//16*16])+d.finalize()
def entries(path):
 b=Path(path).read_bytes();head=struct.unpack_from('>I',b,4)[0]+8
 if b[:4]==b'FARC':
  # The unencrypted counted-header variant is also used by Auth3D scenes.
  # Its packed and unpacked lengths can be equal: do not treat every nonzero
  # unpacked length as a gzip stream (the legacy FArC rule).
  h=decrypt(b[32:head],b[16:32]) if struct.unpack_from('>I',b,8)[0]&4 else b[16:head]
  hs,align,count,esize=struct.unpack_from('>4I',h);at=hs
  if hs<16 or esize<16 or count>100000:raise ValueError('Invalid counted FARC header')
  for k in range(count):
   end=h.index(0,at);name=h[at:end].decode();off,packed,size,flags=struct.unpack_from('>4I',h,end+1);at=end+1+esize
   block=b[off:off+((packed+15)//16*16)+16];raw=decrypt(block[16:],block[:16]) if flags&4 else block
   decoded=zlib.decompress(raw,31) if flags&2 and packed!=size else raw[:size]
   if len(decoded)!=size:raise ValueError('FARC entry length mismatch: '+name)
   yield name,decoded
 else:
  assert b[:4] in [b'FARC',b'FArC',b'FArc']
  at=12 if b[:4] in [b'FArC',b'FArc'] else 32
  while at<head:
   end=b.index(0,at);name=b[at:end].decode();
   if not name:break
   n=2 if b[:4]==b'FArc' else 3
   v=struct.unpack_from('>'+str(n)+'I',b,end+1);at=end+1+n*4
   raw=b[v[0]:v[0]+v[1]];yield name,zlib.decompress(raw,31) if n==3 and v[2] else raw
if __name__=='__main__':
 import sys
 out=Path('/Volumes/Switch-iOS-Dev/GameAnalysis/MEGA39-v1.0.9/MenuExit');out.mkdir(exist_ok=True)
 for name,raw in entries(sys.argv[1]):
  print(name,len(raw),raw[:32].hex());(out/name).write_bytes(raw)
