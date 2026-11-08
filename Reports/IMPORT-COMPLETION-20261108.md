# complete.json 缺失与导入入口 / Missing complete.json and import entry points

2026-11-08 · build22 导入与恢复记录 / build22 import and recovery record

玩家截图为 build21（日语界面），错误是 Foundation 的 `complete.json` 不存在。截图本身不足以判断文件移动是否完整，不能断言玩家操作错误。

## 复现与原因

用程序实际 XCI 导入器生成小型合成 GameResources，随后只移除测试副本的 `romfs/complete.json`，调用实际 `ResourceLayout.locate`：旧代码得到 **NSCocoaErrorDomain Code260 — complete.json couldn't be opened because there is no such file**，与截图一致。DLC 完成标记缺失也走同一验证路径。

单纯把 XCI 放进 App 根目录，随后使用“使用已拷入本机的资源”，不等于导入 XCI。该按钮只检查已经由 PJDV 提取完成的 GameResources。只有根目录 XCI、完全没有已提取资源时，源码会提示选择 GameResources；出现 `complete.json` 报错说明验证已经找到了准备记录和资源目录，却在检查完成标记时失败。可能是未完整复制、导入中断或旧资源目录不完整，仍需目录／导入日志确认具体原因。

`complete.json` 是 App 在对应卷全部文件导入并校验后生成的完成记录，不是玩家需要下载或手工制作的材料。缺失时不得跳过验证或新建空文件假装完成。

## 正确操作

**本体只需要自己的 MEGA39’s XCI 和 prod.keys。DLC 已绑定在 XCI 中，随本体自动识别提取；不另设 DLC 安装入口。MOD 则使用独立 MOD 管理入口，必须先完成本体导入。** 没有 DLC 的基础 XCI 同样支持导入，空 DLC 清单由 App 生成，用户不需另找 DLC 文件或清单。

推荐在“文件”App 的“我的 iPad／iPhone → PJDVM39（或 PJDV M39）”根目录同级放置 `.xci` 和 `prod.keys`，不要把源文件塞进 `GameResources` 子目录。等待文件复制完成，回到启动首页保持前台；可自动检测，也可在资源页点“检测 App 根目录中的 XCI／密钥”（日语：アプリのルートで XCI／キーを検出）。只有显示导入完成后才能启动。

另一种方式是先“选择／更换 prod.keys”，再“导入 XCI”（XCI を読み込む），选择源文件并等导入完成。已保存有效密钥时不需每次重选。XCI 可留在外置盘，导入期间保持连接；原文件只读保留，提取输出另占空间。

“使用已拷入本机的资源”（本体にコピー済みのデータを使う）只用于从另一台设备完整复制成功导入的 `GameResources`，必须保留其清单及全部文件。完成标记在 `GameResources/romfs/complete.json`（旧布局可为 `MEGA39-v1.0.9/complete.json`）及实际 DLC 的各编号子目录里，不是放在 App 根目录。

已出现错误时：不要删存档，不要手工补空 JSON。若手里是原始 XCI，请改用 XCI 导入／根目录检测入口；若是已提取资源，请检查整份 GameResources 是否复制结束。原先导入中断的资源可以重新选择**同一 XCI**续导；身份不匹配时会停止并保留旧文件，不强制覆盖。

## 本地修改和验证

- 捕获完成标记缺失的特定 Foundation 错误，指出 `romfs/complete.json` 或 `DLC/<编号>/complete.json`，提示重新 XCI 导入／完整复制；权限或其他错误仍保留原有诊断。
- 资源页说明明确区分 XCI 导入、已提取目录与 MOD；新增文本覆盖简中、繁中、日语、英语和韩语。
- MOD 安装在后台写入／解压前验证可用本体；未完成或无本体时返回“请先使用 XCI 和 prod.keys 完成本体导入，再添加 MOD”。浏览下载仍可使用。
- `Scripts/test-resource-import.sh` 使用八个小型合成 XCI，不含商业资源或生产密钥；覆盖根目录扫描、基础包无 DLC、包内更新及 DLC、读写计数、续导与源文件不变、缺少本体／DLC 完成标记、错误身份及完整资源恢复。修复前复现 Code260，修复后全部通过。
- 全部五份 Localizable.strings 语法检查通过。编译结果以本轮候选构建日志和包清单为准；未据此宣称复现了玩家实际设备上的完整文件复制过程。

---

## English

The build21 screenshot shows a missing `complete.json` error. A bounded synthetic reproduction uses the actual importer to produce resources, removes only the test copy's base completion marker, and runs the real layout validator. The previous code throws the same **NSCocoaErrorDomain Code260**. Missing DLC completion markers follow the same path.

The copied-resources button validates a fully prepared GameResources directory; it does not extract an XCI. A loose XCI without prepared resources produces a different folder-selection message. This particular error means resource validation found preparation records but could not open a required completion marker. Interrupted imports, incomplete transfers or older partial folders are possible causes; the screenshot alone cannot distinguish them.

Base import needs only the user's XCI and prod.keys. DLC is already inside the XCI and is imported automatically; no separate DLC installer is added. Zero-DLC base XCIs remain supported. Mods use their own manager and require a complete base before installation.

Place the XCI and keys together at the top level of the Files-visible PJDVM39 folder, wait for copying to finish, return to the launch screen and keep the app foregrounded. Use automatic detection or “Detect XCI/keys in App root”. Alternatively select keys and then “Import XCI”. Wait for import completion. Do not use the copied-resources button for a raw XCI or put source files under GameResources.

For existing prepared data, copy the entire GameResources folder, including its manifests and per-volume completion markers. Do not manufacture completion JSON files or bypass validation. Retry the same XCI to resume an interrupted import; mismatched resources are preserved rather than overwritten. Original sources and saves are retained.

The candidate now gives actionable, localized missing-marker guidance; permission and unrelated errors are not replaced by that message. MOD installation checks the base before extraction/writes, while browsing/download remains available. The synthetic import suite covers no-DLC base imports, bundled DLC/updates, missing base and DLC markers, resume, unchanged sources, identity rejection and inbox discovery. The original code fails with Code260 and the candidate passes. All five localization files parse. This does not constitute a reproduction of the player's full device-transfer history.

## 最终候选检查 / Final candidate checks

iOS 与 iOS Simulator 的 Release 构建通过。独立合成资源目录的模拟器 UI 检查已确认：启动页禁止启动不完整资源，日语资源页显示缺失路径和恢复指引，新增 XCI／DLC／MOD 说明正常显示。未对真实设备的40+ GB文件复制重新测试。

Both Release builds pass. In an isolated synthetic-resource simulator UI check, incomplete resources keep Start disabled; the Japanese resource page displays the missing path and recovery instructions, and the XCI/DLC/MOD explanation renders correctly. No new full40+GB physical-device transfer was performed.
