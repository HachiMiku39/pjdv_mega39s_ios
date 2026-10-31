# 本地 MOD 全清单抽测 / Local MOD inventory and representative tests

2026-10-31，本地候选；公开安装包仍为 build19。此报告记录开发者检查，不加入玩家 MOD 管理界面。

## 范围与方法 / Scope

本地共 **50 个文件夹、38,640,153,491 字节**，其中包含重复副本、Windows 插件和配置模板，并非 50 个可独立游玩的曲包。全部完成目录、配置和类型预检；3,831 个 FARC 头通过边界检查，**不是所有归档内容的全量解压校验**。能够适配的内容按每包一个模型／一首歌抽样，无法安全转换的包记录具体原因，不将“转换完成”记为“能玩”。

本机 iPad Pro 11 英寸 M5 模拟器 / iPadOS 27.2，宿主 M3 Max / 64 GiB。全部输出在外置 SSD，使用独立测试资源覆盖层和 AutoPlay 临时存档；原始 PC MOD、XCI 和个人存档未改写。不是 M1／8 GB 或真机性能验收。

The inventory covers **50 folders / 38,640,153,491 bytes**, including duplicates, Windows plugins and an empty template. All received configuration/type checks; **3,831 FARC headers** passed bounded inspection, not full payload validation. Runtime checks sample one model or song per supported package. Unsupported conversion is reported explicitly, never counted as playable. Tests use the local M5 iPad Simulator (iPadOS 27.2) on M3 Max/64 GiB, external-SSD overlays and disposable AutoPlay saves. Original packages, XCI and personal saves are unchanged. This is not physical-device/M1/8 GB acceptance.

## 新模型 / New model samples

MORE MORE JUMP!：Hanasato Minori；Nightcord：Yoisaki Kanade；Vivid BAD SQUAD：Azusawa Kohane；Rage Winter 2020 Miku，均在《愛言葉》实际演奏画面中确认身体、服装与动作可见。**本轮四包使用开发者默认服装覆盖预览，未验收追加服装菜单、名称或缩略图。** 原有四模型包与 X Song 的 App 内独立多选／组合结果见[前一份报告](MOD-NATIVE-MULTISELECT-20261031.md)。

The four new samples were visible during actual Aikotoba gameplay, including bodies, costumes and animation. **These are developer default-costume overrides, not acceptance of additive module UI, names or portraits.** The linked earlier report separately covers native App selection/composition of X Song and the previous four model packages.

Rage Winter 第二副本的全部 104,811,283 字节资源载荷与首个测试副本相同，只有 `mod.json` 不同。DECO27 发现同一纹理 ID 对应不同图像（4744142、4240717）；Sekai Anniversary 的 87450 也有歧义，均拒绝盲目编号替换。EdenProject_Module 这份本地包没有独立对象／纹理登记表，其 Core 依赖尚未解析，不能按通用模型包直接转换。

The second Rage Winter copy has identical payload bytes (104,811,283), with a different `mod.json`. DECO27 has distinct textures sharing IDs 4744142/4240717; Sekai Anniversary similarly conflicts at 87450. Conversion rejects ambiguous global remapping. This local EdenProject_Module copy lacks standalone object/texture registries and still needs Core dependency resolution.

## 视频曲包与载入 / Video packs and loading

每包选择一个原始视频／OGG／谱面，离线将支持的未加密 USM / IVF / VP9 转为 H.264 MP4。10 首完整输出的编码、分辨率、帧数和时间戳已核对；源帧率保持 20、24、29.97 或 30 FPS，**游戏显示约 60 FPS 不代表源视频获得新帧**。谱面在独立测试中映射到 NORMAL 标签，实际来源难度在下表记录，不是宣称源包 NORMAL 已通过。封面、标题 Logo、全曲结算与包内其他歌曲不在这些新样本的验收范围。

纯视频 PV 采用原版视频 PV 的隐藏角色／舞台／动作初始化；直接沿用 PC 测试姿势曾造成等待／烘焙动作解码崩溃。此修正不适用于实时 3D PV。10 首代表资产使用电脑生成的独立组合，**不能据此宣称 App 已能任意导入原始 PC 包**。公开的流式离线辅助工具为 [usm_video.py](../Tools/pc_mods/usm_video.py)，转码不修改源文件，输出可能变大。详细性能测量与限制见[载入优化](LOADING-OPTIMIZATION-20261031.md)。

