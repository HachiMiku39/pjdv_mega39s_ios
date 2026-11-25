#!/usr/bin/env python3
"""Stage the original Google Sans and Noto Sans CJK Regular fonts and OFL notices."""

import argparse
import hashlib
from pathlib import Path
import shutil
import tempfile
from urllib.request import Request, urlopen
from zipfile import ZipFile


ASSETS = Path(__file__).resolve().parents[1] / "Assets" / "GoogleSans"
RAW = "https://raw.githubusercontent.com/"
GOOGLE = RAW + "googlefonts/googlesans/v14.000/"
NOTO = RAW + "notofonts/noto-cjk/523d033d6cb47f4a80c58a35753646f5c3608a78/"
RELEASE = "https://github.com/googlefonts/googlesans/releases/download/v14.000/GoogleSans-v14.000.zip"
REGULAR = "GoogleSans-Regular.ttf"
FILES = {
    REGULAR: (RELEASE, 2190444, "2ab1f257d8c87bd7a376fc8504238fd0ffbc435d7605907196db31a1867cb59e"),
    "GoogleSans-OFL.txt": (GOOGLE + "OFL.txt", 4397, "831b6e041705873c3e6efb18c4c96202bc41c8be42a456d3d26c47abf14816d0"),
    "NotoSansCJK-Regular.ttc": (NOTO + "Sans/OTC/NotoSansCJK-Regular.ttc", 19484784, "b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a"),
    "NotoSansCJK-OFL.txt": (NOTO + "LICENSE", 4301, "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"),
}


def matches(path, size, expected):
    if not path.is_file() or path.stat().st_size != size:
        return False
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest() == expected


def download(url, path, maximum):
    request = Request(url, headers={"User-Agent": "PJDV-font-prepare/1"})
    with urlopen(request, timeout=90) as response, path.open("xb") as dest:
        size = 0
        for block in iter(lambda: response.read(1024 * 1024), b""):
            size += len(block)
            if size > maximum:
                raise ValueError(f"Upstream file exceeds size limit: {path.name}")
            dest.write(block)


def prepare(source_dir):
    if all(matches(ASSETS / name, size, sha) for name, (_, size, sha) in FILES.items()):
        return
    with tempfile.TemporaryDirectory(prefix=".game-font-", dir=ASSETS.parent) as temp:
        stage = Path(temp)
        for name, (url, size, sha) in FILES.items():
            target = stage / name
            if source_dir is not None:
                source = source_dir / name
                if not matches(source, size, sha):
                    raise ValueError(f"Missing or unverified offline source: {source}")
                shutil.copyfile(source, target)
            elif name == REGULAR:
                archive = stage / "GoogleSans-v14.000.zip"
                download(url, archive, 40 * 1024 * 1024)
                with ZipFile(archive) as package:
                    item = package.getinfo("build/GoogleSans/static/" + REGULAR)
                    if item.file_size != size:
                        raise ValueError("Unexpected Google Sans Regular release member size")
                    with package.open(item) as src, target.open("xb") as dest:
                        shutil.copyfileobj(src, dest, 1024 * 1024)
            else:
                download(url, target, size)
            if not matches(target, size, sha):
                raise ValueError(f"SHA-256 mismatch for {name}. Verify the original release.")
        ASSETS.mkdir(exist_ok=True)
        for name in FILES:
            (stage / name).replace(ASSETS / name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-dir", type=Path, metavar="DIRECTORY",
                        help="use local copies of the two pinned fonts and their two OFL notices")
    prepare(parser.parse_args().from_dir)
    print(f"Verified Google Sans and Noto Sans CJK at {ASSETS}")
