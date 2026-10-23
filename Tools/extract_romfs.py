"""Stream authenticated, update-merged RomFS files to a new external directory.

No intermediate decrypted NCA or whole-XCI copy. Resume skips only files whose
recorded SHA256 still matches. Changed destination files are preserved and the
run stops. Temporary files use new UUID names; existing data is not overwritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
import uuid
from romfs_reader import open_program_romfs

BLOCK = 1024 * 1024
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while b:=f.read(4*BLOCK):h.update(b)
    return h.hexdigest()

def extract(xci, keys, output, resume=False, rom_factory=None):
    with xci.open('rb') as source:
        rom=(rom_factory or open_program_romfs)(source,keys)
        fingerprint=hashlib.sha256(json.dumps(rom.entries,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        marker={'format':'pjdv-prepared-romfs-v1','index_sha256':fingerprint,'romfs_bytes':rom.reader.size}
        known={}
        if output.exists():
            if not resume or json.loads((output/'preparation.json').read_text())!=marker:
                raise ValueError('Output exists or does not match this preparation')
            for line in (output/'files.jsonl').read_text().splitlines():
                row=json.loads(line);known[row['path']]=row
        else:
            output.mkdir(parents=False,exist_ok=False)
            (output/'preparation.json').write_text(json.dumps(marker,indent=2)+'\n')
            (output/'files.jsonl').touch(exist_ok=False)
        total=sum(r['bytes'] for r in rom.entries);done=0;last=time.monotonic();started=last
        with (output/'files.jsonl').open('a') as journal:
            for n,row in enumerate(sorted(rom.entries,key=lambda x:x['offset'])):
                dst=output/row['path'];record=known.get(row['path'])
                if dst.exists():
                    if not record or not dst.is_file() or dst.stat().st_size!=row['bytes'] or sha(dst)!=record['sha256']:
                        raise ValueError('Existing destination file differs; preserved: '+row['path'])
                    done+=row['bytes'];continue
                dst.parent.mkdir(parents=True,exist_ok=True)
                temp=dst.parent/('.pjdv-stage-'+str(uuid.uuid4()))
                digest=hashlib.sha256()
                with temp.open('xb') as f:
                    for at in range(0,row['bytes'],BLOCK):
                        b=rom.reader.read(row['offset']+at,min(BLOCK,row['bytes']-at));f.write(b);digest.update(b)
                    f.flush();os.fsync(f.fileno())
                # Link refuses to overwrite even if another process created dst.
                os.link(temp,dst);temp.unlink()
                record={'path':row['path'],'bytes':row['bytes'],'sha256':digest.hexdigest()}
                journal.write(json.dumps(record,ensure_ascii=False)+'\n');journal.flush()
                done+=row['bytes']
                now=time.monotonic()
                if now-last>=10:
                    print(f'{n+1}/{len(rom.entries)} files • {done/1024**3:.2f}/{total/1024**3:.2f} GiB • {now-started:.0f}s',flush=True);last=now
        (output/'complete.json').write_text(json.dumps({'format':marker['format'],'file_count':len(rom.entries),'file_bytes':total,'index_sha256':fingerprint,'file_payload_integrity':'all_file_bytes_checked_through_IVFC','whole_virtual_image':'metadata_and_file_payloads; unused padding not fully traversed'},indent=2)+'\n')
        print(f'Prepared {len(rom.entries)} authenticated files, {total} bytes',flush=True)

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('xci',type=Path);ap.add_argument('output',type=Path);ap.add_argument('--keys',type=Path,required=True);ap.add_argument('--resume',action='store_true');a=ap.parse_args();extract(a.xci,a.keys,a.output,a.resume)