Each sample uses one original movie/OGG/chart. Ten complete supported unencrypted USM/IVF/VP9 streams were converted to H.264 MP4 and checked for codec, size, frames and timing. Source 20/24/29.97/30 FPS remains unchanged; a 60 FPS game display does not create video frames. Source charts are exposed under NORMAL only in the developer fixture; the actual source difficulty is listed below. Covers, logos, full-song completion and other songs are not accepted by these samples. Pure-video initialization follows a native movie-only PV; PC test-pose dependencies had caused waits/baked-motion decode failure. This is never a replacement for real-time 3D assets. The representative combination was prepared offline and does not prove native raw-PC import. See the linked helper and loading report.

## 歌词、人声与菜单音乐 / Lyrics, vocals and BGM

Chinese Base／DLC 只抽取歌词差量，配对原包字体 15 图集与字符映射；合并 9,326 条歌词，源歌词字符离线检查没有缺字。基础《愛言葉》和 DLC《ワールドイズマイン》已在实际打歌画面显示中文。不是全部字体、全部语言、曲名或帮助图验收。Proseka Another Vocal 用《ミラクルペイント》的 WXS 音轨，保留原版舞台和谱面；文件读取、非零音频输出与游戏推进通过，未完成全人声组真人听感对照。

五个 Project Sekai 菜单音乐包共 15 个 OGG 均完整解码通过。Original 与 1st 已观察到游戏菜单读取和非零音频输出；其余仅记离线音频检查，不记实际菜单验收。它们替换相同 BGM 路径，互相是替换关系，不能五包同时输出五种音乐。

Chinese Base/DLC applies lyric-only deltas with the matching font15 atlas/map: 9,326 entries, no missing source lyric codepoints in the offline glyph check. Chinese lyrics appeared in actual base Aikotoba and DLC World Is Mine gameplay. This does not accept every font/language/title/help image. Proseka's WXS Miracle Paint audio was read during original-stage/chart gameplay with nonzero renderer output; complete vocal-bank listening parity remains untested. All 15 OGGs across five menu BGM variants decoded completely offline. Original/1st also reached menu reads and nonzero audio; the other three are not runtime-accepted. All replace shared paths and are mutually alternative BGM choices.

## 仍不能直接使用 / Remaining incompatibilities

- F／F2nd／X Charts、GhostRule Console、DK 的 NC 谱面需要 New Classics 原生玩法：目前未实现，原版 AutoPlay 不证明新玩法判定正确。
- F2nd Song《SPiCa》此前 Auth3D 载入崩溃尚未修复；X Song 的 Calc 倒置仍保留为已知问题。
- Eden Edit／F2nd／Masochist Edit／X 涉及 3D 场景、动作与依赖，当前没有验收过的完整转换方案。Eden Core 混合配置和 Windows 插件，另外缺少三个声明的 DLL 文件，未移植。
- ThumbnailSplitter、CustomizationPoses、ExPatch、HighFrameRate、ScalingFix 是 Windows x86/x64 插件，不执行它们。MissingEditMotionsOPD 是约 15.7 GB 动作支持数据；检查到 PC `.opd` 与原生 `.opdi` 不是直接换名关系，只做归档预检和一个 416 条目的归档解析，未整包复制运行。

F/F2nd/X Charts, GhostRule Console and DK NC charts require a native New Classics mechanics implementation. Original AutoPlay does not validate those rules. SPiCa's Auth3D crash and Calc's inverted MV remain unresolved. Eden's 3D/edit packs and Core still require native stage/motion/dependency work; Core also has three absent declared DLLs. Windows plugins are never executed. The 15.7 GB MissingEditMotionsOPD utility received header checks and one 416-member archive parse only: PC `.opd` cannot simply be renamed to native `.opdi`, and the whole set was not copied into the game.

<!-- GENERATED_MATRIX -->

## 逐包结果 / All 50 folders

