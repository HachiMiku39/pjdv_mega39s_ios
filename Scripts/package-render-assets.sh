#!/bin/sh
set -eu
# The cache is a small, versioned host dependency; no ROM/DLC/key data.
render_source="${PJDV_RENDER_SOURCE_DIR:-$SRCROOT/PrivateBuild/RendererAssets}"
render_chain=b-pjdv-842acf8d7583
render_dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/RendererAssets"
test -s "$render_source/Shaders/shader_map.tsv"
test -d "$render_source/MetalCache/$render_chain"
mkdir -p "$render_dest/Shaders" "$render_dest/MetalCache/$render_chain"
cp "$render_source/Shaders/shader_map.tsv" "$render_dest/Shaders/"
# Only shader libraries and their reflection metadata enter the bundle.
for render_file in "$render_source/MetalCache/$render_chain/"*.metallib "$render_source/MetalCache/$render_chain/"*.json; do
    test -s "$render_file"
    cp "$render_file" "$render_dest/MetalCache/$render_chain/"
done

for locale_source in "$SRCROOT/Assets/Localizations/"*.lproj; do
    locale_name=$(basename "$locale_source")
    mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/$locale_name"
    cp "$locale_source/Localizable.strings" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/$locale_name/"
done

mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ControllerGlyphs"
cp "$SRCROOT/Assets/ControllerGlyphs/recipes.json" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ControllerGlyphs/"
