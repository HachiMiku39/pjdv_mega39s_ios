# 本地 PC MOD 转换试验 / Local PC MOD conversion trials

## 视频曲包研究 / Video-song research (2026-10-31)

`usm_video.py` 为 **macOS 离线工具**，从已解压的单个、未加密 IVF/VP9 USM 提取视频，经本机 FFmpeg / VideoToolbox 转为 H.264 MP4。不捆绑 FFmpeg、游戏、密钥或 MOD。需要支持 `h264_videotoolbox` 的 FFmpeg，输出必须选择新路径；保留原分辨率和时间戳，不插帧。音频仍需单独保留原曲包的 OGG。

```sh
python3 Tools/pc_mods/usm_video.py /path/to/video.usm /Volumes/ExternalSSD/Trials/video.mp4
python3 -m unittest discover -s Tests/USMVideo -v
```

按 1 MiB 分块输送，单帧最多 16 MiB、最多一百万帧；多视频通道、透明视频、分段帧和未知编码会停止。只有完整结束标记和匹配时间戳时才接受已观察到的毫秒时基头。失败不发布完整结果，不覆盖已有输出；exFAT 不支持排他重命名时使用排他创建和分块复制，完成记录最后写入。调用者必须等转换返回成功，不能加载正在复制的文件。实际首个样本进程树测量的子进程峰值常驻内存约 130 MiB；不是所有包的上限承诺。H.264 输出可能比 VP9 原文件更大。

**转码成功仍不等于曲包可玩。** 还需转换/登记谱面、资源路径、字体和 PV 数据；纯视频 MV 的 PC 角色/动作依赖需适配为原版视频 PV 的运行方式，不得将这种替代应用于 3D PV。此工具没有接入 App 的原始 PC 包自动转换流程。实际抽测范围见[本地全部 MOD 清单与载入研究](../../Reports/LOCAL-MOD-MATRIX-20261031.md)。

`usm_video.py` is a **macOS offline helper**, requiring locally installed FFmpeg with `h264_videotoolbox`. It extracts one supported unencrypted IVF/VP9 stream and produces a fresh H.264 MP4, preserving resolution and timestamps, with no frame generation. It bundles no executable, game, key or MOD. Keep song OGG audio separately. Data is piped in 1 MiB blocks, with 16 MiB/frame and one-million-frame limits; unsupported channels, alpha, split frames and codecs are rejected. The observed millisecond-timebase variant additionally requires a final content marker and matching timestamp. Existing outputs are never overwritten. On exFAT, exclusive creation and bounded copying replace unsupported exclusive rename; callers must wait for successful completion and its receipt. The first actual sample's child-process peak RSS was about 130 MiB, not a universal memory ceiling. MP4 may be larger than the source VP9.