| 包 / Package | 结果 / Result | 样本或边界 / Evidence and limit |
| --- | --- | --- |
| !  ThumbnailSplitter | Windows 插件 / Windows-only plugin | Windows PE x86/x64; not loaded or executed on Apple ARM |
| 001.Chinese lyrics DLC | 实际抽样 / Runtime sample | PV3 ワールドイズマイン |
| 003.Chinese lyrics Base | 实际抽样 / Runtime sample | PV48 愛言葉 |
| alocin Song Pack (2) | 视频演奏抽样 / Video gameplay sample | バッドシャーク; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| CustomizationPoses | Windows 插件 / Windows-only plugin | Windows PE x86/x64; not loaded or executed on Apple ARM |
| DECO27 Module pack | 拒绝歧义转换 / Ambiguous conversion rejected | ambiguous different textures sharing a source texture ID; unsafe global remap refused |
| DK Koshitantan and Pomp and Circumstance 3DPV and NC chart Port | 缺玩法 / Requires New Classics | new gameplay mechanics not implemented; not accepted as vanilla charts |
| EdenBeginnerPack | 视频演奏抽样 / Video gameplay sample | あの夏のいつかは / 那个夏天的某日; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenCatchyPopPack | 视频演奏抽样 / Video gameplay sample | うっせぇわ / 吵死了; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenClubMixPack | 视频演奏抽样 / Video gameplay sample | 魔法未来 SPECIAL MEGAMIX; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenDarkPack | 视频演奏抽样 / Video gameplay sample | Sister’s ∞ mercY; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenEditPVPack | 需适配 / Needs adaptation | 3D stages/Auth3D/motions and native dependency conversion not accepted; PC DLLs not executed |
| EdenF2ndPack | 需适配 / Needs adaptation | 3D stages/Auth3D/motions and native dependency conversion not accepted; PC DLLs not executed |
| EdenHeavyMetalPack | 视频演奏抽样 / Video gameplay sample | ぬる / NULL; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenHighOctanePack | 视频演奏抽样 / Video gameplay sample | Bad ∞ End ∞ Night; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenMasochistEditPack | 需适配 / Needs adaptation | 3D stages/Auth3D/motions and native dependency conversion not accepted; PC DLLs not executed |
| EdenMasochistPack | 视频演奏抽样 / Video gameplay sample | すーぱーぬこになれんかった / 还是没能成为超级喵; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenProject_Core | 需适配 / Needs adaptation | mixed PC profiles and plugins; 3 declared DLL files absent; no native Core port |
| EdenProject_Module | 需适配 / Needs adaptation | no standalone object/texture registries in this local package; Core dependencies not resolved |
| EdenRockPack | 视频演奏抽样 / Video gameplay sample | ベノム / 猛毒; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenVibesPack | 视频演奏抽样 / Video gameplay sample | 心予報 / 心预报; video/OGG/notes advancing; one source chart remapped to NORMAL in developer-only matrix; no covers/logos/full-song acceptance |
| EdenXPack | 需适配 / Needs adaptation | 3D stages/Auth3D/motions and native dependency conversion not accepted; PC DLLs not executed |
| ExPatch | Windows 插件 / Windows-only plugin | Windows PE x86/x64; not loaded or executed on Apple ARM |
| F Charts Pack | 缺玩法 / Requires New Classics | new gameplay mechanics not implemented; not accepted as vanilla charts |
| F2nd Charts Pack | 缺玩法 / Requires New Classics | new gameplay mechanics not implemented; not accepted as vanilla charts |
| F2nd Song Pack 1.03 | 已知崩溃 / Known runtime failure | SPiCa Auth3D loading crash remains; previous 2026-10-30 retest |
| GhostRule - Console | 缺玩法 / Requires New Classics | new gameplay mechanics not implemented; not accepted as vanilla charts |
| High Frame Rate | Windows 插件 / Windows-only plugin | Windows PE x86/x64; not loaded or executed on Apple ARM |
| LeoNeed Module Pack | 此前实际抽样 / Earlier runtime sample | Hoshino Ichika |
| MeltF2ndPatch | 需适配 / Needs adaptation | full PC replacement databases lack a scoped native delta profile |
| MissingEditMotionsOPD | 归档检查 / Archive probe only | 816 FARC headers and one 416-entry archive parsed; PC .opd/native .opdi mapping not implemented; no 15GB runtime copy |
| MORE MORE JUMP! Module Pack | 模型演奏预览 / Model gameplay preview | Hanasato Minori; one model on PV48; developer default-costume override, not additive module UI acceptance |
| Nightcord at 25-00 Module Pack | 模型演奏预览 / Model gameplay preview | Yoisaki Kanade; one model on PV48; developer default-costume override, not additive module UI acceptance |
| Project Sekai Colorful Stage (Original) | 音频离线通过 / Offline audio valid | 3/3 OGG files completely decoded; Original and 1st also observed menu read/nonzero audio; other variants not runtime-accepted |
| Project Sekai Colorful Stage 1st Anniversary | 音频离线通过 / Offline audio valid | 3/3 OGG files completely decoded; Original and 1st also observed menu read/nonzero audio; other variants not runtime-accepted |
| Project Sekai Colorful Stage 2nd Anniversary | 音频离线通过 / Offline audio valid | 3/3 OGG files completely decoded; Original and 1st also observed menu read/nonzero audio; other variants not runtime-accepted |
| Project Sekai Colorful Stage 3rd Anniversary | 音频离线通过 / Offline audio valid | 3/3 OGG files completely decoded; Original and 1st also observed menu read/nonzero audio; other variants not runtime-accepted |
| Project Sekai Colorful Stage 4th Anniversary | 音频离线通过 / Offline audio valid | 3/3 OGG files completely decoded; Original and 1st also observed menu read/nonzero audio; other variants not runtime-accepted |
| Proseka Another Vocal pack (base game) | 实际抽样 / Runtime sample | PV14 ミラクルペイント WXS audio |
| Racing_Miku_2026 | 此前实际抽样 / Earlier runtime sample | Racing Miku 2026 Alt. |
| Rage Winter 2020 Miku | 模型演奏预览 / Model gameplay preview | Rage Winter 2020 Miku; one model on PV48; developer default-costume override, not additive module UI acceptance |
| Rage Winter 2020 Miku (2) | 重复资源 / Duplicate payload | all 104811283 payload bytes match tested first copy; mod.json differs |
| ScalingFix | Windows 插件 / Windows-only plugin | Windows PE x86/x64; not loaded or executed on Apple ARM |
| Sekai Anniversary Module Pack | 拒绝歧义转换 / Ambiguous conversion rejected | ambiguous different textures sharing a source texture ID; unsafe global remap refused |
| Sekai Miku ( Brand New World Ver ) | 此前实际抽样 / Earlier runtime sample | L/N Brand New World Miku |
| Sekai Mini Pack 6 | 此前实际抽样 / Earlier runtime sample | 3rd Anni Ichika |
| Template Mod | 空模板 / Empty template | configuration only; no playable payload |
| Vivid BAD SQUAD Module Pack | 模型演奏预览 / Model gameplay preview | Azusawa Kohane; one model on PV48; developer default-costume override, not additive module UI acceptance |
| X Charts Pack | 缺玩法 / Requires New Classics | new gameplay mechanics not implemented; not accepted as vanilla charts |
| X Song Pack | 此前实际抽样 / Earlier runtime sample | Ai Dee NORMAL: 458 COOL / 458 combo; Calc inverted MV unresolved |

