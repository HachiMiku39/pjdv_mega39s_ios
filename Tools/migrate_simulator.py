"""Copy, verify and link one shut-down simulator. Retains a rollback copy.

Only an explicit --cutover changes the original directory. --archive-backup moves
the verified rollback copy to the external APFS volume after launch validation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

UUID = 'FC5E7B33-6E22-402A-B419-6DC191424427'
SOURCE = Path.home() / 'Library/Developer/CoreSimulator/Devices' / UUID
DEST = Path('/Volumes/Switch-iOS-Dev/Simulators') / UUID
BACKUP = SOURCE.with_name(UUID + '.migration-backup')
ARCHIVE = Path('/Volumes/Switch-iOS-Dev/MigrationBackups') / UUID


def ensure_shutdown(path):
    info = plistlib.loads((path / 'device.plist').read_bytes())
    if info.get('state') != 1:
        raise RuntimeError('The selected simulator must be shut down before migration')
    if info.get('UDID') != UUID:
        raise RuntimeError('Unexpected simulator identity')


def manifest(root):
    result = {}
    for folder, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            path = Path(folder) / name
            relative = str(path.relative_to(root))
            if path.is_symlink():
                result[relative] = ['link', os.readlink(path)]
            elif path.is_dir():
                result[relative] = ['directory']
            elif path.is_file():
                digest = hashlib.sha256()
                with path.open('rb') as file:
                    while block := file.read(4 * 1024 * 1024):
                        digest.update(block)
                result[relative] = ['file', path.stat().st_size, digest.hexdigest()]
            else:
                result[relative] = ['special', path.lstat().st_mode]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cutover', action='store_true')
    parser.add_argument('--archive-backup', action='store_true')
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    if sum([args.cutover, args.archive_backup, args.rollback]) > 1:
        raise RuntimeError('Choose a single migration operation')
    if not Path('/Volumes/Switch-iOS-Dev').is_mount():
        raise RuntimeError('External APFS development image is not mounted')
    if args.rollback:
        ensure_shutdown(DEST)
        backup = BACKUP if BACKUP.is_dir() else ARCHIVE
        if not SOURCE.is_symlink() or SOURCE.resolve() != DEST or not backup.is_dir():
            raise RuntimeError('Expected link and rollback backup are missing')
        ensure_shutdown(backup)
        staging = SOURCE.with_name(UUID + '.rollback-staging')
        if staging.exists():
            raise RuntimeError('Rollback staging exists; refusing to overwrite')
        subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl', str(backup), str(staging)], check=True)
        if manifest(backup) != manifest(staging):
            raise RuntimeError('Rollback verification failed; original link retained')
        SOURCE.unlink()
        try:
            staging.rename(SOURCE)
        except OSError:
            SOURCE.symlink_to(DEST, target_is_directory=True)
            raise
        print('Original simulator restored; external copy retained')
        return
    if args.archive_backup:
        ensure_shutdown(DEST)
        if not SOURCE.is_symlink() or SOURCE.resolve() != DEST or not BACKUP.is_dir() or ARCHIVE.exists():
            raise RuntimeError('Archive preconditions not met')
        ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/mv', str(BACKUP), str(ARCHIVE)], check=True)
        report_path = DEST.parent / 'migration-report.json'
        report = json.loads(report_path.read_text())
        report['rollback_copy'] = str(ARCHIVE)
        report['rollback_copy_archived'] = True
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        print(f'Original rollback data retained at {ARCHIVE}')
        return
    if SOURCE.is_symlink() or BACKUP.exists():
        raise RuntimeError('Migration already started; inspect state before retrying')
    ensure_shutdown(SOURCE)
    DEST.parent.mkdir(parents=True, exist_ok=True)
    if DEST.exists():
        raise RuntimeError('Destination exists; refusing to overwrite data')
    print('Copying selected simulator to external APFS storage', flush=True)
    subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl', str(SOURCE), str(DEST)], check=True)
    print('Verifying every regular file and symbolic link', flush=True)
    original = manifest(SOURCE)
    copied = manifest(DEST)
    if original != copied:
        changed = [key for key in original.keys() | copied.keys() if original.get(key) != copied.get(key)]
        raise RuntimeError(f'Verification mismatch: {changed[:10]}')
    ensure_shutdown(SOURCE)
    report = {'uuid': UUID, 'source': str(SOURCE), 'destination': str(DEST),
              'entries_verified': len(original), 'verification': 'all_file_sha256_and_symlinks',
              'cutover': args.cutover, 'rollback_copy': str(BACKUP) if args.cutover else str(SOURCE)}
    if args.cutover:
        SOURCE.rename(BACKUP)
        try:
            SOURCE.symlink_to(DEST, target_is_directory=True)
        except OSError:
            BACKUP.rename(SOURCE)
            raise
    (DEST.parent / 'migration-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Migration stopped safely: {error}', file=sys.stderr)
        sys.exit(2)
