# New Classics 依赖与可选玩法底座 / Dependencies and optional gameplay foundation

2026-10-29。研究结论：可借鉴 MobileSubstrate 的统一接口和依赖管理思想，为 PJDV 实现限定在游戏会话内的扩展底座。**New Classics 的 ARM64 玩法移植尚未实现，现阶段没有执行 PC DLL。**

## 已取得的上游材料

- [作者发布页](https://divamodarchive.com/post/169)：作者推荐 F／F2nd／X Charts，建议同时使用 [ExPatch](https://github.com/nastys/ExPatch/releases/tag/2.2)，并说明 AutoPlay 等修改玩法状态的插件可能存在冲突。
- [New Classics 源码](https://github.com/mrcloverthecoder/nc/tree/c41d4f1c7113ff44dbc7afb888803ea252e201f6)：固定提交 `c41d4f1c7113ff44dbc7afb888803ea252e201f6`，MIT 许可证；`src/build_info.h` 为 1.2.1。源码目录的旧 `assets/New Classics/config.toml` 仍写 0.1.0，不能用它推定当前实现版本。
- 从作者页下载的 ZIP：10,987,982 B，SHA-256 `09012a73518ec6f3d646f9e4236bb4d41785c5edd22bef7d3b2f29486805135e`；23 条目录／文件记录，展开总计 13,746,815 B。实际包配置为 **1.2.0**，与当前源码有小版本差异，需核对。
- 包内包括 `NewClassics.dll`、`LeaderboardBlocker.dll`，两者均为 PE x86-64；另有精灵／AET 图标、菜单文字和音效。下载包与源码快照仅在本地研究目录保存。

## 依赖链

| 组件 | 作用 | 我们的处理方向 |
| --- | --- | --- |
| [DIVA Mod Loader](https://github.com/blueskythlikesclouds/DivaModLoader) | PC 端 DLL 装载、资源覆盖和数据库合并 | 对应职责由 PJDV 的宿主接口、资源加载与组合转换承担；不是直接加载 Windows DLL。 |
| New Classics 核心 | Console／Mixed 谱面、长按、连星、Rush、Chance Time、Technical Zone、判定和计分 | 将算法与状态机移植为 ARM64 宿主组件，逐个匹配 Switch 游戏函数和结构。 |
| New Classics 资源底包 | 图标、菜单、AET、音效和配置 | 作为可导入的数据包，登记版本与资源校验值。 |
| LeaderboardBlocker | 作者包声明的另一个 DLL | 本项目需维持实验成绩隔离规则；不能假定复制 DLL 即有对应行为。 |
| ExPatch | 作者建议的难度开放补丁 | 上游 2.2 解锁 Extreme／Extra-Extreme。PJDV 已有难度开放功能，但仍需验证 New Classics 的选曲流程，不宣称全部等价。 |

本地 `nc_db.toml` 核查：X Charts 为 32 个曲目项／128 个谱面引用，F Charts 为 37／148，所指谱面均在对应包中。F2nd Charts 为 57／228，其中 `pv_606` 的 easy／normal／hard／extreme 四个路径不在 F2nd Charts 自己的包内，已在 **F Charts Pack** 中找到。它是《World’s End Dance Hall -F Edition-》的跨包资源引用；联合启用仍须合并同曲的谱面设置。

组合关系：`X Charts → New Classics + X Song`；`F2nd Charts → New Classics + F2nd Song`；`F Charts → New Classics`。F2nd Song 本轮 SPiCa 的 Auth3D 启动异常是另一项资源兼容问题，安装 New Classics 不构成修复证据。

## 与 Substrate 类似的部分及边界

### 补充：优先研究现成的 Switch 移植与资源加载器

本轮再次读取 [MikuMikuSwitchPlugin](https://github.com/lsmsmx/MikuMikuSwitchPlugin/tree/04d3f174dc62615a1178b914e3a4ded87665b98c)，固定提交 `04d3f174dc62615a1178b914e3a4ded87665b98c`。作者 README 声称 New Classics 已移植约 95%，并要求使用原 PC 版资源；这是上游自报进度，**不是本项目 iPad 验证结果**。源码中实际包含 `source/program/nc`、DSC／音符状态／长按与连星／计分／菜单接入。因此优先评估这份 Switch 实现，再与 MIT 的 PC 原版逐项对照，不必假定所有 ARM64 玩法都要从零重建。

已核对的管理器相关实现：

- [Config.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/04d3f174dc62615a1178b914e3a4ded87665b98c/source/program/Config.cpp)：扫描 MOD 子目录，保存 `priority`；新目录按名称排序后追加到现有顺序。
- [ModLoader.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/04d3f174dc62615a1178b914e3a4ded87665b98c/source/program/ModLoader.cpp)：读取 `enabled`／`include`，按地区选择 `rom_steam`／`rom_steam_en` 并回落到另一地区；也支持 `rom`。将 MOD 搜索根插到原资源之前，靠前的优先。
- [DatabaseLoader.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/04d3f174dc62615a1178b914e3a4ded87665b98c/source/program/DatabaseLoader.cpp)：为 MOD 数据库建立前缀与路径解析，缓存文件存在性，另有日语 DLC18 精灵数据库重定向。
- [nc/mod.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/04d3f174dc62615a1178b914e3a4ded87665b98c/source/program/nc/mod.cpp)：有 Switch 主模块偏移下的加载、状态清理、谱面解析和长按／连星接入。它依赖游戏结构与接入点，尚未接入 PJDV。
- [MemoryHooks.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/04d3f174dc62615a1178b914e3a4ded87665b98c/source/program/MemoryHooks.cpp)：提供分配池回退等研究材料；我们的安装解压内存与游戏运行内存须分别测量。

它可作为**加载层和游戏适配层**的参考；iPadOS／macOS 管理界面仍使用宿主界面。依赖版本解算、循环检查、冲突预检、安装进度与事务回滚，应在宿主补充。所读 `Config`／`ModLoader` 的优先级列表不能替代这些检查。

不能直接启用整套插件：它包含 `nn::fs`、exlaunch／Atmosphère 路径和固定偏移；`version.hpp` 的版本选择仍返回 `DEFAULT`。`nc/nc.cpp` 中 `enableNewClassics` 只围住部分 UI 初始化，其后仍初始化多项核心 hook，不能把此开关当成完全卸载。我们的实现需按已验证的游戏 build ID 检查指令、隔离实验存档，并在会话启动前确定组合。

上游根目录 [LICENSE](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/04d3f174dc62615a1178b914e3a4ded87665b98c/LICENSE) 是 GPL v2 文本，与 PC New Classics 的 MIT 不同；若复用具体代码，须保留对应来源、许可和修改记录并核对发布方式。本轮只保存研究快照，未将其代码编入或激活在 App 中。

Substrate 的[运行接口](https://www.cydiasubstrate.com/api/c/)提供函数定位、替换及调用原实现的共同约定。PJDV 可以借鉴统一接入点、依赖版本和执行顺序，范围限定在自己的游戏会话内。

建议分两部分：

架构上，最接近 Substrate 的应是 PJDV 提供的通用 MOD 接口层；New Classics 是其上的可选玩法兼容层，不能要求每个普通歌曲或模型包都依赖它。

1. **随宿主编译的兼容核心**：暴露谱面加载、音符状态、输入、判定、计分和会话生命周期接口。ARM64 接入点绑定已验证的游戏 build ID，不沿用 PC 的固定地址、Windows hook 库或 C++ 对象布局。
2. **MOD 管理中的资源底包**：携带版本、能力需求、图标、音效和配置。依赖的 Charts 包在启动前检查核心能力和资源版本；缺失或不匹配时阻止启用，普通歌曲／模型包仍可独立运行。

依赖图应检查缺项、版本和循环；多个包以“曲目 ID＋难度＋edition＋玩法风格”为谱面合并键。加载优先级不能替代对象、纹理、精灵和 PV 数据库的实际合并。上游 `src/db.cpp` 仍明确标有 `nc_db` 同曲风格叠加的 TODO，当前移植不能直接宣称任意组合都能叠加。

核心可先提供一个明确处于“未实现”状态的能力登记，依次验收 DSC 合成、星键／长按／连星、判定和计分、菜单与结果显示。完成前不向 Charts 包报告能力可用。玩法底座启停仅在游戏会话开始前生效，切换组合使用独立存档空间；AutoPlay 继续使用临时存档，测试结果不合回正式记录。

## English

New Classics is a feasible **optional gameplay foundation** for PJDV. The useful Substrate analogy is a shared interface, dependency/version checks and ordered integration inside the game's own session. The ARM64 gameplay port is **not implemented**. No Windows DLL has been executed.

The author ZIP is version 1.2.0 (10,987,982 bytes; SHA-256 above), while pinned source commit `c41d4f1c7113ff44dbc7afb888803ea252e201f6` declares 1.2.1 in `build_info.h`; its old asset config still says 0.1.0. These must not be treated as matching builds. The archive includes x86-64 PE `NewClassics.dll`, `LeaderboardBlocker.dll`, sprite/AET resources, menu strings and sounds. Code is MIT-licensed; the original notice is retained locally.

The proposed split is an ARM64 core compiled with the host plus a versioned resource foundation imported through MOD Manager. The host owns DSC merging, note state, input, judgment, scoring and lifecycle interfaces, bound to verified Switch build IDs and layouts. The resource package declares the required capabilities and assets. Missing/unimplemented capabilities prevent dependent chart activation. Ordinary song/model MODs remain usable independently.

The closest Substrate analogue is the host's generic MOD interface layer. New Classics is an optional gameplay compatibility extension above that layer, rather than a mandatory dependency of every song or model package.

X Charts requires New Classics plus X Song; F2nd Charts requires New Classics plus F2nd Song; F Charts requires New Classics. Local X/F chart references resolve, while F2nd's four `pv_606` chart paths are supplied by **F Charts Pack**, outside its own folder. Combined loading must still resolve the two packages' overlapping song configuration. ExPatch is recommended upstream, rather than declared as an unconditional core requirement. The author also warns about AutoPlay compatibility; an ordinary song/model AutoPlay test is not validation of New Classics gameplay.

Dependency ordering must be accompanied by real database merging. Chart identity should include song, difficulty, edition and gameplay style. Upstream still has a TODO for stacking styles of the same song, so unrestricted multi-MOD compatibility is not established. Keep combination-specific saves and disposable AutoPlay sessions; never merge experimental scores into normal saves.

The current MikuMikuSwitchPlugin snapshot (`04d3f174dc62615a1178b914e3a4ded87665b98c`) includes an actual Switch New Classics implementation. Its README's roughly 95% completion claim is the author's assessment, not a PJDV test result. Prioritize evaluating this Switch implementation alongside the original PC code. Its MOD directory discovery, TOML enable/include rules, ordered resource roots, regional fallback and database prefix handling are relevant loading-layer references. The native Apple manager still needs dependency/version checks, conflict analysis, bounded installation, progress and rollback.

Do not activate the entire plugin unchanged: it depends on Horizon/exlaunch interfaces and fixed game offsets, version selection still returns DEFAULT, and its New Classics flag does not guard every core hook. The repository's GPL v2 license also differs from original New Classics' MIT license. Only a research snapshot has been saved; no upstream plugin code has been compiled into or enabled in this App.