## 视频样本记录 / Video sample records

每行仅表示已看见视频、音符和游戏进度推进，不代表全曲结算。片段中没有出现 COOL 字样时记录可见分数。Every row is a gameplay excerpt, not completion; a visible score is used where no COOL count was captured.

| 包 / Package | 原 PV / Source PV | 来源难度 / Source chart | 抓帧判定或得分 / Visible evidence | 抓帧 RAM / Captured RAM |
| --- | --- | --- | --- | --- |
| alocin Song Pack (2) | 4950 | hard | COOL 101 | 731.7 MB |
| EdenBeginnerPack | 1013 | hard | COOL 61 | 722.9 MB |
| EdenCatchyPopPack | 1003 | hard | score 72510 | 711.6 MB |
| EdenClubMixPack | 1032 | extreme | COOL 207 | 746.3 MB |
| EdenDarkPack | 1117 | hard | score 70706 | 736.3 MB |
| EdenHeavyMetalPack | 1210 | easy | score 4000 | 729.3 MB |
| EdenHighOctanePack | 1194 | hard | COOL 101 | 750.8 MB |
| EdenMasochistPack | 1131 | easy | COOL 22 | 726.8 MB |
| EdenRockPack | 1172 | hard | COOL 20 | 734.3 MB |
| EdenVibesPack | 1199 | extreme | COOL 27 | 737.0 MB |

