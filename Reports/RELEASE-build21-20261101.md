# PJDV M39 0.1.5 build21 — 原生 MOD 导入与视频兼容修复 / Native MOD import and video fixes

2026-11-01 · 精简预览 / Lightweight preview

- 原生支持受限的资源模型和常规 FT 视频歌曲 ZIP／文件夹转换，流式处理 USM／VP9 并提供受限软件回退；来源不变、可取消、失败回滚。
- 修复中文字幕字库配对及多曲包列表合并；已有已适配包多选、组合存档、坏包隔离和完整重验保留。
- 修复《Cosmos》紧密排列 1916×1080 视频与 1920×1088 编码尺寸不一致引起的中止，保留容量和边界检查；修复合法 IVF 分数时间基准误拒绝。
- 文件夹导入和转换副本在可用时采用独立 APFS 克隆，跨卷／exFAT 继续按块复制，不改变源文件。

Mac 已验证原始 Kimagure Mercy Miku Module 1.1 和 Tonny’s Song Pack 1.2 转换、组合与模型／歌曲抽样；开发适配的 Eden Heavy Metal 14 首、Rock 19 首完整登记后，随机四首 EXTREME 整曲结算。AutoPlay 使用临时档，未上传排行榜，普通隔离档哈希保持不变。

**边界：** 不承诺任意 PC Mod 兼容。Eden 原始编号大于999仍需开发准备，不能直接当作完整原包导入；复杂3D舞台、Windows DLL、New Classics、Calc部分倒置和SPiCa崩溃未完成。新版本的原始导入→组合→真人打歌→正常存档→重启完整真机闭环仍待验证。旧设备／iOS17／Big Sur和真人音画同步继续需要回测。HDR、RT和插帧仍是默认关闭的实验，不保证稳定60/120FPS或节能。

只含宿主程序和必要运行组件，不含XCI、游戏／MOD载荷、prod.keys、个人存档、开发签名配置或测试移植包。IPA未签名，请用自己的有效签名安装；Mac arm64，ad-hoc签名，未公证。最低目标iOS/iPadOS17、Apple GPU family7；Mac最低目标M1/macOS11，旧系统实测未完整覆盖。备份存档并覆盖安装，资源保留。安装及键盘映射见随附中英文README。

---

- Native conversion for supported resource-only models and conventional FT movie-song ZIPs/folders; streamed USM/VP9 conversion with bounded software fallback, unchanged sources, cancellation and rollback.
- Paired CJK lyric-atlas and independent song-list composition fixes; prepared-package multi-selection, configuration saves, damaged-package isolation and full re-verification remain.
- Fixes Cosmos’ packed1916×1080 versus coded1920×1088 AVC boundary, retaining capacity/bounds checks; accepts valid fractional IVF timebases within CMTime/arithmetic limits.
- Independent APFS clones for supported folder copies; cross-volume/exFAT paths still stream without modifying originals.

Mac samples cover raw Kimagure Mercy Miku Module1.1 / Tonny’s Song Pack1.2 conversion/composition and model/song gameplay. Complete developer-adapted Eden Heavy Metal14 + Rock19 registered all33 songs; four random EXTREME songs completed with disposable AutoPlay saves, no leaderboard upload and unchanged ordinary isolated saves.

**Limits:** Not universal PC-MOD compatibility. Eden IDs above999 still require developer preparation; raw complete-pack import is unfinished. Complex3D stages, Windows DLLs, New Classics, Calc inversion and SPiCa crash remain limited. The entire new native-import/composition/manual-play/normal-save/restart physical-device flow is pending, as are older-device/OS and human-synchronization acceptance. HDR/RT/frame generation remain experimental and off by default, without sustained60/120FPS or power-saving promises.

No game/MOD payloads, XCI, production keys, personal saves, development profiles or converted test packs. Unsigned IPA: use your own valid signing identity. Arm64 Mac: ad-hoc signed, not notarized. Targets remain iOS/iPadOS17+/Apple GPU family7+, M1/macOS11; actual old-OS acceptance is incomplete. Back up saves and update in place. Installation and keyboard maps are in both READMEs.

[中文指南](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b21/README.md) · [English guide](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b21/README.en.md) · [原始导入证据 / Raw import evidence](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b21/Reports/NATIVE-RESOURCE-MODS-20261101.md) · [Eden抽样 / Sampling](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b21/Reports/EDEN-FULL-PACKS-20261101.md)

## 包验证 / Package validation

iOS／Mac Release 构建、模型／歌曲／安装器回归及实际 AVC AddressSanitizer 通过。最终 Mac 包首页与 MOD 管理入口已检查；IPA 全量 CRC／SHA-256 回读、包内私密载荷排除、Mac 深度签名、DMG UDIF 校验通过。系统仍拒绝只读挂载 DMG，未完成挂载后逐文件回读。未在本轮重新安装 iPad／iPhone 真机。

Release builds, model/song/installer regressions and real AVC ASAN passed. Final staged Mac launcher/MOD-manager smoke checks, IPA full CRC/SHA256 readback, private-payload exclusion, deep Mac signature and DMG UDIF integrity passed. Read-only DMG attachment was denied by the OS, so mounted file readback was not performed. No physical iPad/iPhone deployment was repeated during this export.
