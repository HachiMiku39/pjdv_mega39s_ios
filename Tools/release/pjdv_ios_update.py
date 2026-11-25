#!/usr/bin/env python3
"""Apply a host update to your local build 1 IPA before signing the new IPA."""
import argparse
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import zipfile

from pjdv_host_update import apply, check, file_hash

BASE_SHA = "31b99dc74980bd8288ae125bf8a09f849bf9801895a4102ff07e4487d00786e2"
PATCH_SHA = "07a4a44e477c8ae6431d6976fceb40218988150684c454a92c1623c46641ce1d"
OUTPUT_SHA = "8a913bffdb4418079f5945d46e7978ab90d2d9ac68349647eb41fe62d5449f68"
PREFIX = "Payload/PJDVM39.app/"


def unpack(base, folder):
    check(file_hash(base) == BASE_SHA, "Expected the original unsigned build 1 IPA")
    with zipfile.ZipFile(base) as archive:
        for entry in archive.infolist():
            check(entry.filename.startswith(PREFIX), "Unexpected IPA layout")
            name = entry.filename[len(PREFIX):]
            if not name or entry.is_dir():
                continue
            path = PurePosixPath(name)
            check(not path.is_absolute() and ".." not in path.parts and "\\" not in name, "Invalid IPA path")
            mode = entry.external_attr >> 16
            check(not stat.S_ISLNK(mode), "Unexpected link in IPA")
            out = folder / path
            out.parent.mkdir(parents=True,exist_ok=True)
            with archive.open(entry) as source, out.open("xb") as dest:
                shutil.copyfileobj(source,dest)
            out.chmod(0o755 if name == "PJDVM39" else 0o644)


def package(folder, output):
    # Stored entries and constant metadata give the same output digest on macOS,
    # Windows and Linux, independently of the system zlib release.
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_STORED) as archive:
        for f in sorted(folder.rglob("*"), key=lambda item: item.relative_to(folder).parts):
            if not f.is_file():
                continue
            path=f.relative_to(folder).as_posix()
            info=zipfile.ZipInfo(PREFIX+path,(2026,1,1,0,0,0))
            info.create_system=3
            info.external_attr=(stat.S_IFREG | (0o755 if path=="PJDVM39" else 0o644))<<16
            with f.open("rb") as src, archive.open(info,"w") as dst:
                shutil.copyfileobj(src,dst)


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument("base",type=Path,help="Original unsigned build 1 IPA")
    cli.add_argument("patch",type=Path,help="Published iOS host update ZIP")
    cli.add_argument("output",type=Path,help="Path for a new unsigned build 6 IPA")
    a=cli.parse_args()
    check(not a.output.exists() and not a.output.is_symlink(), "Output IPA already exists")
    check(file_hash(a.patch) == PATCH_SHA, "Unexpected iOS update file or digest")
    with tempfile.TemporaryDirectory(dir=a.output.parent) as tmp:
        w=Path(tmp)
        old=w/"Old.app"
        old.mkdir()
        unpack(a.base,old)
        new=w/"New.app"
        apply("ios",old,a.patch,new)
        tmp_ipa=w/"update.ipa"
        package(new,tmp_ipa)
        check(file_hash(tmp_ipa) == OUTPUT_SHA, "Unsigned IPA does not match the release reference")
        with zipfile.ZipFile(tmp_ipa) as z:
            check(z.testzip() is None,"Rebuilt IPA CRC failed")
        # Exclusive creation also protects a newly created output if another
        # updater finished while this one was assembling the IPA.
        with a.output.open("xb") as dest:
            try:
                with tmp_ipa.open("rb") as src:
                    shutil.copyfileobj(src,dest)
            except BaseException:
                dest.close()
                a.output.unlink()
                raise
    print("Unsigned IPA:",a.output)
    print("SHA-256:",file_hash(a.output))


if __name__ == "__main__":
    try:
        main()
    except (OSError,ValueError,KeyError,zipfile.BadZipFile) as e:
        sys.exit(str(e))
