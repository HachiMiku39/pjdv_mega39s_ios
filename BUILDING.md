# 源码与构建（2026-10-25）

本仓库包含 Swift/UIKit 宿主、Mac AppKit 辅助组件、NVN → Metal／Horizon 兼容层、逆向工具和测试。公开源码与精简预览包为 **0.1.5 build19**。AutoPlay、调试信息和热切换的实际验证范围及限制见中英文 README。游戏资源、密钥、存档和本机签名数据不发布。

The public source and lightweight preview installers are **0.1.5 build19**. Both READMEs describe measured AutoPlay, diagnostics and hot-switch checks and outstanding limitations. Game payloads, keys, saves and local signing data are excluded.

## 源码目录

| 目录 | 内容 |
| --- | --- |
| `Sources/` | 启动界面、输入、图形选项、XCI 导入和资源管理 |
| `Sources/MacLifecycle/` | Mac 原生文件选择与正常退出组件 |
| `Runtime/dm/host/` | Horizon 服务和游戏会话兼容实现 |
| `Runtime/dm/gfx/` | NVN → Metal、纹理解码、视频和实验功能 |
| `Runtime/dm/third_party/` | 实际使用的 bcdec 和修改后的 Ryujinx 着色器库源码及许可证 |
| `Tools/` | NSO 分段重写、CPU 等价验证、资源分析与着色器准备工具 |
| `Tests/` | 导入变体、输入、语言、显示策略等检查 |

运行层基于 `jhaizhou-ops/d2r-mobile` 的 `ea86e79688f9339319de3e2c52c69b8b13e30e9e` 参考版本裁剪和修改，保留了部分未启用的上游 D2R 代码。实际参与 App 编译的文件以 Xcode 工程为准。`Runtime/LICENSE`、`Runtime/dm/third_party/` 和 `Assets/ThirdPartyNotices.txt` 保留依赖声明。

## 可以直接运行的核心测试

在 Apple Silicon Mac 上安装 Xcode／命令行工具和 Python 3。无需原游戏、真实密钥或签名即可运行：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PJDV_TEST_ROOT="/Volumes/你的APFS外置盘/PJDVTests/import-01"
bash Scripts/test-core.sh
```

测试目录必须尚未存在。脚本只生成小型合成容器和确定性的虚构密钥，验证导入版本识别、DLC 子集、改名 NCA、错误包拒绝、取消续导、语言回落、源文件不变，以及预检阶段的状态回调。这不代表商业游戏的渲染或性能验收。

## 构建完整游戏宿主前需要的本地输入

原始 XCI、NSO、提取后的资源、重写得到的 ARM64 段、生成的着色器及个人存档均不在仓库内。**只克隆源码还不能完成完整 App 的链接。** 运行程序仍固定到已适配的 JP v1.0.9；任意版本 XCI 导入不等于任意原程序可运行。

在本地、未纳入版本控制的 `PrivateBuild/` 准备以下结果：

```text
PrivateBuild/
├── segmented/       # gen_guest_embed.py 验证证书后生成的 GuestImages.S、GuestLayout.h 等
├── RendererAssets/
│   ├── Shaders/shader_map.tsv
│   └── MetalCache/b-pjdv-842acf8d7583/
└── ExitMenu/         # 从自己的资源准备的菜单覆盖，含 manifest.json
```

NSO 工具流程见 `Tools/rewriter/patch_nso_segmented.py --help`、`equiv_segmented.py --help` 和 `gen_guest_embed.py --help`；只有与原始模块一致的等价验证证书才允许生成嵌入段。资源／着色器工具的输入与命令选项分别见 `Tools/bnsh_jobs.py`、`Tools/build_miku_msl.py` 与 `Runtime/dm/gfx/tools/`。当前保留的工具并非一个已经验收的“一键从任意 XCI 生成 App”流程；版本相关的运行时捕获、参数和资源准备仍需手动研究。公开仓库没有附上商业游戏派生构建数据来填补这些步骤。

着色器工具使用 .NET 10 和 SPIRV-Cross；Python 研究工具依赖见 `requirements.lock.txt`，图标配方分析额外使用 Pillow／NumPy。运行资源菜单导入 XCI 本身是原生 Swift 路径，无需这些开发工具。

工程中的运行层与本地输入路径已转换为仓库相对路径，不要求外置盘使用开发机的卷名。部分历史研究脚本仍保留原开发目录默认值，使用时需通过脚本参数指向自己的工作目录。

## 编译

源码可放在外置盘，DerivedData／模块缓存／临时文件使用 APFS 构建目录：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SWITCH_IOS_BUILD_ROOT="/Volumes/你的APFS外置盘/PJDVBuild"
bash Scripts/build.sh mac
# 或 device / simulator
```

