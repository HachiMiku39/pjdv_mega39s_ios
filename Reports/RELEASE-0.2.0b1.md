# PJDV M39 0.2.0 build 1 · Mod 导入与游戏画面测试

2026-11-25 · [English](#english) · [下载安装包](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.2.0b1)

## 中文

从 GameBanana 作者页面下载了 9 份原档，共 2,570,830,146 字节。6 个模型包中有 5 个通过原包导入。3 个歌曲包都需要开发适配，其中 2 首进行了游戏内验证。下表的下载量和点赞数取自当日的作品页面，点击包名可找到作者及原档。

| 作者原包 | 下载／赞 | 原包导入与游戏测试 |
| --- | ---: | --- |
| [Racing Miku 2025](https://gamebanana.com/mods/612338) | 2,521／40 | 从 M5 iPad Pro 模拟器的 Mod 页面点击原 ZIP 后导入成功。衣柜换装后在《愛言葉》NORMAL 打歌，服装和发型均可见。[舞台截图](images/release-0.2.0b1/racing-2025.jpg) |
| [Racing Miku 2024](https://gamebanana.com/mods/546183) | 1,596／19 | 同一导入流程通过。在《愛言葉》舞台可见白色宽檐帽和披风。[舞台截图](images/release-0.2.0b1/racing-2024.jpg) |
| [MORE MORE JUMP! Module Pack](https://gamebanana.com/mods/395162) | 7,680／33 | 作者 RAR 直接导入，94 个运行文件通过校验。载荷指纹与此前装备花里实乃理的样本一致，本轮复核了此前的画面记录。 |
| [Vivid BAD SQUAD Module Pack](https://gamebanana.com/mods/400356) | 7,207／36 | 作者 ZIP 直接导入，94 个运行文件通过校验。载荷指纹与此前装备小豆泽心羽的样本一致，本轮复核了此前的画面记录。 |
| [Sekai Mini Pack 7](https://gamebanana.com/mods/535939) | 2,606／28 | 原 ZIP 生成的 90 个运行文件通过校验。在 iPhone 18 Pro 模拟器给小豆泽心羽换上 Rekka Kohane，进入《愛言葉》并连续判定。[舞台截图](images/release-0.2.0b1/rekka-kohane.jpg) |
| [Sekai Halloween Module Pack 2023](https://gamebanana.com/mods/475865) | 2,911／28 | 导入被拒。对象登记存在 32 位与 16 位编号差异。进一步核对发现，登记的 `nenitm504.farc` 在作者归档、测试本体与所装 27 个 DLC 中均缺失。 |
| [Project Sekai Covers for Vanilla Songs](https://gamebanana.com/mods/397708) | 4,396／18 | 7z 解压后可以识别。给既有歌曲添加可选人声的整包合并仍待支持。开发抽查将作者的 Wonderlands×Showtime 翻唱设为默认，在《Miracle Paint》NORMAL 中观察到音轨读取、非零音频输出和连续判定。[打歌画面](images/release-0.2.0b1/miracle-paint.jpg) |
| [Project Sekai Movie Song Pack（PC）](https://gamebanana.com/mods/597713) | 3,091／23 | 原 ZIP 可识别，9 首曲目使用编号 2500–2508，超过当前视频歌曲转换范围 1–999。整包未进入可加载列表。 |
| [Project Sekai Movie Song Pack（欧美 Switch）](https://gamebanana.com/mods/625965) | 430／1 | 原包依赖 DMLSwitchPort，目标游戏编号与本项目使用的日版不同。开发侧从该包单独适配《はじまりの未来 (Ergo ver.)》。在 M4 iPad Air 模拟器从选曲菜单进入 HARD，影片和音轨完整播放约 4 分 20 秒，AutoPlay 达到 PERFECT，普通存档校验值一致。[结算画面](images/release-0.2.0b1/hajimari-result.jpg) |

### 两套 Racing Miku 一起使用

候选版按 DML 分类匹配服装和配件的多语言名称。对于 2025 包中两条完全相同的发型记录，导入器会合并。Sekai Mini Pack 7 的模型外层归档和内层成员使用不同文件名前缀，现在按作者登记的归档查找，再验证其成员。

Racing 2024 和 2025 单独加载时，服装编号均为 123，发型编号均为 29。一起加载后，2024 使用 123／29，2025 使用 140／63。交换勾选顺序后，69 个组合文件的 SHA-256、存档配置标识及发型绑定均一致。两套服装分别在独立游戏会话中上场。

### 《Calc.》画面与可选字体

修正透明合成时的上下方向后，已适配 X Song Pack 1.21 的《Calc.》在 M3 Max Mac 和 M5 iPad Pro 模拟器中的两个倒置镜头恢复正常。模拟器完成 NORMAL，390 COOL、390 连击。PC 原始 X Song Pack 2.0 声明依赖 Windows 插件，整包直导仍受此限制。[同镜头画面对照，左为修复前](images/release-0.2.0b1/calc-orientation.jpg)

在启动页选择「游戏设置 → 游戏字体 → Google Sans」，下次进入游戏时应用到歌词、服装名和歌名，中日韩文字使用 Noto Sans CJK 对应的地区字形。M5 iPad Pro 模拟器简中对照中，《Calc.》歌词里的「你、离、远」从方框变为可读文字。选曲标题和服装名也切换了字形，底栏按键提示的 5,110 个前景像素逐点一致。切回原版字体并重新启动游戏后，重新读到了原 Mod 字库。[歌词对照，上为原版、下为开启后](images/release-0.2.0b1/calc-lyrics.png)

发布前，又用版本号为 0.2.0（1）的 Release 构建，在 M5 iPad Pro 模拟器上从启动页分别点选 Racing 2024、2025 两个作者原始 ZIP。两个包都完成转换，并分别出现在已就绪列表中。Apple Silicon Mac 版从只读挂载的发布 DMG 启动，通过启动页检查。

Mod 与字体截图来自本次更新的开发候选。上述九包的画面和打歌抽查使用模拟器与隔离配置，真机打歌延迟、长时间帧率和温升仍待独立验证。游戏、密钥及 Mod 原档由玩家在本地导入。[安装与使用指南](../README.md)

## English

Testing used nine original archives from the authors’ GameBanana pages, totaling 2,570,830,146 bytes. Five of the six model packages passed direct import. All three song archives need adaptation, and two individual songs were tested in-game. The download and like counts above were recorded on November 25, 2026.

| Original archive | Direct import and gameplay result |
| --- | --- |
| [Racing Miku 2025](https://gamebanana.com/mods/612338) and [Racing Miku 2024](https://gamebanana.com/mods/546183) | Both original ZIPs were imported from the Mod Manager on the M5 iPad Pro simulator. Each costume and hairstyle appeared on stage in “Ai Kotoba” NORMAL in its own session. [2025](images/release-0.2.0b1/racing-2025.jpg) · [2024](images/release-0.2.0b1/racing-2024.jpg) |
| [MORE MORE JUMP!](https://gamebanana.com/mods/395162) and [Vivid BAD SQUAD](https://gamebanana.com/mods/400356) | The original RAR and ZIP each produced 94 verified runtime files. Each payload matched its previously tested version. The corresponding earlier simulator observations were Hanasato Minori and Azusawa Kohane, respectively. |
| [Sekai Mini Pack 7](https://gamebanana.com/mods/535939) | All 90 runtime files passed verification. Rekka Kohane was equipped and appeared during “Ai Kotoba” on the iPhone 18 Pro simulator. [On stage](images/release-0.2.0b1/rekka-kohane.jpg) |
| [Sekai Halloween Module Pack 2023](https://gamebanana.com/mods/475865) | Import was rejected. Its registry uses different 32-bit and 16-bit identifiers. The referenced `nenitm504.farc` was also missing from the archive, the tested base game and all 27 installed DLCs. |
| [Project Sekai Covers for Vanilla Songs](https://gamebanana.com/mods/397708) | The extracted 7z folder was recognized. Importing additional vocals for existing songs as a complete package still needs support. A developer sample set the author's Wonderlands×Showtime recording as the default for “Miracle Paint” NORMAL. Audio reads matched the source, the audio output was nonzero and notes received judgments. [Gameplay](images/release-0.2.0b1/miracle-paint.jpg) |
| [Project Sekai Movie Song Pack for PC](https://gamebanana.com/mods/597713) | The ZIP was recognized. Its nine song IDs, 2500–2508, exceed the supported video-song conversion range of 1–999. The full archive could not be activated. |
| [Project Sekai Movie Song Pack for US/EU Switch](https://gamebanana.com/mods/625965) | The original requires DMLSwitchPort and targets a different game ID from the Japanese game. A developer adapted one song, “Hajimari no Mirai (Ergo ver.)”. On the M4 iPad Air simulator it was selected from the song list and played the full 4:20 HARD chart with video and audio. AutoPlay reached PERFECT, and the ordinary saves retained their checksums. [Result screen](images/release-0.2.0b1/hajimari-result.jpg) |

**Combining the Racing costumes.** Import now reads DML costume and accessory translations by category and handles the identical duplicate hair record in the 2025 archive. Sekai Mini Pack 7 uses different prefixes for its outer archive and its members. The converter resolves the registered archive and checks its contents. Each Racing package alone uses costume 123 and hair 29. With both enabled, the 2024 set received 123/29 and the 2025 set received 140/63. Reversing selection order gave the same hair bindings, save-profile ID and SHA-256 hashes for all 69 combined files.

**Rendering and text.** Correcting the vertical orientation of the transparency pass restored two formerly inverted shots in “Calc.” with the adapted X Song Pack 1.21 on an M3 Max Mac and an M5 iPad Pro simulator. The simulator completed NORMAL with 390 COOL and a 390 combo. The raw PC X Song Pack 2.0 declares a required Windows plug-in, which still prevents direct import. [Matching shots, before on the left](images/release-0.2.0b1/calc-orientation.jpg)

Choose **Game Settings → Game font → Google Sans** and start a game session. The setting applies to lyrics, costume names and song titles. Chinese, Japanese and Korean use regional Noto Sans CJK glyphs. The Simplified Chinese “Calc.” sample restored three missing characters, 你, 离 and 远. Song and costume labels changed as expected. All 5,110 foreground pixels in the sampled button legend matched the original. Switching back and relaunching restored the mod’s own font atlas. [Lyrics, original above and enabled below](images/release-0.2.0b1/calc-lyrics.png)

A final check used the Release build stamped 0.2.0 (1) on the M5 iPad Pro simulator. Selecting the original Racing 2024 and 2025 ZIPs from the launcher converted each archive and added it to the ready list. The Apple Silicon Mac app launched successfully from the read-only release DMG.

The mod and font screenshots were captured on development candidates for this update. The nine-archive gameplay checks used simulators and isolated profiles. Sustained performance, input timing and thermals on physical devices still need separate testing. Supply your game, keys and individual mods locally. [Installation and usage](../README.en.md)
