# build20 发布范围 / Release scope

2026-11-01 · 0.1.5 / 20 · `v0.1.5b20` 预览

PJDV M39 0.1.5 build20 — 精简预览 / Lightweight preview

本次更新 iOS/iPadOS IPA、macOS DMG、源码和中英文指南。公开附件不含游戏／MOD 载荷、XCI、prod.keys、个人存档或开发签名配置。

- 修复《Catch the Wave》视频背景与后期合成的有效区域原点不一致。iPhone Air 的原版资源完成两轮 PV、重试和返回选曲；普通 1080p、MetalFX、HDR 路径分别抽样。修正位于共用渲染层，不改视频文件、全局相机或材质。
- 已适配包可在 App 内多选并加载，自动组合；失败／取消保留上一套配置，取消全部选择后加载恢复原版。组合使用独立配置存档，AutoPlay 仍用临时档。
- 坏清单逐包隔离；新增重新完整校验，可检查同大小的大文件损坏；重复导入不覆盖已装内容。
- **仅精确版本 Leo/need Module Pack 1.0.2** 原始 ZIP／文件夹支持 App 内识别、转换和缓存，玩家无需 Python 或 Xcode。其他原始模型版本、原始歌曲包和 Windows DLL 仍需适配。
- 保留 MOD 应用内浏览／下载、分块解压／CRC、取消与空间检查，以及既有键盘、触控、虚拟按键编辑、手柄和画质功能。

**验收边界：** 本机 GPU 检查与 iOS／Mac Release 构建通过；MOD 安装、完整校验、多选组合、冲突／取消恢复和原生模型转换的合成回归通过。模型／多包游戏证据主要来自之前的 M4 与模拟器分项测试；新版“原始导入→组合→真人打歌→正常成绩保存→重启”完整真机闭环仍待验收。此次 iPhone 测试为 PV／显示链，不代表音游时序、全曲画质或稳定 60/120 FPS。Calc 部分镜头倒置、SPiCa 崩溃、New Classics、通用清单 v2 与升级／存档迁移仍未完成。旧设备／iOS17／Big Sur 仍需社区回测。

IPA 未签名，需用自己的有效签名安装；Mac 为 arm64、ad-hoc 签名、未公证。升级前备份存档，优先覆盖安装以保留资源。最低目标 iOS/iPadOS17、Apple GPU family7；Mac 为 M1/macOS11 构建目标，实际旧系统兼容性未完整验收。插帧／HDR／RT 为实验，默认关闭，不承诺节能或稳定帧率。**不会自动下载或附带 MOD／游戏资源。**

[中文安装与键盘映射](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b20/README.md) · [背景修复报告](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b20/Reports/CATCH-WAVE-VIDEO-ORIGIN-20261101.md) · [原生模型导入证据](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b20/Reports/NATIVE-PC-MODEL-IMPORT-20261031.md)

---

This preview updates the lightweight iOS/iPadOS IPA, macOS DMG, source and bilingual guides. No game/MOD payloads, XCI, production keys, personal saves or development profiles are included.

- Corrected the shared movie-background active-region origin. On iPhone Air, original Catch the Wave resources completed two PV runs, retry and return to selection; ordinary 1080p, Spatial and HDR paths were sampled. No video assets, global cameras or materials are changed.
- Prepared packages can be selected together and composed inside the App. Failure/cancellation keeps the previous configuration; load with none selected to restore the original game. Configurations have separate saves; AutoPlay remains temporary.
- Damaged manifests are isolated. Full re-verification checks large-file same-size corruption; duplicate imports preserve installed content.
- Native raw-ZIP/folder recognition, conversion and caching for **the exact Leo/need Module Pack 1.0.2 only**, without Python/Xcode. Other raw model versions, raw song packages and Windows DLLs still need adaptation.
- Existing in-app MOD downloads, bounded extraction/CRC, cancellation/space checks, keyboard/touch/controllers/layout editing and graphics options are retained.

**Limits:** Actual-GPU checks, iOS/Mac Release builds and synthetic MOD import/verification/composition/conflict/cancellation/conversion regressions passed. Earlier M4/Simulator samples support individual model/multi-package cases; the entire new native-import/composition/manual-play/normal-score/restart device flow is not accepted yet. This iPhone PV validation does not qualify manual rhythm timing, all songs/modules or sustained60/120FPS. Calc inversion, SPiCa crash, New Classics mechanics, general manifestv2 and upgrade/save migration remain unfinished. Older hardware/iOS17/Big Sur need community testing.

Unsigned IPA: use your own valid signing identity. The arm64 Mac app is ad-hoc signed, not notarized. Back up saves and update in place. Targets remain iOS/iPadOS17+, Apple GPU family7+, and M1/macOS11; older OS acceptance is incomplete. FG/HDR/RT remain experimental and off by default, without power-saving or stable-frame-rate promises. **No MOD/game assets are automatically downloaded or bundled.**

[English guide](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b20/README.en.md) · [Multi-package evidence](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b20/Reports/MOD-NATIVE-MULTISELECT-20261031.md)


## 包验证 / Package validation

iOS 与 Mac Release 构建通过；最终 Mac 包的启动首页和 MOD 管理入口已检查，并核对实际执行路径。IPA 全量 CRC／SHA-256 回读、Mac 深度签名、DMG UDIF CRC 与密钥／资源／存档排除检查通过。系统拒绝只读挂载 DMG，因此未完成挂载后的逐文件回读，不将其标为通过。文件摘要见发布附件 `SHA256SUMS.txt`／`PACKAGES.json`。

Release builds, final staged Mac launcher/MOD-manager smoke checks, IPA CRC/SHA-256 readback, deep Mac signature verification, DMG UDIF CRC and private-payload exclusion checks passed. macOS denied read-only DMG attachment, so mounted file readback was not performed. This is a compatibility preview, with validation limits described above.
