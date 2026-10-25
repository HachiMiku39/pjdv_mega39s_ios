# Switch《MEGA39’s》MOD 导入研究 / Switch MOD import research

研究日期：2026-10-25（Asia/Shanghai）。本轮仅研究互联网资料与作者源码，**没有启用 build18 MOD 加载，没有安装或执行插件，没有更改游戏资源或 XCI**。

本报告补充 `MOD-INTERFACE-build18.md`，说明 Switch 上实际怎样放置 MOD，以及 Apple 版应移植哪些机制。

## 核心结论

Switch 版常用两层：Atmosphère 的 LayeredFS 将外部文件覆盖到游戏 RomFS；MikuMikuSwitchPlugin 在游戏内部增加资源搜索根、MOD 数据库前缀和新增内容支持。XCI 可以保持原样，MOD 作为独立差异文件保存。

| MOD 类型 | Switch 端机制 | Apple 版接入含义 |
| --- | --- | --- |
| 替换已有服装、贴图、UI、音频 | 按原游戏相对路径做 RomFS 覆盖；是否另需代码补丁取决于包自身 | 可首先实现只读资源层；不同格式、依赖仍需预检 |
| 新增歌曲／服装、`mod_` 数据库 | 专用插件插入搜索目录、扩展数据库、ID／容量与保存逻辑 | 需要宿主资源层和已验证的游戏内部适配，只有文件覆盖接口还不够 |
| PC DLL、Switch `subsdk`／ExeFS 补丁 | 各自平台的程序代码或注入补丁 | 不能直接当作 Apple 插件执行；本版不提供二进制插件加载 |
| 改进光照／抗锯齿的图形 MOD | 可能同时修改游戏程序与 BNSH/BFSHA shader | 必须另走 NVN→Metal 翻译与画面验证，不能承诺仅导入 ZIP 即生效 |

