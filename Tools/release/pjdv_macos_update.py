#!/usr/bin/env python3
"""Rebuild the macOS application from a player's original build 1 DMG or app."""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from contextlib import contextmanager


DMG_SHA256 = "23959b54c1a1023b178ad53f34b493f4042c39ce00134750d71a571691375c71"
PATCH_SHA256 = "3583f2e937ef146f4bb0913c4c3697b320bb12ea508ae442a45802b2adf5133d"
BUILD6_EXECUTABLE_SHA256 = "e5a0dae12ac2178998f1b7282fa23bc1aa53ba49dfeda8d14a044630f780f77c"
SCRIPT_DIR = Path(__file__).resolve().parent


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as reader:
        for chunk in iter(lambda: reader.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_app(app, build):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"),
            info.get("CFBundleIdentifier")) != ("0.2.0", build, "com.local.switchioslab"):
        raise ValueError("This updater requires the original PJDV M39 0.2.0 build " + build)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if build == "6" and digest(app / "Contents/MacOS/PJDVM39") != BUILD6_EXECUTABLE_SHA256:
        raise ValueError("The reconstructed executable differs from the verified release candidate")


@contextmanager
def original_app(source):
    if source.is_dir() and source.suffix.lower() == ".app":
        yield source
        return
    if source.suffix.lower() != ".dmg" or not source.is_file() or digest(source) != DMG_SHA256:
        raise ValueError("Choose your original PJDV M39 0.2.0 build 1 macOS DMG or app")
    with tempfile.TemporaryDirectory(prefix="pjdv-base-") as work:
        mount = Path(work) / "source"
        mount.mkdir()
        subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
                        str(mount), str(source)], check=True)
        try:
            yield mount / "PJDVM39.app"
        finally:
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)


def publish(source, target):
    # Never replace a folder created by another process during verification.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(target), 4) != 0:  # RENAME_EXCL
        errno = ctypes.get_errno()
        raise OSError(errno, os.strerror(errno), target)


def rebuild(source, patch, target):
    if sys.platform != "darwin":
        raise ValueError("The DMG updater runs on macOS")
    source = source.resolve(strict=True)
    patch = patch.resolve(strict=True)
    # Resolve the parent separately to reject even a dangling output symlink.
    target = target.parent.resolve(strict=True) / target.name
    if target.suffix.lower() != ".app" or os.path.lexists(target) or source in target.parents:
        raise ValueError("Choose a new .app path outside the original app")
    if not patch.is_file() or digest(patch) != PATCH_SHA256:
        raise ValueError("The host update does not match the build 6 release")
    # Verify and publish on the destination volume, even when the input is a DMG.
    with tempfile.TemporaryDirectory(prefix=".pjdv-update-", dir=target.parent) as work:
        candidate = Path(work) / "PJDVM39.app"
        with original_app(source) as base:
            verify_app(base, "1")
            subprocess.run([sys.executable, str(SCRIPT_DIR / "pjdv_host_update.py"), "apply",
                            "mac", str(base), str(patch), str(candidate)], check=True)
        verify_app(candidate, "6")
        publish(candidate, target)
    print("Ready:", target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original build 1 .dmg or .app")
    parser.add_argument("output", type=Path, help="New .app path on a Mac volume")
    parser.add_argument("--patch", type=Path, default=SCRIPT_DIR / "mac-host-delta.zip")
    args = parser.parse_args()
    try:
        rebuild(args.source, args.patch, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Update failed: " + str(error) + "\n")


if __name__ == "__main__":
    main()
