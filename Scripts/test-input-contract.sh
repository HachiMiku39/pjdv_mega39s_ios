#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime="${PJDV_RUNTIME_SOURCE:-/Volumes/Switch-iOS-Dev/Runtime/PJDV/dm}"
if [ -d "$project_root/Runtime/dm/host" ]; then runtime="${PJDV_RUNTIME_SOURCE:-$project_root/Runtime/dm}"; fi
test_root="${PJDV_TEST_BUILD_ROOT:-/Volumes/Switch-iOS-Dev/Build}"
mkdir -p "$test_root"
output="$(mktemp -d "$test_root/InputContract.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
xcrun clang -DDM_GAME_M39=1 -fsanitize=address,undefined -g -I"$runtime/host" \
  "-DPJDV_HID_SOURCE=\"$runtime/host/hle_hid.c\"" "$project_root/Tests/test_npad_contract.c" -o "$output/npad"
"$output/npad"
xcrun clang -fsanitize=address,undefined -g -I"$runtime/host" \
  "$project_root/Tests/NativeTouchTests.c" "$runtime/host/hle_touch.c" -o "$output/touch"
"$output/touch"
xcrun swiftc -module-cache-path "$output/ModuleCache" "$project_root/Sources/InputCore.swift" \
  "$project_root/Tests/InputCore/main.swift" -o "$output/input"
"$output/input"

for variant in m39 shared; do
  flags=(-DDM_OE_TEST_SHARED=1)
  if [ "$variant" = m39 ]; then flags=(-DDM_GAME_M39=1); fi
  xcrun clang "${flags[@]}" -O1 -fsanitize=address,undefined -g -Wl,-dead_strip -I"$runtime/host" \
    "-DPJDV_OE_SOURCE=\"$runtime/host/hle_oe.c\"" "$project_root/Tests/OperationModeTests.c" -o "$output/operation-$variant"
  "$output/operation-$variant"
done
