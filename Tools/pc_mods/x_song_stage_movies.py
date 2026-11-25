"""Resolve and publish the three PVDB-declared stage-screen movies in X Song Pack."""
import hashlib
from pathlib import Path
import re
import shutil

import usm_video


def stage_movie_inputs(root, pv):
    """Resolve this profile's optional stage-screen clips from its actual PVDB."""
    result = {}
    for key, declared in pv.items():
        if not key.endswith('.movie_file_name'):
            continue
        match = re.fullmatch(r'pv_(800|802|820)\.movie_file_name', key)
        if not match or declared != 'rom/movie/pvstg_' + match[1] + '.mp4':
            raise ValueError('Unsupported X Song stage movie declaration: ' + key)
        target = Path(declared)
        mp4, usm = root / target, root / target.with_suffix('.usm')
        if mp4.is_file():
            with mp4.open('rb') as stream:
                if stream.read(12)[4:8] != b'ftyp':
                    raise ValueError('Invalid stage MP4: ' + declared)
            result[mp4] = target
        elif usm.is_file():
            result[usm] = target
        else:
            raise ValueError('Missing X Song stage movie: ' + declared)
    return result


def install_stage_movie(source, relative, overlay, work, tables_only=False):
    target = overlay / 'rom_switch' / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    if not tables_only:
        if target.exists():
            raise FileExistsError(target)
        # Keep partial writes, logs and conversion receipts outside the game layer.
        staged = work / 'stage-videos' / relative.name
        staged.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix == '.usm':
            usm_video.convert(source, staged)
        else:
            with source.open('rb') as src, staged.open('xb') as dst:
                try:
                    shutil.copyfileobj(src, dst, 1024 * 1024)
                except BaseException:
                    staged.unlink()
                    raise
        usm_video.publish_completed(staged, target)
    digest = hashlib.sha256()
    with target.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return {'path': str(target.relative_to(overlay)), 'size': target.stat().st_size, 'sha256': digest.hexdigest()}
