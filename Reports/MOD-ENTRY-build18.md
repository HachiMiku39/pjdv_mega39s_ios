# build18 MOD 入口 / MOD entry

2026-10-25。启动页新增“MOD 管理（实验）”。这是手动结构检查与位置登记功能，**没有接通游戏 MOD 加载**，运行层 provider 仍固定关闭。

## 当前行为

- 添加普通 ZIP、ZIP64 或已解压文件夹；只读取目录信息，不复制源包、不解压、不修改游戏资源。
- 识别 Switch RomFS／LayeredFS、`rom` 或 `rom_steam[_en]/rom` 类插件包，以及混合包／仅代码补丁。显示文件数、目录声明的总大小及“未启用”状态。
- 标记代码补丁、其他地区 Title ID 和 `mod_` 数据库。这是结构信息，不代表地区身份、依赖或运行兼容性已验证。
- 只保存源位置书签及检查结果。可重新检查或移除登记；移除登记不会删除原文件。
- ZIP 仅读中央目录：不解压载荷、不验证 CRC，也不检查 TOML 语义。7z／RAR 需先解压，再添加文件夹；加密／分卷 ZIP 暂不接受。特殊 ZIP 压缩方法只登记并显示需先解压提示。
- 拒绝越界路径、目录大小写冲突、文件／目录冲突、符号链接和特殊文件。上限为50000条目、32MiB ZIP目录、8MiB路径名与32MiB路径索引预算；总声明展开大小上限128GiB。解析按有界元数据进行，避免读取大包全部内容。
- 五种本地化同步；启动页改为可滚动布局，避免横屏小窗口加入新入口后挤掉原设置。

入口不扫描 XCI／密钥根目录，不更改原来的自动导入。只有用户手动选中的 MOD 会检查；实际资源读取、曲库、存档、着色器均不经过登记记录。

## 常见格式

| 层次 | 示例 | 本版处理 |
| --- | --- | --- |
| 下载容器 | ZIP／7z／RAR | ZIP和ZIP64目录检查；7z/RAR先解压 |
| Switch资源覆盖 | `atmosphere/contents/<TitleID>/romfs/...`、`romfs/rom_switch/rom/...` | 检查登记，未启用 |
| 插件式资源包 | `config.toml + rom/...`，或地区资源根 | 检查登记，未解析配置和启用 |
| 实际游戏素材 | FARC、BIN、TXT等 | 作为完整包中的路径识别，不将裸素材当完整安装包 |
| 程序扩展 | `exefs/subsdk9`、`main.npdm`、IPS、DLL等 | 标为代码内容，不执行 |

来源：[MikuMikuSwitchPlugin](https://github.com/lsmsmx/MikuMikuSwitchPlugin)、[DML](https://github.com/blueskythlikesclouds/DivaModLoader)、[ZIP格式说明](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)。目录检查不是压缩解码器或兼容认证。

## 代码与测试

`Sources/ModPackage.swift`：有界目录检查、格式识别、书签登记。
`Sources/ModImportController.swift`：启动页管理界面与平台文件选择。
`Scripts/test-mod-packages.sh`：纯合成包，ASan检查ZIP/ZIP64、文件夹、越界／大小写／符号链接／损坏／数量上限／取消、150次元数据变异、登记去重和移除后源文件不变。没有真实游戏素材。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PJDV_TEST_ROOT="/Volumes/你的外置APFS盘/ModPackageTests/new-run"
bash Scripts/test-mod-packages.sh
```

输出目录必须尚未存在。实际运行结果、Mac／iOS构建和界面核验记录位于外置SSD的 `Build/ModEntry-20261025/VERIFICATION.json`；不能把Mac文件选择通过写成iPad真机验收。

## English

The launcher now has MOD Manager (Experimental). It manually inspects/registers ZIP, ZIP64 and extracted folders without copying, extracting, enabling or injecting MODs. Game resources, saves and the disabled runtime provider are unchanged.

The manager recognizes Switch RomFS layouts, plugin-style rom/Steam-region roots, mixed packages and code-only patches. It labels executable content, other declared title IDs and mod_ databases. These are structural findings, not compatibility or dependency validation. ZIP payload CRC and TOML semantics are not checked. Extract 7z/RAR externally; encrypted/split ZIPs are rejected. Unusual ZIP methods require extraction before future use.

Only source bookmarks and inspection metadata are stored. Reinspect or remove a registration without deleting the source. Traversal, case/file-directory conflicts, links and special files are refused. Entry/path/central-directory budgets bound metadata work. The launcher scrolls on smaller landscape windows and all 5 localizations include the feature.

Synthetic ASan tests cover valid layouts, ZIP64, malformed metadata, cancellation, 150 mutations, bookmark round trips, deduplication and source preservation. Platform builds and actual UI checks are recorded separately; no real MOD playback is claimed.
