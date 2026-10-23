# 源码与构建（2026-10-23）

本仓库现在包含实际使用的 Swift/UIKit 宿主、Mac AppKit 辅助组件、NVN → Metal／Horizon 兼容层、逆向处理工具和测试。当前源码版本为 **0.1.5 build13 导入改进候选**；GitHub 已发布的安装包仍是 **build10**，没有用新源码覆盖历史附件。

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
