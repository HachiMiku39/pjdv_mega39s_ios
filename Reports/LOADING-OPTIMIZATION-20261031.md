# 载入分析与改进 / Loading analysis and changes

2026-10-31，本地候选。公开安装包仍为 build19；本轮没有制作整合包。

## 已修改、已测量

`ModComposition.prepare` 的单包路径曾在同一次启动中重复调用完整的 `overlayPaths` 校验。现在复用本次调用已经通过校验的路径，每次启动仍重新检查基线和载荷，不跳过哈希，不引入跨会话“永远有效”标记。多包合并行为不变。

M3 Max / 64 GiB，外置 SSD，LeoNeed 已转换包：80 个载荷文件、4 个基线检查，每遍哈希 37,750,169 字节。各执行三次暖缓存测试：

| 单包准备阶段 | 修改前 | 修改后 |
| --- | --- | --- |
| 三次耗时，秒 | 0.14320 / 0.11845 / 0.11777 | 0.06004 / 0.06105 / 0.06052 |
| 中位数 | 118.45 ms | 60.52 ms |

**此阶段约减少 58 ms（49%）；不是整首歌加载加快 49%，也不是 M1 实测。** 同大小修改载荷和改变基线标记的回归样本仍被拒绝；组合、缓存和回滚检查通过，模拟器候选构建通过并实际进入原版及转换后的歌曲。

## 这次“载入慢”还包含兼容等待

PC 曲包不能只复制数据库或将 `.usm` 改成 `.mp4`。检查到的代表样本在 CRI USM 内包裹 IVF / VP9；当前原版 Switch 视频路径使用 MP4。先完成实际视频转码，并给视频独占 PV 保留原版视频 PV 所需的隐藏角色、舞台和动作初始化后，Eden Beginner 的代表歌曲才实际推进视频、音符和歌词。错误的 PC 测试动作依赖曾导致等待或烘焙动作解码崩溃。该初始化仅适用视频独占 PV，不可替代实时 3D 场景。

卡住时的一次线程采样显示游戏线程在等待，工作线程多为空闲，不能据此把所有等待解释为 SSD 顺序读取不足。可选的 `PJDV_FS_MISS_DIAG` 诊断现可按路径片段记录带时间戳的缺失查询，最多 2,048 条；默认关闭，保留原路径解析和错误语义。原版会探测多个地区和 DLC 路径，单条不存在记录本身不代表错误，不能全局屏蔽这些查询。

10 首完整代表视频的离线转码、帧数和输出媒体元数据已检查，实际游玩验收范围另见[逐包清单](LOCAL-MOD-MATRIX-20261031.md)。使用 1 MiB 流式输送，首个样本转码子进程峰值常驻内存约 130 MiB。原 VP9 约 97.6 MB，H.264 输出约 219.3 MB，**转码改善兼容性，不保证节省空间**。工具还未接入 App 的原始 PC 包自动导入流程。

## 接下来值得做的优化

1. **导入时完成转换并缓存结果**，启动不重复转码／全量重建；内容或转换器版本变化时才失效。先验证实际引用的媒体、谱面和动作，不只验证数据库存在，避免把缺资源表现为无限载入。
2. **分别计时**文件定位、读取、解压、贴图上传和管线编译。以同一首歌冷／暖加载对照，再确定并发读或预热的收益；避免同时展开多个大档增加 8 GB 设备峰值内存。
3. **按需预热资源和管线**，限制缓存容量，连续切歌检查内存回落。保留加载失败时上一套能玩的组合。
4. **Metal Fast Resource Loading 作为独立后端评估**：它支持兼容资源的异步加载／解压和减少拷贝，不能直接解释任意 FARC / gzip / USM；旧系统继续使用现有路径。API 的运行时可用性仍要检查，GPU family 不能代替系统 API 检查。[Apple 文件系统性能指南](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system) · [Metal 示例](https://developer.apple.com/documentation/metal/loading-textures-and-models-using-metal-fast-resource-loading) · [WWDC22](https://developer.apple.com/videos/play/wwdc2022/10104/)

## English

The single-package `ModComposition.prepare` path validated the same baseline/payload twice in one invocation. It now reuses the validated paths for that invocation, while each launch still performs its checks. No hashes were removed, no persistent trust shortcut was added, and multi-package composition is unchanged. Same-size payload corruption and changed-baseline regression cases still fail. Composition/cache/rollback tests and the Simulator build pass; actual vanilla and adapted gameplay ran in the candidate.

On an M3 Max/64 GiB host with external SSD, the converted LeoNeed fixture contains 80 payload files, four baseline checks and 37,750,169 hashed bytes per pass. Three warm trials are listed above. Median preparation time dropped from **118.45 to 60.52 ms**, about 58 ms/49% for this phase only. This is **not a 49% song-loading gain or an M1 benchmark**.

Some apparent loading stalls were format/dependency mismatches. The sampled PC videos contain IVF/VP9 inside USM, whereas the guest's native movie path expects MP4. Actual conversion and the original game's pure-video hidden-actor initialization allowed the Beginner representative to advance video, notes and lyrics. Wrong PC pose/baked-motion dependencies had caused waits or a decode crash. This setup must never be applied to real-time 3D PVs. One stalled-session thread sample showed mostly waiting/idle workers, not sustained disk saturation. The optional, timestamped missing-path trace is capped at 2,048 entries and disabled normally; missing regional/DLC probes are often expected fallbacks, not automatically failures.

Ten complete representative videos were converted and their codec/frame counts/timestamps inspected; see the separate matrix for actual gameplay scope. Conversion streams 1 MiB blocks; the first sample's child-process peak RSS was about 130 MiB. Its 97.6 MB VP9 became a 219.3 MB H.264 MP4, so compatibility conversion can increase disk use. The helper is still offline and is not an automatic raw-PC importer in the App.

Next: import-time conversion/cache keyed by content and converter version; validate referenced resources before launch; measure lookup/read/decompression/upload/compilation separately; bound concurrency and cache memory; test cold/warm loads and memory recovery across songs. Apple's linked file-system guide and Metal Fast Resource Loading sample support targeted async I/O/decompression work, but do not make arbitrary FARC/USM directly compatible. Preserve the existing older-system path and runtime API checks.
