"""Exercise the Swift launch path and the native boot admission on a Mac."""
import os
from pathlib import Path
import subprocess
import tempfile

tests = Path(__file__).resolve().parent
project = tests.parents[1]
runtime = Path(os.environ.get("PJDV_RUNTIME_SOURCE", project / "Runtime/dm"))
if not (runtime / "host/pjdv_boot.c").is_file() and "PJDV_RUNTIME_SOURCE" not in os.environ:
    runtime = Path("/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm")
source = (runtime / "host/pjdv_boot.c").read_text()
with tempfile.TemporaryDirectory(dir=os.environ.get("PJDV_TEST_ROOT")) as tmp:
    out = Path(tmp)
    # Keep the real allocation, phase transition and pthread-create failure paths.
    (out / "boot_under_test.inc").write_text(
        source[source.index("typedef struct { char *path[5]; } guest_boot_args;"):
               source.index("static void guest_boot_body(")] +
        source[source.index("int pjdv_guest_boot("):])
    # The command-line Mac harness substitutes the iOS-only audio session API.
    (out / "GuestRuntime.swift").write_text(
        (project / "Sources/GuestRuntime.swift").read_text().replace("import AVFAudio", ""))
    subprocess.run(["xcrun", "clang", "-I", str(out), "-c", str(tests / "native.c"),
                    "-o", str(out / "native.o")], check=True)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(out / "ModuleCache"),
                    str(out / "GuestRuntime.swift"), str(project / "Sources/InputCore.swift"),
                    str(tests / "check.swift"), str(out / "native.o"), "-o", str(out / "check")], check=True)
    (out / "ExitMenu").mkdir()
    (out / "ExitMenu/manifest.json").write_text("{}")
    subprocess.run([str(out / "check"), str(out / "Data")], check=True, timeout=25)
