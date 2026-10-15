# PJDV M39 · iPadOS / macOS 测试版

《初音未来 Project DIVA MEGA39’s》Switch JP v1.0.9 的 iPadOS / Apple Silicon Mac 兼容移植研究。采用原游戏 ARM64 程序适配、Horizon 服务兼容与 **NVN → Metal**；当前暂不支持 iPhone。

**版本：0.1.2（build 4）｜更新：2026-10-15｜状态：测试版。** 目前可以运行原游戏的标题、菜单、MV 和实时 3D 节奏游戏，画质一致性、完整输入体验和全曲稳定 60 FPS 仍在验证。

[下载测试版](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases) · [详细研究记录](RESEARCH-20261015.md)

## 今天的改进

- **直接导入 XCI**：新增系统文件选择器、NCA3 解密、BKTR 更新合并、IVFC 数据校验、27 DLC 提取、进度与取消。再次选择同一 XCI 可校验并复用已完成的文件，不覆盖不同版本或校验失败的旧文件。
- **资源独立管理**：可连接完整的已提取资源文件夹；iPad 开启访达文件共享，支持把资源拷到本机。Mac 记住用户选择的目录，外置盘资源无需复制到系统盘。
- **默认全部开放**：现有歌曲已存在谱面的全部难度、服装与饰品初始可用。新旧存档均适用，保留原成绩、通关记录、设置和点数；首次修改前备份原始存档。不生成原包不存在的谱面。
- **DualSense 游戏震动**：已由用户在 M4 iPad 的《Catch the Wave》EXTREME 连续长滑键中确认有震动，且事件与宿主输出日志一致；启动测试脉冲关闭。普通短滑键不等同于原作的长链震动事件。
- **补齐固定键盘映射**：Delete / Backspace 对应 Switch ＋，Enter / Return 对应 Switch －；保留 IKJL、方向键、Q/E 和 Space 组合键。
- **Mac 数据目录**：改用 App 专用的 Application Support 目录存放存档、缓存和日志，修复 GUI 启动时卡在文稿日志打开的问题。本机旧存档已复制迁移，原目录保留。

## 支持范围与已有功能

| 项目 | 当前状态 |
| --- | --- |
| 系统 | iPadOS 26+；macOS 26+ 的 Apple Silicon Mac Catalyst 版 |
| GPU | Apple GPU family 9 或更新；最低按 M3 / A17 Pro 级别，启动时检测实际能力 |
| 已测试硬件 | M4 iPad Pro 11 英寸、M3 Max Mac；模拟器结果与真机性能分开记录 |
| 显示 | 横屏、16:9 等比例；支持 1080p、1440p、屏幕匹配输出 |
| MetalFX | Spatial 超分已接入；当前处理整幅游戏画面，没有插帧，不能等同于原生高分辨率 3D |
| 图形 | 原版着色器翻译到 Metal；已修复眼球默认 W、后处理翻转、阴影过滤方向和部分 mip 拷贝缺口 |
| 光追 | 单灯不透明舞台阴影试验，默认关闭；角色自阴影、反射和完整原版光照尚未还原 |
| 音频 | AudioRenderer → CoreAudio，48 kHz 立体声；用户确认片头和菜单声音正常，歌曲同步仍需更多回归 |
| 输入 | Switch 布局虚拟手柄、键盘、DualSense / Xbox 接入；连接实体手柄后自动隐藏虚拟手柄，可手动开关 |
| 触屏 | 虚拟按键可触控；原作触点已接入，Touch Play、多指打歌仍需完整验收 |
| 性能 | FPS / CPU / RAM 浮窗、帧时间日志、只读资源路径索引；全曲稳定真实 60 FPS 尚未验收 |
| 退出 | 原 eShop 菜单入口重映射为“退出游戏”，确认后走保存与停止会话流程 |

当前游戏程序和资源格式固定到 **JP v1.0.9 / 589824、Title ID 0100F3100DA46000、1 基础版＋1 更新＋27 DLC**。不能把其他地区或其他更新版的 XCI 当成已经支持的版本。

## 安装包怎么选

| 包 | 内容与用途 |
| --- | --- |
| GitHub iPad IPA | 轻量、未签名；需要自行有效签名，并导入自己的游戏与密钥 |
| GitHub Mac DMG | 轻量、arm64、ad hoc 签名，未公证；首次运行需导入自己的资源 |
| 本地 iPad FullTest ZIP | IPA＋整份已提取 GameResources＋说明，约 42 GB；供本地换设备测试 |
| 本地 Mac Full DMG | App 内包含整份已提取资源，可直接启动，需保留约 45 GB 空间 |

GitHub 轻量包没有 XCI、提取后的大型游戏资源、prod.keys 或本机开发签名配置。按用户要求内置密钥的测试版及完整资源包仅留在本地外置 SSD。