默认不签名，不内置密钥。公开构建脚本会拒绝 `PJDV_EMBED_KEYS=1`。真机安装必须使用自己的有效签名，发布包内不得有开发者团队配置、描述文件、XCI、GameResources、prod.keys 或个人存档。

目标为 iOS／iPadOS 17 和 Mac Catalyst 14／macOS 11；Mac 最低 M1。当前 Xcode 27 SDK 对 Big Sur 目标会给出最低部署版本警告，工程保留兼容构建设置；**实际 Big Sur／M1 设备运行仍待验证**。GPU 功能档位与 API 可用性分别检查。

## build13 导入改进候选

M1 iPad Pro 2021／iPadOS 18 的录屏显示 build11 仍不能从系统文件列表选中 XCI／密钥。原生文件选择的根因尚未在该设备定位，不把模拟器或 M4 通过视作该问题已解决。

- 保留已声明的 XCI／keys UTType、未知类型回退、源文件就地读取及安全作用域；系统窗口完成后再处理选择。
- 新增目录授权入口：系统选择所在文件夹，App 自己列出对应扩展名的普通文件。目录访问随所选文件保留到导入结束。参见苹果的 [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)。
- `AppImportInbox` 仅扫描 App 暴露的数据根目录。启动首页每两秒检查，元数据稳定至少四秒后开始校验；大小／时间变化会重新等待。多个候选由用户选择，成功签名记录防止重启重复导入。目录／符号链接／零字节条目不作为输入。
- 进度显示阶段、资源完成量／总量、百分比、应用层读写速度、累计量和耗时。`ImportIOMeter` 使用单调时钟和加锁计数，读取计入 XCI 及已有资源校验；写入只计成功输出的资源数据。每 0.5 秒采样，空闲和结束时显示零速率，续导不虚增写入。含缓存影响，不能当作物理 SSD 性能。
- Mac 保留 `NSOpenPanel` 及串行选择源／目标，App 根目录自动导入使用其本机数据目录。

验证记录：iOS／模拟器／Mac Release 编译通过；合成容器测试覆盖计数、空闲速率、并发计数、已有资源续导、根目录扫描与复制变化等待。iPadOS 27.2 模拟器在独立空白容器中，直接从根目录自动导入 64 MiB 合成 XCI，完整标记和有效载荷通过，源文件哈希不变；重启未重复导入。M4 iPadOS 27.2 已安装 build13，真实密钥经用户明确授权，仅传到该设备本地；根目录自动识别与保存通过。系统选择器的 XCI／keys 关闭和错误路径也在 M4 验证。合成密钥未覆盖真机密钥。

尚未验证：反馈者 M1／iPadOS 18、第三方 Files 提供方以及这次改动后的 40+ GB 真实 XCI 全量导入。历史 build10 Release 附件未替换；本地 build13 精简 IPA 是待回测候选，不含真实密钥、资源或开发签名。

## build14 导入内存修复（2026-10-24）