依据：[Atmosphère LayeredFS 源码](https://github.com/Atmosphere-NX/Atmosphere/blob/master/stratosphere/ams_mitm/source/fs_mitm/fsmitm_romfs.cpp)、[作者 README](https://github.com/lsmsmx/MikuMikuSwitchPlugin)、[ModLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/ModLoader.cpp)、[DatabaseLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/DatabaseLoader.cpp)。

## 已核对的版本与证据

- GitHub API 于研究当日确认 main：`13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a`，提交时间 `2026-10-24T10:46:10Z`，说明为 `hotfixes, taa added`。
- 作者标记的最新 Release 为 **Version 11**，标签 `last_big`。Release 页面包含 5 个作者附件：`main.npdm`、`subsdk9`、`README.txt`、`optimize_a3da.py`、`optimize_textures.py`。GitHub 页面另外生成源码下载，因此页面 Assets 总数可显示 7。
- API 的 `published_at` 为 `2026-10-16T21:26:01Z`，不等同于之后修改附件／说明的时间，也不证明二进制由当前 main 构建。必须区分发布附件与 main 源码。
- 读取了 Release 的 README.txt 与固定提交源码。没有下载／运行 subsdk9、main.npdm 或优化脚本。
- GameBanana 作者入口确认是 [652898](https://gamebanana.com/mods/652898)，但网页正文依赖 JavaScript，本次未核对其地区资源压缩包内部内容。不将第三方教程中的附件名、游戏版本要求或完整兼容声明当成已验证事实。
- 公开说明没有建立“日版任意版本都兼容”的依据；本项目固定 JP1.0.9 的运行程序仍需逐处指纹与预期指令校验。

元数据和只读证据保存在外置卷 `Build/ModImportResearch-20261025/`。没有真实密钥或游戏素材。

## Switch 已有 Atmosphère 环境的目录

当前项目日版 Title ID 是 `0100F3100DA46000`。作者另列英文版 `01001CC00FA1A000`、韩版 `0100BE300FF62000`，目录不能互换。下面为日版的结构示例，插件和 MOD 自身要求的游戏版本仍需分别核对。

```text
SD卡/
├── atmosphere/
│   └── contents/
│       └── 0100F3100DA46000/
│           ├── exefs/
│           │   ├── main.npdm
│           │   └── subsdk9
│           └── romfs/
│               └── mods/
│                   └── ExampleMod/
│                       ├── config.toml
│                       └── rom/
│                           ├── objset/
│                           ├── lang2/
│                           └── ...
└── MikuMikuSwitchPlugin/
    ├── config.toml
    └── Save/
```

`main.npdm` 与 `subsdk9` 使用作者匹配的发行文件；保留已有配置／插件副本再测试，避免不同插件版本混用。发布包中的 `.py` 是电脑端资源处理工具，不是 Switch 启动必需的执行模块。作者 Makefile 的模块输出名为 `subsdk9`，部署子目录为 `atmosphere/contents/$(PROGRAM_ID)/exefs`。不要直接照抄仓库模板 `config.mk` 的 PROGRAM_ID，它当前并非本项目的日版 ID。

仅做传统 LayeredFS 替换时，MOD 内容放到 `romfs/` 下的原游戏路径，例如 `romfs/rom_switch/rom/...`；使用插件时才采用上面的 `romfs/mods/ExampleMod/rom/...` 包目录。两种根目录不能混淆。

来源：[Release](https://github.com/lsmsmx/MikuMikuSwitchPlugin/releases/tag/last_big)、[Makefile](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/Makefile)、[config.mk](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/config.mk)、作者 README。

## 开关、优先级和包配置

全局文件：`sdmc:/MikuMikuSwitchPlugin/config.toml`。与 PC DivaModLoader 的全局 `mods = "mods"` 字符串不同，Switch 插件这里的 `mods` 是布尔开关。

```toml
mods = true
priority = ["ExampleMod", "SecondMod"]
```

排在前面的目录优先级更高。Config.cpp 会扫描 MOD 目录：移除已不存在的名称，将新发现的目录按名称排序后追加到已有列表末尾，并在需要时写回配置。因此新增包未必自动取得最高优先级。

每个 MOD 内的 `config.toml` 示例：

```toml
enabled = true
include = ["."]
```

`include` 是相对于该 MOD 根目录的内容子目录列表。作者当前实现对没有 config 的目录默认视为启用；TOML 解析失败则跳过该包。Apple 导入器将来应明确显示解析失败与依赖状态，不能静默报告成功。

来源：[Config.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/Config.cpp)、[ModLoader.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/ModLoader.cpp)。

## PC MOD 的哪些部分可以沿用

当前 Switch 加载器识别 `rom`、`rom_steam/rom` 和 `rom_steam_en/rom`。这是目录结构支持，不是全部 PC MOD 的运行兼容保证。

- 保留 `config.toml`、`rom` 与 `mod_` 数据库的原始关系，不按旧教程一律删前缀或合并回原版数据库。
- 新曲目通常需要谱面、音频、场景、动作以及相关数据库记录一起成立；数据库中的 ID 冲突仍需解决。
- 新版通过 MdataMgr 的路径标记解析 MOD 专用数据库；新增内容还涉及 PvLoader、StrArray、SpriteLoader、保存系统和容量修正，不只是替换 pv_db 一个文件。
- `.dll` 声明属于 PC 加载器的代码扩展；Switch ModLoader 的目录处理并不提供 Windows DLL 执行能力。Apple 版也不直接加载这些文件。
- 作者要求部分视频 MOD 做 USM→MP4 转换并修改 pv_db 的引用。改后缀不会改变容器和编码；具体播放能力要在当前宿主解码器验证，不能把禁用全部 PV 当成所有设备的固定要求。
- 缺失包要求的 DLC、素材或代码依赖，需要具体报告，不把“作者插件支持 mod_”等同于“任意包在当前资源组合都能运行”。

来源：[PC DML 文档](https://github.com/blueskythlikesclouds/DivaModLoader)、[DatabaseLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/DatabaseLoader.cpp)、[PvLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/PvLoader.cpp)、作者 README。

## 源码研究发现的适配陷阱

以下是代码检查得到的结论或推断，未作真实 Switch MOD 安装验收。

1. **`mods=false` 不等于完全无插件。** 它会停止 MOD 包目录的加载，但 `exl_main` 和 MainHook 仍安装／初始化数据库、保存、内存、图形等功能。做原版画质和性能 A/B 时，要区分“包禁用”与“插件完全未加载”。
2. **地区目录探测不是可靠身份验证。** Config 按 JP、EN、KR 顺序找第一个存在的内容目录。若同时存在多个地区目录，这种方式不能代替读取当前游戏身份。Apple 宿主应使用导入 XCI 的明确 Title ID 和固定程序指纹。
3. **共同资源和地区资源不能随意扁平化。** 当前 ModLoader 在检测到 Steam 地区目录后选择一个对应根；StrArray 却从 modDirectoryPaths 的 `rom/lang2` 读取字符串。由此推断：只含地区目录、或同时混用共同／地区资源的包，必须分别验证其搜索和字符串来源。不能仅凭目录存在就宣布语言和素材全部兼容。
4. **图形 MOD 与 shader 缓存耦合。** 作者 FT Restoration 工具处理 BNSH/BFSHA 并重编译片元着色器。我们的 Apple 版需重新走 NVN→Metal 转换并验证绑定／反射与缓存身份，单纯覆盖文件可能仍使用旧缓存或缺少对应 shader。
5. **解除 ID 上限不会解除物理内存限制。** 上游包含内存池回退、稀疏高 ID 分配和贴图／a3da 处理工具。M1 等设备仍需按实际包统计内存与加载成本，不能把顺序存储速度当成全曲库扩展能力。

来源：[main.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/main.cpp)、Config、ModLoader、[StrArray.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/StrArray.cpp)、[MemoryHooks.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/MemoryHooks.cpp)、[FT Restoration](https://github.com/lsmsmx/Megamix-FT_Restoration)。

## 对本项目的接入建议（尚未实现）

建议将来在文件 App 暴露的 PJDVM39 根目录旁设 `Mods/`：

```text
PJDVM39/
├── GameResources/       # 原有提取资源，保持只读
├── Mods/
│   └── ExampleMod/
│       ├── config.toml
│       └── rom/
└── ModProfiles/         # 后续独立 MOD 组合配置与测试档命名空间
```

这是设计提案，当前 App 不会自动扫描或加载这些目录。

先支持两种包结构的识别：标准 Switch LayeredFS 包与 `config.toml + rom` 类 DML 包。导入时建立清单、路径规范化、身份和依赖记录；只提取 MOD 差异文件，不复制或重打 40GB XCI。第三方 ExeFS／DLL 模块应明确标为暂不支持，而非静默跳过后声称整个包兼容。

第一阶段只做已有资源替换，复用 build18 的只读查询接口，并保证目录列举、存在性检查和打开文件一致；先验证一套服装／贴图及停用回原版。内置手柄图标、退出菜单、低配纹理覆盖与用户包的冲突需明确处理。

第二阶段再增加 `mod_` 数据库、字符串与曲库／服装扩展，适配当前 JP1.0.9 的指纹和原始指令。按 MOD 组合隔离保存数据、处理重复 ID、初始化和关闭顺序；增加歌曲不等于解锁未提供的资源。

图形 MOD 单独作为后续阶段，先在 Mac 验证 NVN→Metal 新着色器及缓存失效，再在 iPad 验证内存和帧时间。不得把上游 DLL／subsdk9 直接注入本项目。

本轮重新读取本地接口实现：注册仍返回 DISABLED，能力／provider 数仍为 0，查询仍回落原路径。没有修改该实现，也未改动已有构建和安装包。

## English summary

Research date: October25,2026. No MOD was enabled, installed or executed. Original XCI and extracted resources are unchanged.

Switch modding uses two related layers: Atmosphère LayeredFS for file replacement, and MikuMikuSwitchPlugin for guest search roots, mod-specific databases, new content and supporting patches. Japanese Mega39s uses title0100F3100DA46000. Plugin files go under the title's exefs directory; plugin-managed packs live under romfs/mods/PackName with config.toml and rom content. Global configuration lives at sdmc:/MikuMikuSwitchPlugin/config.toml. Its mods key is Boolean, unlike the PC loader's directory string. Earlier priority entries win; newly discovered folders are appended.

Current main is pinned to13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a. The latest-labelled release is Version11/last_big; release publication time does not prove its binaries match current main. Published attachments were checked through the public API; only README text was downloaded. The GameBanana author's JavaScript-only installation details and regional resource archives were not verified.

Preserve mod_ databases. PC DLLs and Switch executable modules cannot execute directly in the Apple host. Steam-region folder recognition alone does not prove format, database, localization or shader compatibility. USM footage requires actual conversion and matching database references. Base/DLC dependencies and duplicate content IDs remain important.

Code inspection shows that mods=false disables pack discovery but leaves other plugin hooks installed; it is not a clean no-plugin baseline. Region selection by the first existing directory is weaker than actual title identity. Common and region-specific roots, string-array discovery, shader caches and memory usage need separate validation.

For PJDV M39, start with reversible read-only replacement of existing assets. Add database/song expansion only after fingerprint-verified guest adaptation and isolated saves. Graphics restoration requires a separate NVN-to-Metal pipeline. The suggested Mods and ModProfiles folders are proposals only; build18 continues to refuse provider activation.
