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

针对 M1 用户反馈的“选择本地文件没有反应”，Mac 改用现有 AppKit 辅助 bundle 中的 `NSOpenPanel`，不再通过 iPad 文档选择器选择 XCI／密钥。不依据未知扩展名的 UTType 灰掉文件；选择后仍由原有解析器检查文件格式和密钥。XCI → 保存位置的连续面板在前一面板关闭后串行打开。

预检新增阶段状态和活动指示；真正开始资源复制后再显示字节进度。选择密钥或取消文件窗口不会假装开始导入，失败会显示明确错误。

当前 Mac／iOS Release 编译、合成容器回归，以及当前 Mac 的原生选择面板／错误回调／XCI 到目标面板／取消行为已验证。反馈者尚未提供 macOS 版本，不能据此宣称该 M1 环境已修复。安装包 build10 不包含本项修改。

Apple API 参考：[NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)、[UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)。
