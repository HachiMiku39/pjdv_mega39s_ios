#!/bin/sh
set -eu
[ "${EFFECTIVE_PLATFORM_NAME:-}" = '-maccatalyst' ] || exit 0
plugin="$TARGET_BUILD_DIR/$PLUGINS_FOLDER_PATH/PJDVMacLifecycle.bundle"
mkdir -p "$plugin/Contents/MacOS"
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
/usr/bin/xcrun --sdk macosx clang -fobjc-arc -arch arm64 -mmacosx-version-min=11.0 -isysroot "$sdk" -bundle \
  -framework Foundation -framework AppKit "$SRCROOT/Sources/MacLifecycle/PJDVMacLifecycle.m" \
  -o "$plugin/Contents/MacOS/PJDVMacLifecycle"
/usr/bin/plutil -create xml1 "$plugin/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.local.switchioslab.mac-lifecycle "$plugin/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string PJDVMacLifecycle "$plugin/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string BNDL "$plugin/Contents/Info.plist"
/usr/bin/plutil -insert NSPrincipalClass -string PJDVMacLifecycle "$plugin/Contents/Info.plist"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
 /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$plugin"
fi
