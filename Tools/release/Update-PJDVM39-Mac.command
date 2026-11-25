#!/bin/sh
set -eu
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
    echo "This updater requires Python 3.9 or later. / 请先安装 Python 3.9 或更高版本。"
    exit 1
fi

source_dmg=$(/usr/bin/osascript -e 'POSIX path of (choose file with prompt "Choose your original PJDV M39 build 1 DMG / 选择原版 build 1 DMG" of type {"dmg"})')
destination=$(/usr/bin/osascript -e 'POSIX path of (choose folder with prompt "Save the new app in a folder / 选择保存新版应用的文件夹")')
python3 ./pjdv_macos_update.py "$source_dmg" "${destination%/}/PJDVM39-0.2.1.app"
