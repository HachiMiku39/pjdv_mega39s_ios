"""Read base/BKTR-merged RomFS without copying either NCA or XCI.

Layouts follow SciresM/hactool bktr.h, nca.c and ivfc.h. Every accessed
RomFS block is checked through IVFC to the master hash in the NCA FS header.
Key values stay in memory and are never serialized into the resource index.
"""
import argparse
import bisect
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import struct
from inspect_xci import inspect, FormatError, MAX_TABLE
from nca_reader import Archive, load_keys

BASE = '80cd21b28e6031ae82d7b65fcd446993.nca'
UPDATE = 'ba9d8ba79c3ca77f7a271c3b49ddd2e5.nca'


class PlainSection:
    def __init__(self, archive, section):
        self.archive, self.section, self.size = archive, section, section['size']
    def read(self, offset, length):
        return self.archive.read(self.section, offset, length)


class BktrSection:
    def __init__(self, archive, section, base):
        self.archive, self.section, self.base = archive, section, base
        fs = section['fs']
        ro, rz, rm, _, rn = struct.unpack_from('<QQIII', fs, 0x100)
        so, sz, sm, _, sn = struct.unpack_from('<QQIII', fs, 0x120)
        if rm != 0x52544b42 or sm != rm or ro + rz != so or so + sz != section['size'] or rz > MAX_TABLE or sz > MAX_TABLE:
            raise FormatError('Invalid BKTR metadata layout')
        reloc = archive.read_ctr_data(section, ro, rz)
        sub = archive.read_ctr_data(section, so, sz)
        self.relocations, self.size = self._buckets(reloc, 20, '<QQI', rn)
        self.subsections, physical_end = self._buckets(sub, 16, '<QII', sn)
        if physical_end != so or not self.relocations or not self.subsections:
            raise FormatError('Invalid BKTR total size or empty maps')
        self.subsections = [(o, ctr) for o, _, ctr in self.subsections]
        if self.subsections[-1][0] > ro:
            raise FormatError('BKTR data subsections overlap metadata')
        if self.subsections[-1][0] < ro:
            self.subsections.append((ro, struct.unpack_from('<I', fs, 0x140)[0]))
        self.sub_offsets = [r[0] for r in self.subsections]
        self.rel_offsets = [r[0] for r in self.relocations]
        if self.rel_offsets[0] != 0 or self.sub_offsets[0] != 0:
            raise FormatError('BKTR map must start at zero')
        for i, (v, p, patch) in enumerate(self.relocations):
            end = self.relocations[i+1][0] if i+1 < len(self.relocations) else self.size
            limit = ro if patch else base.size
            if patch not in (0, 1) or v >= end or p + end - v > limit:
                raise FormatError('BKTR mapped range outside base or patch data')

    @staticmethod
    def _buckets(raw, stride, fmt, declared_entries):
        if len(raw) < 0x8000 or len(raw) % 0x4000:
            raise FormatError('BKTR bucket block has invalid size')
        _, buckets, total = struct.unpack_from('<IIQ', raw)
        if not 1 <= buckets <= 2046 or (buckets+1)*0x4000 > len(raw):
            raise FormatError('Invalid BKTR bucket count')
        entries = []
        for i in range(buckets):
            at = (i+1)*0x4000
            _, count, end = struct.unpack_from('<IIQ', raw, at)
            if not 1 <= count <= 0x3ff0//stride or end > total:
                raise FormatError('Invalid BKTR bucket entry count')
            for n in range(count):
                entries.append(struct.unpack_from(fmt, raw, at+16+n*stride))
        if len(entries) != declared_entries or any(a[0] >= b[0] for a,b in zip(entries,entries[1:])) or entries[-1][0] >= total:
            raise FormatError('Invalid BKTR entry ordering or header count')
        return entries, total

    def physical_read(self, offset, length):
        out = bytearray()
        while length:
            i = bisect.bisect_right(self.sub_offsets, offset)-1
            end = self.sub_offsets[i+1] if i+1 < len(self.sub_offsets) else self.section['size']
            take = min(length, end-offset)
            out.extend(self.archive.read_ctr_data(self.section,offset,take,self.subsections[i][1]))
            offset += take; length -= take
        return bytes(out)

    def read(self, offset, length):
        if offset < 0 or length < 0 or offset+length > self.size:
            raise FormatError('BKTR virtual read out of bounds')
        out = bytearray()
        while length:
            i = bisect.bisect_right(self.rel_offsets, offset)-1
            v, p, patch = self.relocations[i]
            end = self.rel_offsets[i+1] if i+1 < len(self.rel_offsets) else self.size
            take = min(length,end-offset); physical = p+offset-v
            out.extend(self.physical_read(physical,take) if patch else self.base.read(physical,take))
            offset += take; length -= take
        return bytes(out)


