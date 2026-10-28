"""Merge selected classic SPR sprites, preserving every original atlas entry.

Layout references: MikuMikuLibrary SpriteSet, Sprite and TextureSet readers.
Texture payloads use relative internal pointers and are copied unchanged.
"""
import struct

def read(b):
    sig,tx,nt,ns,so,tn,sn,mo=struct.unpack_from('<8I',b)
    assert sig==0 and 0<nt<256 and ns<65536
    for off,size in ((so,ns*40),(tn,nt*4),(sn,ns*4),(mo,ns*8)):
        assert 32<=off<=len(b)-size
    def names(off,n):
        out=[]
        for i in range(n):
            p=struct.unpack_from('<I',b,off+4*i)[0];assert 32<=p<len(b)
            out.append(b[p:b.index(0,p)].decode())
        return out
    assert struct.unpack_from('<2I',b,tx)==(0x03505854,nt)
    offsets=[tx+struct.unpack_from('<I',b,tx+12+4*i)[0] for i in range(nt)]
    end=min([v for v in (so,tn,sn,mo) if v>tx]+[len(b)])
    assert offsets==sorted(set(offsets)) and tx+12+4*nt<=offsets[0]<end
    bounds=offsets[1:]+[end]
    return dict(textures=[b[a:z] for a,z in zip(offsets,bounds)],texture_names=names(tn,nt),
                sprites=[b[so+40*i:so+40*(i+1)] for i in range(ns)],
                names=names(sn,ns),modes=[b[mo+8*i:mo+8*(i+1)] for i in range(ns)])

def write(d):
    b=bytearray(32)
    def append(raw,alignment=4):
        b.extend(b'\0'*((-len(b))%alignment));p=len(b);b.extend(raw);return p
    ns=len(d['sprites']);nt=len(d['textures'])
    so=append(b''.join(d['sprites']),16);mo=append(b''.join(d['modes']),16)
    def names(values):
        offsets=[append(s.encode()+b'\0',1) for s in values]
        return append(struct.pack('<'+'I'*len(offsets),*offsets))
    tn=names(d['texture_names']);sn=names(d['names'])
    tx=append(struct.pack('<3I',0x03505854,nt,nt|0x01010100)+b'\0'*(nt*4),16)
    for i,raw in enumerate(d['textures']):
        p=append(raw);struct.pack_into('<I',b,tx+12+i*4,p-tx)
    struct.pack_into('<8I',b,0,0,tx,nt,ns,so,tn,sn,mo)
    result=bytes(b);check=read(result)
    # Padding between TXP payloads is not semantically part of a texture.
    for key in ('texture_names','sprites','names','modes'):assert check[key]==d[key]
    for a,z in zip(d['textures'],check['textures']):assert z.startswith(a)
    return result

def merge(base,delta,sprite_names,texture_prefix):
    a=read(base);s=read(delta);old_count=len(a['sprites']);old_tex=len(a['textures'])
    assert not set(sprite_names)&set(a['names'])
    selected=[s['names'].index(name) for name in sprite_names];texmap={};sprmap={}
    for i in selected:
        row=bytearray(s['sprites'][i]);ti=struct.unpack_from('<I',row)[0]
        assert ti<len(s['textures'])
        if ti not in texmap:
            texmap[ti]=len(a['textures']);a['textures'].append(s['textures'][ti])
            a['texture_names'].append(texture_prefix+str(ti))
        struct.pack_into('<I',row,0,texmap[ti]);sprmap[i]=len(a['sprites'])
        a['sprites'].append(bytes(row));a['names'].append(s['names'][i]);a['modes'].append(s['modes'][i])
    packed=write(a);check=read(packed);original=read(base)
    for key in ('names','sprites','modes'):assert check[key][:old_count]==original[key]
    assert check['texture_names'][:old_tex]==original['texture_names']
    for i,t in enumerate(original['textures']):assert check['textures'][i].startswith(t)
    return packed,sprmap,texmap