## iPad 安装与首次启动

1. 给 IPA 使用你自己的有效开发签名，安装到受该签名允许的 iPad。公开 IPA 未签名，不能靠把文件拷到 iPad 就完成安装。
2. 按系统要求启用 [开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。如系统要求信任开发签名，在“设置 → 通用 → VPN 与设备管理”处理对应开发者。
3. 打开 PJDV M39，使用下面的 XCI 导入或已提取资源方式。资源未就绪时“启动游戏”不可用。
4. 点击“启动游戏”，用虚拟 A、键盘 D 或实体手柄的确认键进入。A 可以跳过开头视频。

本地 development IPA 的签名只覆盖当前登记设备，并有有效期；换 iPad 需要重签。更新测试版尽量覆盖安装，先备份存档再做卸载操作。

### 方式一：直接导入 XCI

1. 在首页打开“导入 XCI／资源管理”。公开版先点“选择／更换 prod.keys”，选择本地密钥文件；本地内置密钥版可跳过这一步。
2. 点“导入 XCI”，选择匹配版本的 `.xci`。ZIP / 7z 需先解压；云端文件需先下载完整。
3. 保持 App 在前台，等待基础资源、v1.0.9 更新合并及 27 DLC 导入完成，再点“完成 → 启动游戏”。

XCI 若在外置盘，可直接读取源文件，输出资源写入 iPad 本机。此包资源约 **41.94 GB**，建议给输出预留 **45 GB** 可用空间；若 XCI 也先拷到本机，则还要计入约 **42.72 GB** 的源文件空间。取消后再选同一 XCI 可以续导；断开外置盘、空间不足或校验失败会停止，原 XCI 与存档保留。

### 方式二：使用完整测试包内已提取的资源

已有本作完整资源的设备只需更新 IPA，无需重复拷入资源。

1. 在 Mac / 外置 SSD 上解压本地 FullTest ZIP，不必重新从 XCI 提取。
2. 安装并至少打开一次 App。用线连接 iPad，在访达打开“iPad → 文件 → PJDV M39”，拷入完整的 `GameResources` 文件夹。
3. 等传输完全结束；打开 App 的资源管理，选择“使用已拷入本机的资源”。也可在“文件”App 中连接已准备好的整个资源目录。

必须保留准备完成的清单文件和文件夹结构，不要只拷贝 `rom` 子目录：

```text
PJDV M39 的 Documents/
└── GameResources/
    ├── romfs/                 # 也兼容 MEGA39-v1.0.9 这个目录名
    │   ├── preparation.json
    │   ├── complete.json
    │   ├── files.jsonl
    │   ├── rom/
    │   ├── rom_switch/
    │   ├── shader/
    │   └── ……
    └── DLC/
        ├── manifest.json
        ├── 1/
        ├── 2/
        └── ……                # 共 27 个，编号不连续，不要重新编号
```

也可以直接连接外置盘上已提取的目录；运行期间需一直连接。若希望使用本机存储的读取性能，先完整拷入本机。

## Mac 安装与导入

- 打开 DMG，把 PJDV M39 拖到可保留它的位置。完整资源版 App 约 42 GB；轻量版 App 需另行导入资源。
- 当前使用本地 ad hoc 签名，尚未 Apple 公证。首次打开按 [Apple 的未公证 App 说明](https://support.apple.com/102445) 检查并批准此 App。
- 轻量版：资源管理里先选择自己的 prod.keys，再选择 XCI，随后选择资源保存位置。可以选外置 SSD；导入完成后会记住位置。
- 已有完整资源：选择“连接已提取资源文件夹”，选同时含 `romfs` / `MEGA39-v1.0.9` 和 `DLC` 的父目录。
- 完整资源版在新设备上可以直接读取 App 内资源。使用外置盘目录时，运行期间保持该盘连接；路径失效后重新选择。

## 键盘映射

Mac 键盘、iPad Magic Keyboard / 外接键盘使用同一套固定映射，按物理 QWERTY 位置读取，目前不做改键面板。

| 键盘 | Switch 输入 |
| --- | --- |
| W | X（上面键） |
| A | Y（左面键） |
| D | A（右面键，确认） |
| S | B（下面键，返回） |
| 方向键 ↑ / ↓ / ← / → | 方向上 / 下 / 左 / 右 |
| I / K / J / L | 方向上 / 下 / 左 / 右 |
| Q / E | L / R |
| Space | X、Y、A、B 同时按下 / 松开 |
| Delete / Backspace（含 Forward Delete），或 P | ＋（暂停） |
| Enter / Return（含数字键盘 Enter），或 M | － |

**Return 不再兼任确认，确认使用 D。** ZL / ZR 暂不做键盘映射，两个摇杆也不提供键盘映射或编辑。支持长按和组合；失去焦点时清理按住状态。

## 手柄与触控测试

- DualSense：圆圈对应 Switch A / 确认，叉号对应 Switch B / 返回；方向键、摇杆、四个面键、L1 / R1 已经用户实测基本正常。
- 游戏震动用《Catch the Wave》测试成功的连续长滑键。EXTREME 开头约 1.7 秒、HARD 约 26.7 秒有可用于验证的长链；只敲普通短滑键不能验证这一路反馈。
- 震动为 GameController / CoreHaptics 的近似转换，尚非位精确的 Switch HD 震动。重连、左右反馈和延迟仍需更多回归。
- DS5 内置扬声器在 Mac / 移动设备上不受支持，游戏音频从设备或耳机输出，参见 [Sony 支持说明](https://www.playstation.com/en-us/support/hardware/pair-dualsense-controller-bluetooth/)。
- 虚拟手柄采用 Switch 布局，当前缩放 200%；有实体手柄时自动隐藏，也可手动开启 / 关闭。
- 主菜单请用方向和确认键；原版菜单文字不是全部都能直接点按。原作 Touch Play 和虚拟按键触控分别验收。

## 建议的测试顺序

1. 冷启动、跳过片头、进入选曲；抽查 EXTREME / EX EXTREME 和服装直接装备，确认原成绩保留。
2. 用《Catch the Wave》检查输入与长链震动；再测暂停 / 恢复、重试、回选曲和手柄断开重连。
3. 用《ゴーストルール》检查持续负载，比较普通放大与 MetalFX，记录画质、卡顿、帧时间、音画同步和温度。
4. 使用“退出游戏”确认保存后，重新启动检查黑屏、残音、闪退和存档。

M4 iPad 早前已完成《ゴーストルール》1080p 三轮、1440p 多轮，正常演奏采样约 60 FPS，但存在少量长间隔与载入停顿。不能据此声称所有歌曲和设备稳定真实 60 FPS。Mac FPS 浮窗仍有读数问题，判断性能请同时参考帧时间日志。

## 存档与日志

| 平台 | 位置 |
| --- | --- |
| iPad | App 的 `Documents/GuestSave`、`Documents/PJDV-runtime.log`，可通过文件共享备份 |
| Mac | `~/Library/Application Support/PJDVM39/GuestSave`、同目录下的 `PJDV-runtime.log` |

全解锁策略的初次原档备份位于 `GuestSave.unlock-backup-v1/sys.dat`。保留整个 GuestSave 目录备份更方便；不要用其他版本或游戏的 sys.dat 替换。早期 Mac 测试版的旧存档仍保留在原文稿位置；本机迁移保留副本，其他旧测试环境可以在 App 退出后手动复制到新位置。

## 验证范围与已知问题

- 原生 XCI 解密器已对这份 XCI 的全部 **41,943,373,493 bytes** 文件数据完成 IVFC 校验，并逐文件与此前 Python 提取 SHA-256 对照一致；28 个分区的目录指纹、数量和字节总量一致。
- 缺失文件补全、已有资源校验复用、取消 / 续导、格式边界与非法输入检查已测试；不读取或执行 XCI 内的新程序代码，运行程序仍是已适配的版本。
- Mac 已通过系统选择器实际导入并重启恢复目录访问；修复数据目录后已进入原游戏。iPad 最终 0.1.2（build 4）已安装，资源管理与原游戏片头实机启动通过；完整大 XCI 的真机导入仍需本机 / 外置盘输入回归：开发传输通道发送该大文件时中断，不能把此项记作通过。
- 默认解锁已检查真实新档和 M4 旧档，并在真机抽查 EXTREME / EX EXTREME 与服装直接装备；没有逐项玩遍所有歌曲 / 难度 / 服装。
- 全曲画质、反射 / 光照一致性、Touch Play、更多手柄、真实持续 60 FPS、发热与音画 / 判定同步仍需验证。

更多已验证的渲染缺口、原版材质研究与历史证据见 [研究记录](RESEARCH-20261015.md)。

## 参考与致谢

主要工程参考 [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) 与 [jiayx/d2r-mobile-build](https://github.com/jiayx/d2r-mobile-build)；着色器参考 Ryujinx 翻译链；数据研究参考 [MikuMikuSwitchPlugin](https://github.com/lsmsmx/MikuMikuSwitchPlugin)、[ReDIVA](https://github.com/korenkonder/ReDIVA)、[hactool](https://github.com/SciresM/hactool)。相关许可证与署名保留在安装包 ThirdPartyNotices.txt 中。

本项目为非官方兼容研究，游戏、角色与原作资源归各自权利人。公开测试包需配合用户自己的游戏与密钥。
