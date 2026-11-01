# Eden 包与存储检查 / Eden packages and storage audit

2026-11-01。本轮为本地研究与导入存储优化；**没有发布新安装包，也没有将 Eden 全套导入或宣称全套可玩。**

## 找到的内容

Steam 的 `mods` 目录里有 15 个 Eden Project 包，共 5,541 个文件，逻辑大小约 **14.65 GiB**，exFAT 分配空间约 **15.70 GiB**。这是 PC Mega Mix+ 的 Eden Project，不是 Eden 模拟器的 Mod 格式。

| 类别 | 本地包 | 检查结果 |
| --- | --- | --- |
| 以视频 PV 为主的 9 包 | Beginner、Catchy Pop、Club Mix、Dark、Heavy Metal、High Octane、Masochist、Rock、Vibes | 共 176 条 PV 记录，175 条明确标注 `movie_pv_type=ONLY`；歌曲编号全部超过 999。不能把整包都当作已经验证过的纯视频格式。 |
| 3D／编辑 PV 的 4 包 | Edit PV、F2nd、Masochist Edit、X | 涉及舞台、Auth3D、动作、灯光等；F2nd 另声明 `pv701.dll`。视频转码不能代替这些功能。 |
| Core | EdenProject_Core，内层配置版本 1.0.3 | 混合原曲覆盖、额外谱面、歌词、资源与 PC 插件。声明的 `DLCChecker.dll`、`OldMan.dll`、`SaveDataMigrator.dll` 不在本地包中；另外两个插件文件存在，但都没有执行。254 条 PV 记录包含原曲覆盖，不能算作 254 首新增歌曲。 |
| 模型 | EdenProject_Module，No OPD 1.3 | 有 129 条服装记录，但没有独立 `mod_obj_db.bin`／`mod_tex_db.bin`。现有原生模型识别器不能直接接受。 |

模型包本地说明明确写着 **Standalone Module Pack**，因此不能把“缺少独立登记表”直接等同于“必须安装 Core”。本轮比对发现，模型包的 206 个对象归档名称没有与本地 Core 的对象归档登记对应；按对象集合名称比较，Switch 原始数据库匹配其中 7 个。此比较不足以判定包损坏，说明仍需追踪 PC 基线登记、归档内部对象及服装引用，不能盲目拼接 Core 数据库。

