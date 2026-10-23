#!/bin/sh
set -eu
key_dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ImportKeys"
# Public builds never embed keys, even if a local environment requests it.
if [ "${PJDV_EMBED_KEYS:-0}" != 0 ]; then
    echo 'Public builds must not embed prod.keys. Import keys through the app UI.' >&2
    exit 2
fi
# This is only a generated bundle path, never the user's imported key storage.
if [ -f "$key_dest/prod.keys" ]; then /bin/rm "$key_dest/prod.keys"; fi
