# build18 — MOD interface research / MOD 接口研究

状态：本地准备版，**不加载 MOD**。本报告记录10月24日接口阶段；10月25日已增加[手动检查／登记入口](MOD-ENTRY-build18.md)，运行层仍关闭。build17 的源码和安装包单独冻结。研究日期：2026-10-24。
Status: local preparation, **no MOD loading**. build17 source/installers remain separately frozen.

## 研究基线 / Research baseline

[MikuMikuSwitchPlugin, commit 13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a](https://github.com/lsmsmx/MikuMikuSwitchPlugin/tree/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a)。只读取源码，不运行插件。本报告替代先前只抽取少量文件的 `b8025c7` 研究范围；不能把两份本地目录的文件差异都当成上游更新。
Read-only inspection of the pinned revision above; no upstream binaries executed. The older local b8025c7 research contains selected files only, so directory differences are not an upstream change log.

| 上游模块 / Upstream | 实际机制 / Mechanism | 本项目后续适配 / Future adaptation |
| --- | --- | --- |
| [ModLoader.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/ModLoader.cpp) | `priorityPaths` 决定顺序；`config.toml` 的 `enabled`、`include` 决定目录；识别 `rom`、`rom_steam/rom`、`rom_steam_en/rom`，把路径插到游戏搜索列表前 / Ordered search roots, TOML enable/include, Steam/region layout selection, prepend to guest search list | 先做只读替换已有贴图／服装；明确顺序与冲突，不修改原 GameResources / Read-only replacement of existing assets first; deterministic priority and conflicts; base assets unchanged |
| [DatabaseLoader.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/DatabaseLoader.cpp) | 把带特殊标记的路径注入 MdataMgr，解析到 MOD 专用数据库；缓存存在性；另有日语 DLC18 图片数据库修正 / Marked MdataMgr paths resolve mod-specific databases, existence cache, Japanese DLC18 sprite-DB correction | 文件覆盖和数据库扩展分为不同能力；后者还要处理 ID、语言完整性、容量及独立存档 / Separate database capability; validate IDs, localization, capacity and isolated saves |
| [PvLoader.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/PvLoader.cpp) | 歌曲 ID／循环／格式化限制及 movie 标记解析的多处程序补丁 / Multiple executable patches for song IDs, loops, formatting and movie tracking | 不能只加一个目录就宣称新增曲目兼容；须逐条验证当前 JP1.0.9 指纹和预期指令 / Adding a directory cannot establish song compatibility; verify every patch against executable fingerprint and original instructions |
| [FsHooks.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/FsHooks.cpp) | 把调试／生成资源的部分读写路径重映射到 SD 卡 / Redirects selected debug/generated-data paths to SD storage | 不照搬这些写重映射；保留现有保存事务与 AutoPlay 隔离 / Keep save transactions and AutoPlay isolation; do not redirect writes through the asset seam |
| [MemoryHooks.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/MemoryHooks.cpp) | 内存池回退和稀疏高 ID 数据库分配修正 / Pool fallback and sparse high-ID database allocation fixes | 将来导入时先统计内存预算和 ID 稀疏度；不能承诺任意 PC MOD 能在 M1 内存内运行 / Preflight memory budget and ID sparsity; no assumption arbitrary PC mods fit M1 memory |
| [FTRestoration.cpp](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/source/program/FTRestoration.cpp) | FXAA／MLAA／TAA、SSS、阴影与色调等针对游戏程序的恢复补丁 / Guest-specific AA, SSS, shadow and tone-map restoration | 独立的渲染研究线索，**本次未启用**；恢复游戏 TAA 不等于 MetalFX Temporal，也不等于帧生成 / Separate research only, disabled here; guest TAA is neither MetalFX Temporal nor frame generation |

## build18 已落地 / Implemented

原生自有 C ABI：`Runtime/dm/host/pjdv_mod_interface.h` 和 `.inc`；本机实际运行源码在外置卷 `Runtime/PJDV/dm/host`。没有复制上游插件实现。
Own native C ABI, not copied plugin implementation. The public source layout uses `Runtime/dm/host`; the private development runtime lives on the external SSD.

- ABI 版本与结构长度；只读资源查询类型；预留独立的资源覆盖／数据库扩展能力标志；状态查询。
- Version/structure-size checks, read-only query contract, separate reserved asset/database capability bits, status query.
- `hle_fs.c` 中只在只读挂载、非创建路径预留查询点。当前始终回落到原有内置覆盖、路径别名、缓存和基础资源逻辑；保存／临时写路径不走此接口。
- Read-only non-create filesystem resolution has a reserved query seam. It always falls back to existing compatibility overlays, aliases, caches and base lookup. Save/temp writes do not use it.
- 状态始终为零个启用能力、零个 provider。注册函数始终拒绝激活，不保留也不调用回调。查询不读输入路径、不访问文件、不分配内存、不改变输出缓存或 errno；没有环境变量、设置开关或文件可以开启它。
- Zero active capabilities/providers. Registration refuses activation and retains/invokes no callback. Queries perform no path reads, filesystem access or allocation and preserve output and errno. No environment variable, preference or file activates it.
- 10月24日接口阶段未提供 MOD 导入界面；10月25日增加手动结构检查／位置登记。仍无自动扫描、TOML 解析、第三方 NSO／DLL／dylib 加载或新增歌曲；XCI 导入流程保持原样。
- The October24 interface-only stage had no import UI. October25 adds manual structural inspection/source registration, with no automatic scan, TOML parsing, third-party binary execution or new songs. XCI import is unchanged.

## 后续实现前必须解决的边界 / Required future boundaries

第一阶段建议只替换既有资产，独立可撤销目录，原资源只读。相同路径冲突需明确优先级并报告覆盖者；相对路径需规范化并拒绝越界、符号链接逃逸、重复大小写与大小限制问题。目录列举、存在性检查、打开文件必须一致；按会话冻结搜索计划，换包时统一失效路径、数据库、FARC、着色器和纹理缓存，不能在运行中随意变更搜索根。

First phase: reversible replacement of existing assets from a separate directory. Validate relative paths and symlinks, case collisions, size limits and deterministic precedence. Enumeration, metadata checks and file opens must agree. Freeze a search plan per session; invalidate path/database/archive/shader/texture caches together before a new session. The reserved ABI alone does not implement these checks or provide a loader.

新增歌曲／服装数据库应在第二阶段独立实现：Title ID、程序 Build ID 和原始字节指纹匹配后才允许原生自有适配；资源／shader／格式兼容需单独核验，USM→MP4 也不解决所有编解码问题。新 ID 不得覆盖原记录，测试档不得合入正常档。导入失败不得留下半完成数据库。不同语言的图片与文字要同时验证。

Database extensions are a later capability. Require matching Title ID, executable Build ID and expected instruction fingerprints for native adapters. Validate formats/shaders/video codecs separately. New IDs must not collide with existing content or records; use separate test saves and atomic import state. Check both localized text and image resources.

上游是 Switch exlaunch 注入环境，PC 插件是另一套 ABI；同为 ARM64 不能直接加载。上游有直接地址和 `FIX(addr)`，示例 `DetermineUserVersion()` 仍返回 DEFAULT，不能把它当成自动支持所有版本的依据。本项目不得直接应用这些偏移。

Switch exlaunch and PC plugin ABIs cannot run directly in this signed Apple host. Upstream contains hard-coded addresses, `FIX(addr)` conversions and a default version stub; these do not establish cross-version support. Do not apply upstream offsets directly.

[上游 LICENSE](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/13bc9fabdf5e8249a7e65c5c724ec0a52d345e2a/LICENSE) 为 GPL v2 文本。以后若复用具体实现，须保留对应源码和许可，并审查其依赖；本次只独立预留接口，没有引入上游实现或 MOD 素材。
Upstream LICENSE is GPL v2 text. Any future implementation reuse needs the applicable source/license/dependency treatment. This change only introduces independent contracts, with no upstream implementation or mod assets.

## 验证 / Validation

C ABI ASan/UBSan 测试：10 万次查询保持输出与 errno，空请求安全回落，异常 ABI 拒绝，伪 provider 回调从未执行，环境变量不能打开加载。
C ABI ASan/UBSan checks: 100,000 fall-through queries preserve output/errno; null request is safe; unsupported ABI is refused; fake callbacks never run; environment activation has no effect.

Mac／iOS Release 编译及 Mac 启动检查另记于外置 SSD 的 `Build/ModInterfaces18-20261024/VERIFICATION18.json`。构建通过不代表 MOD 兼容或实际 MOD 加载通过；本版没有加载测试目标。
Mac/iOS Release builds and Mac startup are recorded separately in `VERIFICATION18.json`. Compilation or launch does not qualify MOD compatibility; loading is intentionally absent.
