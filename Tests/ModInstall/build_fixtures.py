from pathlib import Path
import hashlib, json, random, struct, sys, zipfile

root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=False)
entries=[('Pack/config.toml',b'enabled = true\n'),('Pack/rom/objset/example.farc',b'synthetic asset\x00'*100)]
for name,method in [('stored',zipfile.ZIP_STORED),('deflated',zipfile.ZIP_DEFLATED)]:
    with zipfile.ZipFile(root/(name+'.zip'),'w',compression=method) as z:
        for path,data in entries:z.writestr(path,data)
        z.writestr('__MACOSX/._ignored',b'ignored metadata')
with zipfile.ZipFile(root/'chunk-boundary.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr(*entries[0])
    # Incompressible input forces inflate to request a new input block after
    # exactly filling the 64 KiB output buffer (Z_BUF_ERROR, not corruption).
    rng=random.Random(39)
    z.writestr('Pack/rom/objset/chunk.farc',rng.randbytes(4*1024*1024+4093))
base=(root/'stored.zip').read_bytes();cd=base.index(b'PK\x01\x02')
bad=bytearray(base);nl,el=struct.unpack_from('<HH',bad,26);bad[30+nl+el]^=1
(root/'bad-crc.zip').write_bytes(bad)
bad=bytearray(base);bad[30]^=1;(root/'local-name.zip').write_bytes(bad)
bad=bytearray(base);struct.pack_into('<I',bad,cd+24,1);(root/'declared-short.zip').write_bytes(bad)
# Reject a large declared expansion before creating a staging directory.
bad=bytearray(base);struct.pack_into('<I',bad,cd+24,0xffffffff)
# Use an explicit ZIP64 record for a 33 GiB synthetic entry; no huge payload.
h=bytearray(base[cd:cd+46]);nl,el,cl=struct.unpack_from('<HHH',h,28)
extra=struct.pack('<HHQ',1,8,33*1024**3)
struct.pack_into('<I',h,24,0xffffffff);struct.pack_into('<H',h,30,el+len(extra))
old_end=cd+46+nl+el+cl
bad=bytearray(base[:cd]+h+base[cd+46:cd+46+nl+el]+extra+base[cd+46+nl+el:])
eocd=bad.rindex(b'PK\x05\x06');size=struct.unpack_from('<I',bad,eocd+12)[0]
struct.pack_into('<I',bad,eocd+12,size+len(extra));(root/'too-large.zip').write_bytes(bad)
# A highly compressible 256 MiB member tests expansion without whole-file buffers.
with zipfile.ZipFile(root/'large.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr(*entries[0])
    with z.open('Pack/rom/objset/large.farc','w') as f:
        block=b'\x55'*65536
        for _ in range(4096):f.write(block)
folder=root/'FolderMod';(folder/'rom/objset').mkdir(parents=True)
(folder/'rom/objset/example.farc').write_bytes(entries[1][1])
hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*.zip')}
(root/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
