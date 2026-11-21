"""Run the normal present path against controlled Metal feedback on macOS."""
from pathlib import Path
import os
import subprocess
import tempfile


def main():
    fixtures = Path(__file__).resolve().parent
    runtime = Path(os.environ.get("PJDV_RUNTIME_SOURCE", "/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm/gfx/nvn"))
    source = (runtime / "nvn_mtl.m").read_text()
    helpers = source.index("static void present_acquire_slot(")
    present = source.index("static int present_now(", helpers)
    begin = source.index("present_acquire_slot(alloc_i);", present)
    end = source.index("if (target_ts > 0)", begin)
    with tempfile.TemporaryDirectory(dir=os.environ.get("PJDV_TEST_ROOT")) as tmp:
        output = Path(tmp)
        (output / "slot_functions.inc").write_text(source[helpers:present])
        (output / "encode_and_feedback.inc").write_text(source[begin:end])
        for legacy in (1, 0):
            binary = output / f"test-slots-{legacy}"
            command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-O1",
                       "-fsanitize=address,undefined", "-framework", "Foundation",
                       f"-DDM_NVN_M3={legacy}", "-I", str(output), str(fixtures / "slots.m"),
                       "-o", str(binary)]
            subprocess.run(command, check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
