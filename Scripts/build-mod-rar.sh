#!/bin/sh
# Build the pinned, read-only RAR decoder using the selected Xcode toolchain.
set -eu
platform=${1:-${PLATFORM_NAME:-macos}}
output=${2:-"${DERIVED_FILE_DIR:?missing output directory}/mod-rar"}
case "$platform" in
    macos) sdk=macosx; target=arm64-apple-macos11.0 ;;
    macosx) sdk=macosx; target=arm64-apple-ios14.0-macabi ;;
    iphoneos) sdk=iphoneos; target=arm64-apple-ios17.0 ;;
    iphonesimulator) sdk=iphonesimulator; target=arm64-apple-ios17.0-simulator ;;
    *) echo "Unsupported RAR decoder platform: $platform" >&2; exit 1 ;;
esac
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
vendor="$script_dir/../ThirdParty/ModRAR"
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
cc=$(xcrun --sdk "$sdk" --find clang)
archiver=$(xcrun --sdk "$sdk" --find libtool)
mkdir -p "$output"
(cd "$vendor" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null)
key=$(
    {
        echo "$target"
        echo "$sdk_path"
        "$cc" --version
        cat "$0" "$vendor/SHA256SUMS" "$vendor/darwin_config.h"
    } | /usr/bin/shasum -a 256
)
if [ -f "$output/libpjdvarchive.a" ] && [ -f "$output/receipt" ] && [ "$(cat "$output/receipt")" = "$key" ]; then
    echo "RAR decoder ready ($target)"
    exit 0
fi
work=$(mktemp -d "$output/build.XXXXXX")
trap 'rm -rf "$work"' EXIT
for src in "$vendor"/src/*.c; do
    base=$(basename "$src" .c)
    "$cc" -std=gnu11 -target "$target" -isysroot "$sdk_path" -Os -fPIC -fvisibility=hidden \
        -Werror=implicit-function-declaration -D'PLATFORM_CONFIG_H="darwin_config.h"' \
        -I"$vendor" -I"$vendor/include" -I"$vendor/src" \
        -c "$src" -o "$work/$base.o"
done
"$archiver" -static -no_warning_for_no_symbols -o "$work/libpjdvarchive.a" "$work"/*.o
echo "$key" > "$work/receipt"
mv -f "$work/libpjdvarchive.a" "$output/libpjdvarchive.a"
mv -f "$work/receipt" "$output/receipt"
echo "Built RAR decoder ($target)"