作者的 [Core 页面](https://gamebanana.com/mods/478684) 将 Core 列为其曲包依赖；[模型包页面](https://gamebanana.com/mods/456470) 是单独发布项。网页当前版本与本地旧包不同，不能混用版本后就视为依赖已满足。[DIVA Mod Loader](https://github.com/blueskythlikesclouds/DivaModLoader/blob/master/README.md) 的资源覆盖、数据库追加和 DLL 插件也是不同机制；本项目不会执行 Windows DLL。

## 如何接入本项目

1. **先做视频曲包的稳定编号转换。** 当前原生视频歌曲导入器只接受 1–999；Eden 这 9 包的编号需要持久映射，并同步处理 PV 数据、列表、封面、歌词及成绩身份。不能仅改文件名或临时换成 NORMAL；勾选顺序、包升级及组合变化都不应串成绩。
2. **按曲目解析所需的 Core 资源与能力。** 保留曲包依赖的共享资源，避免每个包重复复制整份 Core；原曲覆盖、额外谱面和多语言歌词需分别处理。先验证某一曲包依赖闭包，再扩展其他包。
3. **模型单独解析，避免强制绑定 Core。** 先从服装、部件和归档内部结构核对对象／纹理登记来源，再决定是否需要 PC 基线元数据。缺失或有歧义的引用明确拒绝，不生成空模型。
4. **3D／编辑 PV 后续逐项移植。** 舞台、动作、Auth3D、OPD、特效和代码补丁都有独立边界，不能因为音频／视频可播放就标为完成。

此前 9 包各一首的视频／音频／音符推进抽样仍有效，但那是开发侧临时重映射的试验，**不是本轮 App 内整包自动导入、封面／歌词完整性、整曲结算或正常存档的证明**。详见 [既有逐包矩阵](LOCAL-MOD-MATRIX-20261031.md)。上一轮新下载样本的 App 原始 ZIP 转换与组合结果见 [原生资源 MOD 报告](NATIVE-RESOURCE-MODS-20261101.md)。

## 已完成的空间优化

- 只处理开发卷 `Build` 中不在当前数据目录使用的测试媒体。排除原始 XCI、用户 Steam Mod、游戏基线、存档、当前 Mac／模拟器数据、App、源码及工具链；跨范围硬链接也不处理。
- 按大小筛选，再做完整 SHA-256；将确认完全相同的独立测试文件改为 APFS 写入时复制克隆。保留文件路径、字节、修改时间、权限与元数据；原有测试内的硬链接关系保留。不是用符号链接指向用户源文件。
- **554 个路径**完成处理，随后全部重新读取校验。该步骤实测开发卷可用空间约 **5.00 → 8.58 GiB**，增加约 **3.59 GiB**。之后编译和测试会继续使用空间，此数字不是 Samsung 整盘的净变化或未来保证。
- Samsung 主分区检查时仍有约 **437 GiB** 可用。没有删除、移动或重写那里的原始 Mod、XCI、分卷包及无关文件。

两个旧导入测试目录的 `du` 合计约 78.4 GiB，但 **不能直接称为可回收 78.4 GiB**。开发卷上存在克隆及硬链接，账面目录大小会重复计算共享数据。它们本轮保留。XCI 与解压资源也是不同用途，不能因为已有解压资源就自动删除原始包。

## 减少后续导入的重复写入

本地源码已修改：

- 同卷支持时，文件夹导入和转换器的原样资源副本优先使用 APFS 克隆；副本有独立 inode，源文件后续原地修改不会污染已导入内容。
- exFAT、跨卷或不支持克隆时继续按块复制。APFS 不会自动去重任意重复写入的文件，跨卷也不能靠克隆省掉实际拷贝。
- 保留完整读取／哈希校验、取消、失败回滚和源文件变化检查。容量预检仍按保守的完整副本需求计算，未用“预计克隆成功”放宽容量限制。
- ZIP 仍需展开一次；成功转换后已有流程会清除本次导入器拥有的临时展开目录，源 ZIP 保留。视频转码会生成另一种编码的文件，不能将它与 USM 当作字节相同的重复文件。
- 组合层已对可复用的 App 内资源使用共享文件；不会为每个 Mod 再解压一整份 XCI。未新增自动删除旧包或存档的策略。

验证：安装器的 ZIP／文件夹、损坏数据、取消和路径回归通过；APFS 原地修改隔离、拒绝覆盖及实际 exFAT→APFS 复制回退通过，合成安装器进程峰值 RSS 约 13.7 MiB。模型和歌曲转换回归通过。Mac Catalyst、iOS 真机目标与模拟器编译通过；**没有在本轮重新做 iPad／iPhone 真机导入或 Eden 整包游玩验收**。

Apple 参考：[APFS 的克隆和写入时复制](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html)、[卷的文件克隆能力查询](https://developer.apple.com/documentation/foundation/urlresourcekey/volumesupportsfilecloningkey)。

## English

This is a local investigation and storage change, **not a new release or acceptance of the complete Eden collection**. The Steam library contains 15 PC Eden Project packages: 5,541 files, approximately 14.65 GiB logical and 15.70 GiB allocated on exFAT. They are unrelated to the Eden emulator's general Mod format.

Nine predominantly video-PV packs contain 176 PV records, 175 explicitly movie-only, all with IDs above 999. Four more packs use 3D/edit stages and motion dependencies. Core's local inner configuration is version 1.0.3; three declared DLLs are absent. Its 254 PV records include overrides of existing songs, not 254 new songs. No DLL was executed.

The No OPD 1.3 module pack contains 129 costume records without standalone object/texture registries. Its own description calls it standalone. None of its 206 object archive names matched the local Core archive registrations; seven object-set names matched the native Switch databases. This does not establish a broken package or prove Core is required. PC-baseline registrations, archive internals and costume references still need tracing. Author pages and DML's documentation are linked above; current website versions differ from the local copies.

The next conversion work is persistent song-ID allocation, synchronized PV/list/jacket/lyric/save identity, and per-song shared-resource dependencies. It must survive selection order and upgrades without mixing scores. Model registration is a separate investigation. Real-time 3D stages, Auth3D, motions, physics and patches need their own adapters. Earlier nine-package gameplay samples used developer-only chart remapping and do not establish complete in-App import or normal persistence.

For storage, only inactive test-media files inside the development volume's Build directory were compacted. Full SHA-256 matching preceded copy-on-write replacement. All 554 paths, contents, modification times and metadata were preserved, including existing test-local hard-link groups. Full final readback passed. Free development-volume space increased from about 5.00 to 8.58 GiB, approximately 3.59 GiB during that step. Samsung's main partition had roughly 437 GiB available. Original XCI, Steam Mods, game baselines, saves, current data directories, applications and unrelated exFAT files were untouched. Old import fixtures showing 78.4 GiB in directory accounting were retained; shared extents mean that number is not an expected reclaim estimate.

The source candidate now prefers APFS clones for folder-import and converter payload copies, with independent inodes. Editing a source in place does not change its imported copy. Cross-volume/exFAT paths retain bounded streaming, hashing, cancellation and rollback. Space preflight remains conservative. ZIP extraction and video conversion still require their own output; encoded USM and MP4 are not byte-identical duplicates. Existing successful conversions remove only their importer-owned temporary extraction. Original downloads and saves are retained.

Installer, actual APFS/exFAT isolation/fallback, model and song regressions passed. The synthetic installer process peaked at about 13.7 MiB RSS. Mac Catalyst, iOS device-target and Simulator builds passed. Physical-device import and complete Eden playback were not tested again in this round. This source candidate remains unpublished.