**Conversion is not gameplay acceptance:** charts, paths, fonts and PV registries need separate adaptation. A native pure-video dummy actor setup applies only to video-only PVs, never 3D scenes. This helper is not an in-App raw-PC importer. See the linked bilingual report for exact sample results and remaining failures. USM offsets were cross-checked against [usm-toolkit, pinned MIT source](https://github.com/darkruss48/usm-toolkit/blob/21d43276afc2edb627af9bab3486093c5c69d9b8/src/usm_stream.cpp).

这些工具复用本项目已验证的转换代码，读取**已解压**的单个 PC MOD，生成独立 RomFS 覆盖目录。不会修改原游戏、XCI、MOD 来源或存档，不执行 DLL。它不是通用 PC MOD 转换器，也不会自动启用 App 的 MOD ABI。

These tools reuse this project's conversion paths to turn **one extracted package** into an isolated RomFS overlay. Sources, base assets, XCI files and saves remain unchanged. No DLL is executed. This is not a universal converter and does not activate the App MOD ABI.

| Profile | 范围 / Scope |
| --- | --- |
| `rage-winter-2020` | Rage Winter 2020 Miku：重分配模型、纹理和服装部件编号；只在测试覆盖层中替换 Miku 默认服装 0。Remaps model/texture/item IDs and replaces Miku costume 0 in the test overlay; no additive costume menu registration. |
| `x-song-pack` | X Song Pack 的 32 首曲目：注册 PV、舞台、动作、Auth3D、精灵与 AET，配对扩展字体和各语言缩略图。Registers 32 PVs, stages, motions, Auth3D, sprites/AET; pairs extended fonts and localized thumbnail atlases. |
| `electric-angel-rin-len` | PC v2.0.1 的 Electric Angel 编曲版，PV237。紧凑化 Auth3D／精灵编号、分配独立舞台登记槽；保留全部原缩略图并追加新图。PC v2.0.1, PV237: compact Auth3D/sprite IDs, allocate a stage registry slot, preserve every base thumbnail and append the new one. |

X Charts Pack 依赖 New Classics 的判定、长星键和计分逻辑，不能仅复制谱面启用。X Charts requires New Classics gameplay mechanics; merely copying its charts is insufficient.

## 使用 / Usage

需要 Python 3.10+ 和 `cryptography`（已有 FARC 格式读取器的依赖），自行提供提取后的游戏资源。输出目录必须为外置 SSD 上的新目录。转换为单进程、低优先级；逐个 FARC 处理，编码输入上限 128 MiB，单条展开上限 256 MiB，单档总展开上限 384 MiB。超过限制直接停止，不整包载入内存。

Requires Python 3.10+ and `cryptography`, plus your own extracted game assets. Choose a **new output directory on the external SSD**. Conversion uses one low-priority process and handles one FARC at a time: 128 MiB encoded archive, 256 MiB per decoded member and 384 MiB total decoded payload per archive. Oversized archives are rejected.

```sh
python3 Tools/pc_mods/convert.py \
  --profile rage-winter-2020 \
  --source "/path/to/extracted/Rage Winter 2020 Miku" \
  --base "/path/to/MEGA39-v1.0.9" \
  --dlc "/path/to/DLC" \
  --output "/Volumes/ExternalSSD/ModTrials/RageWinter"
```

输出 `manifest.json` 记录 ID 对照和文件校验值；模型使用 `overlay/`。X Song 需按 `ui-candidate:overlay` 的优先级测试，前者包含字体／精灵配对修复。必须使用隔离测试存档；默认服装覆盖不应写入个人测试外的存档。输出生成不等于所有画面通过：需实际检查模型、物理、歌词、封面、场景和歌曲结束。

The manifest records ID mappings and hashes. Use `overlay/` for the model, or `ui-candidate:overlay` priority for X Song's paired fonts/sprites. **Use an isolated test save.** Conversion success is not visual acceptance: inspect models, physics, lyrics, covers, stages and song completion in the game.

Electric Angel 同样使用 `overlay/`，已在模拟器完成 NORMAL：371 COOL、371 连击、100.78%，尚未完成所有镜头和双人表现的原版对照。X Song 已验证 Strangers／海底谭完整结算及海底谭的大小封面、中文歌词；**Calc 的 MV 倒置仍未解决**。模型下载包转换后 16 个文件与已验证配置逐字节相同；模型仍只是覆盖默认服装的试验。

Electric Angel uses `overlay/` and completed NORMAL in the simulator (371 COOL, 371 combo, 100.78%); camera/duet visual parity is not fully accepted. X Song's Strangers/Umiyuri completed, with Umiyuri covers and Chinese lyrics verified; **Calc's inverted MV remains unresolved**. The downloaded model produces 16 files identical to the previously validated profile, which remains a default-costume replacement experiment.

下载来源与转换资源只保存在本地；公开仓库仅保留工具、报告和获授权的测试截图。Downloaded/converted assets remain local; the public repository contains tools, reports and authorized test screenshots only.

## Auth3D 曲线研究 / Auth3D curve research (2026-10-30)

`a3dc_to_a3da.py` 是离线研究辅助工具，提供 `convert(bytes)`，将经典 A3DC 的二进制关键帧展开为文本 A3DA。保留未知文本属性、曲线插值／外推、变换与半精度旋转数据；遇到不支持的结构停止，不生成空动画。格式研究参考 [ReDIVA a3da.cpp，固定提交 207c270](https://github.com/korenkonder/ReDIVA/blob/207c270472ba3f0edcda29bae777e5bd4a8952d9/src/KKdLib/a3da.cpp)。合成数据验证：`python3 Tests/Auth3D/test_conversion.py`。

**不是已验收的 F2nd 修复，也没有接入 App 的通用转换器。** 转换后《SPiCa》真机载入仍失败；公共 FARC 的继承条目也必须合并，不能只覆盖整个包。见[复测结果](../../Reports/MULTI-MOD-VALIDATION-20261030.md)。

`a3dc_to_a3da.py` is an offline research helper exposing `convert(bytes)` for classic Auth3D binary curves. It preserves unknown text properties, interpolation/extrapolation, transforms and half-float rotation data, and rejects unsupported structures instead of substituting empty animation. Format reference and synthetic test command are above. **It is neither an accepted F2nd fix nor an in-App general converter**: SPiCa still fails the physical loading test, including after inherited FARC entries were restored.
