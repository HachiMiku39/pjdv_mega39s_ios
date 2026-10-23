"""Prepare authenticated DLC data from local content metadata, without XCI copies."""
import argparse,json
from pathlib import Path
from extract_romfs import extract
from romfs_reader import PlainSection,IntegritySection,RomFS
from nca_reader import Archive,load_keys
from inspect_xci import inspect

def prepare(xci,keys,analysis,output,resume=False):
    metadata=json.loads(analysis.read_text())['content_metadata']
    rows=[]
    for row in metadata:
        if row['meta_type']!=130:continue
        title=int(row['title_id'],16);index=title-0x0100F3100DA47000
        if not 1<=index<=0xfff:raise ValueError('Unexpected DLC title')
        contents=[c for c in row['contents'] if c['content_type']==2]
        if len(contents)!=1:raise ValueError('DLC data NCA count mismatch')
        rows.append({'index':index,'title_id':row['title_id'],'nca':contents[0]['nca_content_id']+'.nca'})
    if len(rows)!=27 or len({r['index'] for r in rows})!=27:raise ValueError('Missing or duplicate DLC metadata')
    output.mkdir(parents=True,exist_ok=True)
    for row in sorted(rows,key=lambda r:r['index']):
        def factory(file,keypath):
            container=inspect(file.name);files=next(p['files'] for p in container['partitions'] if p['name']=='secure')
            archive=Archive(file,next(f for f in files if f['name']==row['nca']),load_keys(keypath))
            if archive.title_id!=row['title_id']:raise ValueError('DLC NCA title mismatch')
            sections=[s for s in archive.sections if s['partition_type']==0]
            if len(sections)!=1:raise ValueError('DLC RomFS section count mismatch')
            s=sections[0];return RomFS(IntegritySection(s,PlainSection(archive,s)))
        destination=output/str(row['index'])
        print('Preparing DLC',row['index'],flush=True)
        extract(xci,keys,destination,resume,rom_factory=factory)
    (output/'manifest.json').write_text(json.dumps({'format':'pjdv-dlc-local-v1','contents':rows},indent=2)+'\n')
    print('All 27 DLC authenticated and prepared',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('xci',type=Path);p.add_argument('output',type=Path);p.add_argument('--keys',type=Path,required=True);p.add_argument('--analysis',type=Path,required=True);p.add_argument('--resume',action='store_true');a=p.parse_args();prepare(a.xci,a.keys,a.analysis,a.output,a.resume)
