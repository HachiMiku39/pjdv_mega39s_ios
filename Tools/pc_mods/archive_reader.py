"""Size-limited FARC reader for offline, single-package conversion.

Reuses the existing project's format decryption helper, not user prod.keys.
Archive entry names remain data; this reader never extracts them as paths.
"""
import struct,sys,zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'exit_menu'))
from farc import decrypt
MAX_ARCHIVE=128*1024*1024
MAX_ENTRY=256*1024*1024
MAX_TOTAL=384*1024*1024
def entries(path):
    path=Path(path)
    if path.stat().st_size>MAX_ARCHIVE:raise ValueError('FARC archive exceeds conversion limit')
    b=path.read_bytes()
    if len(b)<16:raise ValueError('Truncated FARC')
    head=struct.unpack_from('>I',b,4)[0]+8
    if not 12<=head<=min(len(b),16*1024*1024):raise ValueError('Invalid FARC header')
    total=0
    def decode(raw,size,compressed):
        nonlocal total
        if size>MAX_ENTRY or total+size>MAX_TOTAL:raise ValueError('FARC expansion exceeds conversion limit')
        if compressed:
            d=zlib.decompressobj(31);result=d.decompress(raw,size+1)
            if len(result)!=size or not d.eof:raise ValueError('FARC compressed length mismatch')
        else:
            result=raw[:size]
            if len(result)!=size:raise ValueError('FARC payload length mismatch')
        total+=size;return result
    if b[:4]==b'FARC':
        h=decrypt(b[32:head],b[16:32]) if struct.unpack_from('>I',b,8)[0]&4 else b[16:head]
        hs,align,count,esize=struct.unpack_from('>4I',h);at=hs
        if hs<16 or esize<16 or count>100000:raise ValueError('Invalid counted FARC header')
        for _ in range(count):
            end=h.index(0,at);name=h[at:end].decode()
            off,packed,size,flags=struct.unpack_from('>4I',h,end+1);at=end+1+esize
            # The counted encrypted variant includes its IV in packed size.
            n=(packed+15)//16*16 if flags&4 else packed
            if off>len(b) or n>len(b)-off:raise ValueError('FARC payload outside archive')
            block=b[off:off+n];raw=decrypt(block[16:],block[:16]) if flags&4 else block
            yield name,decode(raw,size,bool(flags&2 and packed!=size))
    elif b[:4] in [b'FArC',b'FArc']:
        at=12;n=2 if b[:4]==b'FArc' else 3
        while at<head:
            end=b.index(0,at);name=b[at:end].decode()
            if not name:break
            v=struct.unpack_from('>'+str(n)+'I',b,end+1);at=end+1+n*4
            off,packed=v[:2];size=v[2] if n==3 and v[2] else packed
            if off>len(b) or packed>len(b)-off:raise ValueError('FARC payload outside archive')
            yield name,decode(b[off:off+packed],size,bool(n==3 and v[2]))
    else:raise ValueError('Unsupported FARC signature')
