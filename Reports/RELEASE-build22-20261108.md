# PJDV M39 0.1.5 build22 — Touch Play 判定与导入指引 / Touch judgments and import recovery

2026-11-08 · 精简预览 / Lightweight preview

- 修复原生 Touch Play 点按有动画但不判定的问题：集成 Handheld 控制器与外接 FullKey 路径并存，触屏运行模式不再随性能档禁用。
- 修复缺失 complete.json 时直接显示系统文件错误的体验；指出缺失位置，提示重新导入 XCI 或完整复制已成功提取的 GameResources，不伪造完成标记。
- 本体只需 XCI＋prod.keys；包内 DLC 随本体导入。MOD 单独管理，安装前必须通过本体完整性检查；更新简中、繁中、日语、英语和韩语说明。

原生触屏实测：AutoPlay 关闭、宿主虚拟手柄隐藏，模拟器《愛言葉》NORMAL 点按取得250分；《Catch the Wave》EXTREME 连续原生滑动取得15 COOL、5 FINE、14560 SLIDE分和23010总分。只是输入路径抽样，未完整通关；不是强制COOL，也不是手柄代打。隔离存档测试，源存档哈希未变，无排行榜上传。

输入 ASan／UBSan、Swift 顺序发布、运行模式和八个合成 XCI 的导入／恢复检查通过。日语模拟器资源页已验证错误路径、禁用启动和恢复说明。iOS 与 Mac Catalyst Release 构建通过；最终安装包完整性、签名与启动检查见随附 PACKAGES.json。 / iOS and Mac Catalyst Release builds pass; see PACKAGES.json for final installer integrity, signing and launch checks.

**待验收：** 真实 iPad／iPhone 多触点、长按／连续滑键手感、手柄热插拔和长时间音画同步。高性能配置与1080p输出保留，但原版内部画质是否与旧主机模式完全一致仍需画面对照。Mac 本轮不宣称完成触屏打歌验收；旧系统实测、任意 MOD 支持、HDR／RT／插帧的既有限制不变。

仅精简 IPA、Mac DMG 与源码：无游戏／MOD载荷、XCI、prod.keys、存档或本机签名配置。IPA未签名，需自己的有效签名；Mac arm64／ad-hoc，未公证。先备份存档再覆盖更新。原生 Touch Play 测试请在游戏选项开启 Touch Play，并隐藏宿主虚拟手柄。

[中文指南](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b22/README.md) · [English](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b22/README.en.md) · [触屏证据 / Touch evidence](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b22/Reports/TOUCH-PLAY-20261108.md) · [导入与恢复 / Import recovery](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b22/Reports/IMPORT-COMPLETION-20261108.md)

---

Fixes native Touch Play animations without judgments by retaining the integrated Handheld alongside FullKey input and separating touch-capable operation from the selected performance profile. Missing completion markers now identify the path and provide recovery; validation remains enforced. Base import requires only the user's XCI and keys, DLC comes from the XCI, and Mods require a complete base before installation. All five UI languages are updated.

With AutoPlay off and the host virtual pad hidden, simulator native taps scored250 in Ai Kotoba NORMAL; Catch the Wave EXTREME native drags produced15 COOL,5 FINE,14560 SLIDE points and23010 total. These are partial input-path checks, not full clears or human timing acceptance. No judgment/scoring patches were added. Tests used isolated saves without leaderboard uploads; source saves were unchanged. Actual C input sanitizers, Swift ordering, mode semantics and eight synthetic XCI import/recovery fixtures pass; Japanese simulator recovery UI was inspected.

Physical-device multitouch/hold/chain-slide feel, controller reconnection, long-session synchronization and internal graphics equivalence remain pending. No Mac native-touch gameplay acceptance is claimed. Existing older-OS, MOD and graphics-experiment limits remain.

Lightweight unsigned IPA, arm64/ad-hoc Mac DMG (not notarized), and source only. No game/Mod payloads, XCI, production keys, saves or development profiles. Use your own signing, back up saves and update in place. Enable native Touch Play in game options and hide the host pad for native-touch retesting.