RAM 为模拟器当时的 App 浮窗读数，不是峰值、真机或内存泄漏测试。Simulator overlay readings are neither peak RSS nor physical-device/leak acceptance.

## 实际游戏截图 / Actual gameplay captures

![ 001.Chinese lyrics DLC — PV3 ワールドイズマイン](images/local-mod-20261031/Matrix-Chinese-DLC-lyrics-small.jpg)

![ 003.Chinese lyrics Base — PV48 愛言葉](images/local-mod-20261031/Matrix-base-lyrics-small.jpg)

![ alocin Song Pack (2) — バッドシャーク](images/local-mod-20261031/Matrix-alocin-play-small.jpg)

![ EdenBeginnerPack — あの夏のいつかは / 那个夏天的某日](images/local-mod-20261031/Matrix-Beginner-actual-small.jpg)

![ EdenCatchyPopPack — うっせぇわ / 吵死了](images/local-mod-20261031/Matrix-Catchy-play-small.jpg)

![ EdenClubMixPack — 魔法未来 SPECIAL MEGAMIX](images/local-mod-20261031/Matrix-Club-play-small.jpg)

![ EdenDarkPack — Sister’s ∞ mercY](images/local-mod-20261031/Matrix-Dark-play-small.jpg)

![ EdenHeavyMetalPack — ぬる / NULL](images/local-mod-20261031/Matrix-Heavy-play-small.jpg)

![ EdenHighOctanePack — Bad ∞ End ∞ Night](images/local-mod-20261031/Matrix-HighOctane-play-small.jpg)

![ EdenMasochistPack — すーぱーぬこになれんかった / 还是没能成为超级喵](images/local-mod-20261031/Matrix-Masochist-play-small.jpg)

![ EdenRockPack — ベノム / 猛毒](images/local-mod-20261031/Matrix-Rock-actual-small.jpg)

![ EdenVibesPack — 心予報 / 心预报](images/local-mod-20261031/Matrix-Vibes-play-small.jpg)

![ MORE MORE JUMP! Module Pack — Hanasato Minori](images/local-mod-20261031/MMJ-Hanasato-Minori-02-small.jpg)

![ Nightcord at 25-00 Module Pack — Yoisaki Kanade](images/local-mod-20261031/Nightcord-Kanade-01-small.jpg)

![ Proseka Another Vocal pack (base game) — PV14 ミラクルペイント WXS audio](images/local-mod-20261031/Matrix-Proseka-play-small.jpg)

![ Rage Winter 2020 Miku — Rage Winter 2020 Miku](images/local-mod-20261031/Rage-Winter-01-small.jpg)

![ Vivid BAD SQUAD Module Pack — Azusawa Kohane](images/local-mod-20261031/VBS-Kohane-01-small.jpg)

## 本轮代码与检查 / Code and checks

- 单包启动复用本次已校验路径，保留损坏／基线变化拦截；组合测试通过。Single-package validation deduplicated without bypassing checks; composition tests pass.
- USM 流边界／截断／时间基／已有输出保护：7 个自动检查通过，另有 exFAT 排他发布实测。Seven synthetic streaming/rejection tests pass, plus actual exFAT publication/output-preservation checks.
- 模拟器 Release 候选构建通过；实际原版与上述转换样本进入演奏。Simulator Release candidate builds; vanilla and listed samples entered gameplay.
- 缺失路径诊断默认关闭；公开只提交这一处运行时诊断差量，不包含私人资源或日志。Missing-path trace is opt-in; only its runtime code change is published, with no private resources/logs.

**没有制作或发布新安装包、MOD 资源或游戏资源。No new installer, MOD payload or game assets are included.**

## 关闭实验组合后 / After disabling the trial overlay

关闭代表样本覆盖，使用另一独立测试存档重新启动，原版曲库恢复为 244 首、原标题与菜单正常，无新增测试曲目残留。未据此声称完整长时间内存回归完成。With the representative overlay removed and another isolated save, the original 244-song library/title/menu returned normally, with no trial PV entries. This is not full long-session memory acceptance.

![原版曲库恢复 / Vanilla library restored](images/local-mod-20261031/VanillaAfter-menu.jpg)
