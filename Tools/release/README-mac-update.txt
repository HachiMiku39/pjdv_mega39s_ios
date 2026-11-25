PJDV M39 0.2.0 · macOS build 1 → build 6

中文

适用 Apple Silicon Mac，macOS 11 或更新。离线更新工具需要 Python 3.9 或更新版本，仅使用标准库。

1. 解压整个更新 ZIP，保留文件在同一文件夹。
2. 双击 Update-PJDVM39-Mac.command，选择自己已有的官方 build 1 DMG，然后选择一个有写入权限的本地文件夹。推荐 Mac 的 APFS 卷。
3. 看到 “Ready” 后，打开新生成的 PJDVM39-build6.app。更新器会核对旧版、重建文件、验证签名；旧 App、已导入的游戏资源和存档保留在原处。请先退出自己正在运行的旧版，再打开新版。Mac 包采用临时签名，未经 Apple 公证。

也可在终端进入解压后的文件夹，以自己的原版 DMG 或原版 App 为输入。最后一个参数为尚不存在的新 App 路径。

python3 pjdv_macos_update.py "/path/PJDVM39-0.2.0b1-macOS.dmg" "/path/PJDVM39-build6.app"
python3 pjdv_macos_update.py "/path/PJDVM39.app" "/path/PJDVM39-build6.app"

English

For Apple Silicon Macs running macOS 11 or later. The offline updater needs Python 3.9 or later and uses the standard library.

1. Extract the whole update ZIP into one folder.
2. Double-click Update-PJDVM39-Mac.command. Select your original official build 1 DMG, then a writable local folder. An APFS volume is recommended.
3. When “Ready” appears, open the new PJDVM39-build6.app. The updater checks the base app, restores and verifies the new files, and checks the signature. Your old app, imported resources and saves stay in place. Quit any running build 1 before starting the new one. The Mac app is ad-hoc signed and has not been notarized by Apple.

The two commands above also work in Terminal when run from the extracted folder. Use the path to your own build 1 DMG or original Mac app and a new output path.

Original build 1 DMG SHA-256
23959b54c1a1023b178ad53f34b493f4042c39ce00134750d71a571691375c71
