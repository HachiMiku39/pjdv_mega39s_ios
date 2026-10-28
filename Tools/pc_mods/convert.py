"""Offline conversion of explicitly scoped PC resource profiles.

This produces an isolated read-only overlay. It does not enable the public
App MOD ABI, execute PC code, or install New Classics gameplay mechanics.
"""
import argparse,os,sys
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--profile',required=True,choices=['rage-winter-2020','x-song-pack','electric-angel-rin-len'])
p.add_argument('--source',required=True,type=Path,help='Extracted package root containing rom/')
p.add_argument('--base',required=True,type=Path,help='Extracted original game root')
p.add_argument('--dlc',required=True,type=Path)
p.add_argument('--output',required=True,type=Path,help='New directory on the external SSD')
a=p.parse_args()
if not __debug__:p.error('Do not run this validation tool with Python -O')
a.source=a.source.resolve();a.base=a.base.resolve();a.dlc=a.dlc.resolve();a.output=a.output.resolve()
if not (a.source/'rom').is_dir() or not (a.base/'rom_switch/rom').is_dir() or not a.dlc.is_dir():p.error('Missing package/base/DLC directory')
if a.output.exists():p.error('Output must be a new directory; existing data will not be overwritten')
for root in (a.source,a.base,a.dlc):
    if a.output.is_relative_to(root) or root.is_relative_to(a.output):p.error('Output must be separate from all input directories')
for f in a.source.rglob('*'):
    if f.is_symlink():p.error('Source symlinks are not supported')
    if f.is_file() and f.suffix.lower()=='.farc' and f.stat().st_size>128*1024*1024:p.error('FARC exceeds the conversion limit')
a.output.mkdir(parents=True)
for key,value in [('SOURCE',a.source),('BASE',a.base),('DLC',a.dlc),('OUTPUT',a.output)]:os.environ['PJDV_MOD_'+key]=str(value)
try:os.nice(10)
except OSError:pass
if a.profile=='rage-winter-2020':
    import profile_model
    profile_model.main()
elif a.profile=='x-song-pack':
    import profile_x_song
    profile_x_song.main()
    import sprite_pairing,font_pairing
else:
    import profile_electric_angel
    profile_electric_angel.main()
print('Conversion complete; game validation requires an isolated test save.')