M1 8 GB iPad 用户报告累计提取约 7 GB 后退出。只读复现发现，Darwin `FileHandle.read(upToCount:)` 桥接的临时对象会滞留到长 GCD 工作项结束；流式读取本身并不足以限制内存。增加读取、本地文件校验、每文件和每 1 MiB 写入块的局部 `autoreleasepool`，保留 IVFC、SHA-256、文件同步及取消续导校验。预检路径临时对象也逐文件释放。参见苹果的 [NSAutoreleasePool 文档](https://developer.apple.com/documentation/foundation/nsautoreleasepool)。

同一真实 XCI 的 macOS 只读／解密／完整性校验探针：修复前处理 942,314,033 字节时 footprint 已达 1,078,379,720 字节，主动保护停止；修复后处理 8,623,614,129 字节，结束 footprint 为 112,853,544 字节，采样峰值 116,785,704 字节。该结果不是 M1 真机数据。 后续同一 XCI 的全部选中资源（本体及 27 DLC）只读遍历完成：41,943,373,493 字节，结束 footprint 为 117,686,824 字节，采样峰值同为 117,686,824 字节；仍未包含真机写盘与最终资源提交。

`Scripts/test-core.sh` 增加 `StreamingMemoryTests.swift`：在单个 GCD 工作项中，从 1 MiB 合成文件连续读取 8 GiB；验证返回 Data 在池释放后仍有效，并将内存增长限制在 128 MiB 内。旧读取代码在约 129 MiB 时失败，修复后通过。测试只生成约 1 MiB 临时文件，不占用 8 GiB 磁盘。

资源导入界面每 0.5 秒显示进程 footprint 和采样峰值；每五秒持久化累计读写量、耗时和内存到 App 根目录 `PJDV-import-diagnostics.jsonl`。成功／失败及系统内存警告会额外记录。下一次导入开始时，保留上一会话到 `PJDV-import-diagnostics.previous.jsonl`（旧日志上限 8 MiB），避免自动续导覆盖崩溃前记录。日志不包含文件路径、游戏资源、密钥或存档，留在本机。日志是进程内采样，不能替代系统 Jetsam 终止原因。

M4／iPadOS 27.2 本轮已备份存档、卸载并重装 build14；42,716,664,832 字节原始 XCI 完整传入并抽样核验。用户重新信任开发签名后，自动导入在 95.89 秒内成功写入 41,943,373,493 字节，读入 42,359,651,800 字节；0.5 秒采样峰值为 124,601,208 字节，结束内存 117,359,480 字节，无内存警告或异常退出。全部 28 个卷（本体＋27 DLC）的完成标记、22,391 条唯一文件记录及字节总数核对一致，没有未完成标记。个人存档已从重装前备份恢复并回读哈希；合并恢复原显示／输入／语言设置，保留新导入完成签名。M1 8 GB／iPadOS 18 仍需反馈设备回测；这不是同款设备终止原因的确认，也不是全曲游戏内存或帧率验收。

独立模拟器 `com.local.pjdv.memimport14` 验证通过：64 MiB 虚构容器从 App 根目录自动导入，界面显示 100%、约 28 MB 进程内存和采样峰值；再次手动检测同一文件完成校验续导，新增写入为零。当前／上一轮日志都以 success 结束，上一轮 67,109,009 字节写入记录保留。此测试不使用真实密钥，不替代 M4 整份 XCI 写盘验收。

## build15 原生 Touch Play 与全部控件布局（2026-10-24）

快速重复使用同一触点 ID 时，旧单槽会把未读取的再次按下合并；改为每 ID 最多 16 个有界 stroke，保留每次 Start／End，移动在同一次 stroke 内合并，溢出不遗留按住状态。`dm_touch_reset()` 在失焦时清空全部排队／按住触点。Swift 发布端串行提交 pad 与 touch，并拒绝较旧修订号，避免控制器线程把已松开的触点写回。

旧代码三次快速点击复现断言失败；修复后扩展 NativeTouchTests、ASan／UBSan、原 13 项触控 ABI、InputCore 并发与旧快照回归通过。布局模型兼容旧 two-stick JSON；18 控件、矩形肩键比例、边界及编解码测试通过。A16 模拟器验证 A／ZR 位置、尺寸、保存重启与取消不覆盖。Device Hub 的远程拖动未能移动控件，当前验证的是点空白定位；真实手指拖动仍需实机回归。

M4 覆盖安装输入候选成功，但启动因设备锁屏被阻止；M1／iPadOS18 未直测。M1《39みゅーじっく！》40–50 FPS 尚无匹配场景的前后对比，不声称已优化。现有 whole-frame 光流插帧候选此前 PV 轮廓失真，且 source30 改变原游戏出帧节奏，维持研究启动参数门控。苹果 SDK 的 MTLFXFrameInterpolator 标注 iOS／Mac Catalyst 26 起可用；不能把该 API 当成 iPadOS18 的回退方案。


## build16 ProMotion / Spatial 回归

`Runtime/dm/gfx/nvn/pjdv_fg_policy.h` 统一源帧／显示节奏，模式1为30/60，模式2为60/120。120的显示回调不再以固定两个tick阻塞源游戏，系统降至60Hz时不应因此将游戏减半为30。退出插帧恢复此前显示链模式。宿主按GPU family、设备种类、屏幕刷新率与低电量状态限制120；GPU错误回退原生60。

`pjdv_fg_spatial.inc` 在图像插帧使用的传统Metal队列中编码Spatial，使真实／生成帧经过相同的超分路径。取消研究启动强制1080p普通放大和菜单过滤；M3+ Mac／iPad保留1440p／屏幕匹配。HDR选择退出插帧。帧生成本身仍为图像光流，不是Apple MetalFX FrameInterpolator。

新增 `Tests/FrameGenerationPolicy/main.c` 验证两个模式的源帧周期／显示目标；`Tests/FrameGenerationSpatial/main.m` 需支持MetalFX的真实GPU，验证首个真实帧、生成帧的Spatial输出、尺寸、GPU成功及关闭回退。不支持时返回77，不以模拟器代替真实GPU验收。示例（从项目根目录，编译输出放自己的构建目录）：

```sh
xcrun clang -fobjc-arc -O2 -I Runtime/dm/gfx/nvn -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore Tests/FrameGenerationSpatial/main.m -o /tmp/pjdv-fg-spatial-test
/tmp/pjdv-fg-spatial-test
```

研究日志分别记录sourceFPS、generatedFPS、presentedFPS、lastFGGPUms和lastRealCopyGPUms；普通复制不能覆盖插帧GPU耗时。`PJDV_FG_CAPTURE=1` 下可向GuestTemp/fg-capture.request写入新整数，下一次生成时本地读回previous/current/generated及存在时的Spatial输出；仅用于开发诊断，勿把游戏图像或设备日志当作公开安装包内容。


## build18 MOD 入口与合成包测试

启动页新增 MOD 管理，只检查结构并登记原位置书签，运行层加载仍关闭。ZIP/ZIP64 仅读目录；7z/RAR 请先解压后添加文件夹。见 [入口与测试说明](Reports/MOD-ENTRY-build18.md)。

```sh
export PJDV_TEST_ROOT="/Volumes/你的APFS外置盘/PJDVTests/mod-01"
bash Scripts/test-mod-packages.sh
```

测试输出目录必须尚未存在；ASan 检查 ZIP64、路径与元数据边界、取消、150 次元数据变异、书签登记和源文件保留。没有真实 MOD／游戏资源。Mac UI 已验证，iPad 真机入口尚未验收。

The launcher MOD manager only inspects and registers source bookmarks; loading remains disabled. Run the synthetic ASan package tests above in a fresh output directory. These tests do not qualify real MOD playback.


## build19 MOD 下载和流式解压 / Streamed MOD imports

`Sources/ModDownloadBrowser.swift` 使用隔离 WKWebView 和磁盘下载任务；`ModInstaller.swift` 单任务分块解压 ZIP 并校验 CRC，支持取消／空间检查。合成回归：

```sh
PJDV_TEST_ROOT="/Volumes/ExternalSSD/PJDVTests/mod-install-01" bash Scripts/test-mod-install.sh
```

The importer uses bounded chunks and does not activate imported packages. Only explicit offline conversion profiles are provided in `Tools/pc_mods`; they require your own extracted game/MOD assets and an isolated test save. No test overlays are bundled. See `Reports/MOD-DOWNLOAD-CONVERSION-20261029.md` for tested scope and unresolved Calc/New Classics issues.
