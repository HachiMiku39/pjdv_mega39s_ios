#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if xcode-select -p | /usr/bin/grep -q 'CommandLineTools'; then
    for candidate in /Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode*.app/Contents/Developer; do
      if [ -d "$candidate" ]; then export DEVELOPER_DIR="$candidate"; break; fi
    done
  fi
fi
BUILD_KIND="${1:-simulator}"
case "$BUILD_KIND" in
  simulator) DESTINATION='generic/platform=iOS Simulator' ;;
  device) DESTINATION='generic/platform=iOS' ;;
  mac) DESTINATION='generic/platform=macOS,variant=Mac Catalyst' ;;
  *) echo 'Usage: bash Scripts/build.sh [simulator|device|mac]' >&2; exit 2 ;;
esac
BUILD_ROOT="${SWITCH_IOS_BUILD_ROOT:?Set SWITCH_IOS_BUILD_ROOT to an APFS build directory; see BUILDING.md}"
for required in PrivateBuild/segmented/GuestImages.S PrivateBuild/segmented/GuestLayout.h PrivateBuild/RendererAssets/Shaders/shader_map.tsv PrivateBuild/ExitMenu/manifest.json; do
  if [ ! -s "$PROJECT_ROOT/$required" ]; then
    echo "Missing private build input: $required. See BUILDING.md; no original game inputs are included in this repository." >&2
    exit 2
  fi
done
mkdir -p "$BUILD_ROOT/DerivedData" "$BUILD_ROOT/ModuleCache" "$BUILD_ROOT/Temp"
export TMPDIR="$BUILD_ROOT/Temp/"
xcodebuild -project "$PROJECT_ROOT/SwitchIOSLab.xcodeproj" -scheme SwitchIOSLab \
  -configuration "${PJDV_CONFIGURATION:-Release}" -destination "$DESTINATION" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" \
  CODE_SIGNING_ALLOWED=NO build
