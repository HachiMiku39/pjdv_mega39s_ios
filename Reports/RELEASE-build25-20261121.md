# build25 运行稳定性与验证 / Runtime stability and verification

2026-11-21 · 0.1.5 build25

## 改动

- 两个窗口向同一位置导入 XCI 时，后来的导入会提示目录正在使用。多个任务加载同一 Mod 组合时会复用已经完成的缓存。
- 修复退出失败后恢复线程时可能丢失唤醒或过早启动的问题。多个线程读取手柄时，每次读取有独立的采样编号。
- 切换显示节拍、退出游戏和丢帧时，Metal 现在等待正确的上屏回调再释放帧资源。延迟到达的旧回调也会保留较新帧的上屏时间。
- 修复了并发检查发现的双窗口启动问题。一个窗口准备游戏时，另一个窗口不能接管它的输入和临时存档。原生线程创建失败后可以重试。

## 测试结果

Mac 真机从资源主页两次进入游戏。首轮运行中将输出从 2048 × 1152 切至 1280 × 720，提交帧数从 428 增至 761。结束进程后重新启动，720p 设置保留，并提交了 357 帧。两轮均进入 nnMain 并启动 48 kHz 双声道音频引擎。

iPad Pro 11 英寸（M5）模拟器用独立 AutoPlay 存档跑完《愛言葉》街机模式 NORMAL。结算为 PERFECT、296/296 COOL、100.71%。打歌中切换原生 60 → 30 → 60 FPS 和 1080p → 720p → 1080p 后，音符、舞台和歌词持续推进，Core Audio 持续收到非零音频块。普通存档目录测试前后均为空。 从游戏菜单确认保存并退出后返回启动页，音频渲染器、音频输出、打开的文件与目录及挂载数量均归零。同一进程再次进入游戏，版权画面和非零音频输出恢复。

合成资源测试覆盖 XCI 并发导入和中断续传，8 个并发任务读到同一份 Mod 组合。线程恢复测试通过 30 次，4 个读取线程共取得 16,384 个唯一手柄采样编号。显示链测试用受控 GPU 回调覆盖 100 次交错停止、1,000 轮帧率切换，以及编码失败和延迟完成。

本次完整打歌在模拟器上使用 AutoPlay。iPhone／iPad 真机的触屏判定、音画同步、长时间帧率及温升仍需实测；音频以缓冲区数据验证。

## 已知问题

旧插帧任务的 GPU 错误回调仍可能覆盖之后选择的新模式。导入文件夹时，后台刷新旧书签与在另一窗口切换目录可能重叠。更多待查情形和修复前的复现条件见并发检查记录。 [并发检查记录](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b25/Reports/CONCURRENCY-AUDIT-20261121.md)

## Changes

- When two windows import an XCI into the same destination, the second import reports that the directory is busy. Concurrent requests for the same Mod combination reuse the completed cache.
- Fixed missed wakeups and premature worker startup when resuming after a failed exit. Controller snapshots now have unique sample numbers across concurrent readers.
- Metal now waits for the relevant presentation callback before releasing frame resources during display pacing changes, shutdown and frame drops. Late callbacks preserve newer frame timestamps.
- Fixed the concurrent launch issue found in the source audit. While one window prepares a game, another window cannot take over its input or clear its temporary save. Launch can be retried if the native thread fails to start.

## Tests

On an Apple Silicon Mac, the game started twice from the resource screen. During the first run, output switched from 2048 × 1152 to 1280 × 720 as submitted frames increased from 428 to 761. After process termination and relaunch, the game retained 720p and submitted 357 frames. Both runs entered nnMain and started the 48 kHz stereo audio engine.

On the 11-inch iPad Pro (M5) simulator, AutoPlay completed “愛言葉” in Arcade mode on NORMAL using an isolated save. The result was PERFECT with 296/296 COOL and 100.71% completion. Notes, stage and lyrics continued through mid-song native 60 → 30 → 60 FPS and 1080p → 720p → 1080p switches, with nonzero Core Audio buffers. The ordinary save directory was empty before and after the song. Confirming save and exit in the game menu returned to the launcher. Audio renderer, audio output, open file, directory and mount counts returned to zero. Starting again in the same process restored the copyright screen and nonzero audio output.

Synthetic resource tests covered concurrent XCI import and resume. Eight concurrent requests read the same Mod cache. The runtime passed 30 thread recovery checks and four controller readers returned 16,384 unique sample numbers. Controlled GPU callbacks exercised 100 interleaved stops, 1,000 frame rate switching cycles, encoder failures and delayed completions.

The full song was played by AutoPlay on the simulator. Physical iPhone and iPad touch judgement, audio/video sync, sustained frame rate and thermals still need device testing. Audio was checked through buffer data.

## Known issues

A delayed error callback from an older frame-generation task can still override a newer mode selection. If another window selects a resource directory while a stale bookmark is refreshed, the old choice may be written back. Additional static findings and pre-fix reproduction conditions appear in the source audit. [Source audit in Chinese](https://github.com/HachiMiku39/pjdv_mega39s_ios/blob/v0.1.5b25/Reports/CONCURRENCY-AUDIT-20261121.md)