class IntegritySection:
    def __init__(self, section, reader):
        fs = section['fs']; self.reader = reader
        if fs[8:12] != b'IVFC' or struct.unpack_from('<I',fs,20)[0] != 7:
            raise FormatError('Unsupported IVFC hierarchy')
        self.levels = []
        for i in range(6):
            off, size, bits, _ = struct.unpack_from('<QQII',fs,24+24*i)
            if not 9 <= bits <= 20 or off+size > reader.size or not size:
                raise FormatError('IVFC level outside virtual section')
            self.levels.append((off,size,1<<bits))
        self.master = fs[0xc8:0xe8]
        self.size = self.levels[-1][1]
        self.blocks_verified = 0

    @lru_cache(maxsize=512)
    def block(self, level, index):
        off, size, block = self.levels[level]; pos=index*block
        if pos >= size:
            raise FormatError('IVFC block index outside level')
        raw = self.reader.read(off+pos,min(block,size-pos))
        expected = self.master[index*32:(index+1)*32] if level == 0 else self.level_read(level-1,index*32,32)
        if len(expected) != 32 or hashlib.sha256(raw+bytes(block-len(raw))).digest() != expected:
            raise FormatError(f'IVFC integrity mismatch at level {level} block {index}')
        self.blocks_verified += 1
        return raw

    def level_read(self, level, offset, length):
        _, size, block = self.levels[level]
        if offset < 0 or length < 0 or offset+length > size or length > MAX_TABLE:
            raise FormatError('IVFC read outside level or bound')
        out = bytearray()
        while length:
            index, local = divmod(offset,block); raw = self.block(level,index)
            take = min(length,len(raw)-local)
            out.extend(raw[local:local+take]); offset += take; length -= take
        return bytes(out)
    def read(self, offset, length):
        return self.level_read(5,offset,length)


class RomFS:
    def __init__(self, reader):
        self.reader = reader
        h = struct.unpack('<10Q',reader.read(0,80))
        if h[0] != 80 or h[9] > reader.size:
            raise FormatError('Invalid RomFS header')
        for i in (1,3,5,7):
            if h[i]+h[i+1] > reader.size or h[i+1] > MAX_TABLE:
                raise FormatError('RomFS metadata table outside bounds')
        self.directories = reader.read(h[3],h[4]); self.files = reader.read(h[7],h[8]); self.data_offset = h[9]
        self.entries = self._index()

    @staticmethod
    def name(table, at, fixed, length, root=False):
        if length > 4096 or at+fixed+length > len(table):
            raise FormatError('RomFS name outside table')
        name = table[at+fixed:at+fixed+length].decode('utf-8')
        if root and name == '': return name
        if not name or name in ('.','..') or any(c in name for c in '/\\\0'):
            raise FormatError('Unsafe RomFS name')
        return name

    def _index(self):
        rows, seen_dirs, seen_files, paths = [], set(), set(), set()
        stack = [(0,'',None)]
        while stack:
            at, prefix, expected_parent = stack.pop()
            if at in seen_dirs or at%4 or at+24 > len(self.directories):
                raise FormatError('RomFS directory cycle or invalid offset')
            seen_dirs.add(at)
            parent,sibling,child,file,_,length=struct.unpack_from('<6I',self.directories,at)
            name=self.name(self.directories,at,24,length,root=at==0)
            if expected_parent is not None and parent != expected_parent:
                raise FormatError('RomFS parent mismatch')
            path = prefix+'/'+name if prefix else name
            if sibling != 0xffffffff: stack.append((sibling,prefix,expected_parent))
            if child != 0xffffffff: stack.append((child,path,at))
            while file != 0xffffffff:
                if file in seen_files or file%4 or file+32 > len(self.files):
                    raise FormatError('RomFS file cycle or invalid offset')
                seen_files.add(file)
                par,sib,offset,size,_,length=struct.unpack_from('<IIQQII',self.files,file)
                name=self.name(self.files,file,32,length); full=path+'/'+name if path else name
                if par != at or full in paths or self.data_offset+offset+size > self.reader.size:
                    raise FormatError('RomFS file parent, path or data bounds invalid')
                paths.add(full);rows.append({'path':full,'offset':self.data_offset+offset,'bytes':size});file=sib
        return sorted(rows,key=lambda r:r['path'])


def open_program_romfs(file, keys_path, merged=True):
    container=inspect(file.name);keys=load_keys(keys_path)
    files=next(p['files'] for p in container['partitions'] if p['name']=='secure')
    def archive(name): return Archive(file,next(e for e in files if e['name']==name),keys)
    base=archive(BASE);bs=next(s for s in base.sections if s['partition_type']==0)
    plain=PlainSection(base,bs)
    if not merged: return RomFS(IntegritySection(bs,plain))
    update=archive(UPDATE);us=next(s for s in update.sections if s['partition_type']==0)
    return RomFS(IntegritySection(us,BktrSection(update,us,plain)))


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('xci',type=Path);ap.add_argument('--keys',type=Path,required=True);ap.add_argument('--index',type=Path,required=True);ap.add_argument('--base',action='store_true');a=ap.parse_args()
    with a.xci.open('rb') as f:
        romfs=open_program_romfs(f,a.keys,not a.base)
        value={'format':'pjdv-romfs-index-v1','merged_update':not a.base,'file_count':len(romfs.entries),'romfs_bytes':romfs.reader.size,'metadata_ivfc_blocks_verified':romfs.reader.blocks_verified,'files':romfs.entries,'whole_romfs_integrity':'not_yet_all_blocks_read'}
        with a.index.open('x') as dst:json.dump(value,dst,ensure_ascii=False,indent=2)
        print(f'Indexed {len(romfs.entries)} files; authenticated metadata blocks {romfs.reader.blocks_verified}')


if __name__=='__main__': main()
