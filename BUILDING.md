# 源码与构建（2026-10-23）

本仓库现在包含实际使用的 Swift/UIKit 宿主、Mac AppKit 辅助组件、NVN → Metal／Horizon 兼容层、逆向处理工具和测试。当前源码版本为 **0.1.5 build11 修复候选**；GitHub 已发布的安装包仍是 **build10**，没有用新源码覆盖历史附件。

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

## build11 文件导入修复候选

反馈设备已确认是 **iPad Pro 2021／M1、iPadOS 18**，现象为点击 XCI 后选择窗口不关闭。之前按照 Mac 反馈准备的修复不能据此视作解决。

- iPad／iPhone：在 Info.plist 声明外来 XCI／keys 文件类型和扩展名；选择器显式支持对应格式，并保留 `public.item` 以接受 Files 提供方的动态／未知类型。格式仍由导入器校验。显示受支持扩展名，方便识别 ZIP／7z 尚未解压的情况。
- 收到文件 URL 时先取得安全作用域访问，在文件窗口关闭后才处理选择或开始导入；整个后台读取期间保留源文件访问。不使用 `asCopy: true`，不移动或预先复制整份 XCI。
- Mac：使用现有 AppKit 辅助 bundle 中的 `NSOpenPanel`。不依据未知扩展名灰掉文件；XCI → 目标位置两个面板串行打开。
- 预检阶段显示活动指示和阶段文本，开始提取后显示字节进度。取消不会启动导入，失败显示具体错误。

验证：iOS／模拟器／Mac Release 编译通过。iPadOS 27.2 模拟器的独立测试容器中，验证了 XCI 与 keys 可选、错误显示、取消恢复，以及合成密钥＋小型合成 XCI 从系统选择窗口到资源清单／完成标记的完整导入，合成源文件哈希保持不变。测试没有拷入真实游戏或密钥。回归步骤见 [Tests/ImportPicker/README.md](Tests/ImportPicker/README.md)。

**验证边界：** 本机没有 iPadOS 18 模拟器运行时，尚未在反馈者 M1／iPadOS 18 设备回测；不能宣称该问题已在原设备修复。GitHub 历史 build10 安装包不含这些修改。build11 的本地精简 IPA 是待回测候选，需要有效签名。

Apple API 参考：[文件类型声明](https://developer.apple.com/documentation/UniformTypeIdentifiers/defining-file-and-data-types-for-your-app)、[UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)、[NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)。
