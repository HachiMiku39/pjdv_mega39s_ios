"""Bounded classic object/TXP validation used by local MOD conversion."""

import struct

def u32(b,o):
    if o<0 or o+4>len(b): raise ValueError('offset outside buffer')
    return struct.unpack_from('<I',b,o)[0]

def text(b,o,n=None):
    if o<0 or o>=len(b): raise ValueError('string outside buffer')
    return b[o:o+n].split(b'\0')[0].decode('utf-8','replace') if n else b[o:b.index(0,o)].decode('utf-8','replace')

def bound(b,o,n):
    if o<0 or n<0 or o+n>len(b): raise ValueError('range outside buffer')

def objset(b):
    if u32(b,0)!=0x5062500: raise ValueError('unsupported object-set signature')
    n=u32(b,4); a=u32(b,12); skins=u32(b,16); names=u32(b,20); ids=u32(b,24); tex=u32(b,28); nt=u32(b,32)
    if n>10000 or nt>100000: raise ValueError('count limit')
    bound(b,a,n*4); bound(b,tex,nt*4)
    result={'objects':[],'texture_ids':[u32(b,tex+i*4) for i in range(nt)],'bytes':len(b)}
    for i in range(n):
        o=u32(b,a+i*4); bound(b,o,40)
        nm=u32(b,o+24); mo=o+u32(b,o+28); nc=u32(b,o+32); ma=o+u32(b,o+36)
        if nm>10000 or nc>10000: raise ValueError('mesh/material limit')
        bound(b,mo,nm*0xd8); bound(b,ma,nc*0x4b0)
        ob={'name':text(b,u32(b,names+i*4)),'id':u32(b,ids+i*4),'skin':bool(u32(b,skins+i*4)),'meshes':[],'materials':[]}
        for j in range(nm):
            m=mo+j*0xd8
            ob['meshes'].append({'vertices':u32(b,m+36),'submeshes':u32(b,m+20),'vertex_flags':hex(u32(b,m+28)),'name':text(b,m+152,64)})
        for j in range(nc):
            m=ma+j*0x4b0
            slots=[]
            for k in range(8):
                q=m+20+k*120; typ=u32(b,q+8)&15
                if typ: slots.append({'type':typ,'texture_id':u32(b,q+4)})
            ob['materials'].append({'shader':text(b,m+8,8),'slots':slots})
        result['objects'].append(ob)
    return result

FMTS={0:'A8',1:'RGB8',2:'RGBA8',3:'RGB5',4:'RGB5A1',5:'RGBA4',6:'DXT1',7:'DXT1a',8:'DXT3',9:'DXT5',10:'ATI1',11:'ATI2',12:'L8',13:'L8A8',15:'BC7',127:'BC6H'}

def textures(b):
    if u32(b,0)!=0x03505854: raise ValueError('unsupported texture-set signature')
    n=u32(b,4)
    if n>10000: raise ValueError('texture count limit')
    bound(b,12,n*4); out=[]
    for i in range(n):
        p=u32(b,12+i*4); sig=u32(b,p); count=u32(b,p+4); info=u32(b,p+8)
        if sig not in (0x04505854,0x05505854) or count>1000: raise ValueError('texture header')
        bound(b,p+12,4*count); mip=[]
        for j in range(count):
            q=p+u32(b,p+12+j*4)
            if u32(b,q)!=0x02505854: raise ValueError('mip signature')
            w,h,fmt,idx,size=struct.unpack_from('<5I',b,q+4); bound(b,q+24,size)
            mip.append({'width':w,'height':h,'format':FMTS.get(fmt,str(fmt)),'bytes':size})
        out.append({'mips':info&255,'array':(info>>8)&255,'levels':mip})
    return out
