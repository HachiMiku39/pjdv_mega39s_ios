# build24 启动页 / Launcher

2026-11-19 · 精简预览 / Lightweight preview

## 中文

启动页参考 macOS27 的系统设计：采用系统颜色、字体与控件，内容区保持清楚的层级，材质用于侧栏与主要操作。支持的新系统使用原生 Liquid Glass 开始按钮，旧系统回落兼容按钮，不提高最低系统版本。

- 宽窗口展示侧栏与内容区；宽度小于980点或使用辅助功能字号时隐藏侧栏，并将资源／Mod 入口移入单栏主区。更窄的内容区把设置与封面排列为纵向，保留滚动。
- 封面使用现有 App 图标原图，不重绘。开始按钮保留资源完整性检查与原有启动动作；资源未就绪时仍禁用。
- 画质、语言、虚拟按键布局与 AutoPlay 使用既有菜单／控制器。图形实验仍受原有设备能力检查约束。资源可用且根目录没有待导入文件时，隐藏重复的导入提示；自动检测逻辑保留。
- 支持系统明暗色、可缩放文字、指针交互及五种 UI 语言。侧栏和主要按钮采用系统提供的材质／样式，未自行模拟玻璃滤镜。

验证：Mac Catalyst arm64 与 iOS arm64 Release 编译通过；五种本地化文件与项目文件语法检查通过，封面与原图 SHA-256 一致。本机曾启动候选并完成资源预检，捕获日志没有约束冲突或崩溃。

**限制：** 预览控制工具连续连接失败，未取得截图。最终外观、窄窗口、明暗样式、辅助功能字号以及按钮／菜单交互均未完成实际验收。编译通过与日志检查不能代替视觉或操作验收。本轮不宣称游戏帧率、渲染或输入问题已新增修复；无新的 iPad／iPhone 真机测试。

公开精简包不含游戏／Mod 资源、XCI、密钥、存档或个人开发签名配置。IPA未签名，需要自己的有效签名；Mac为arm64、ad-hoc签名、未公证。升级前备份存档，优先覆盖安装。

## English

The launcher follows macOS27 system-design conventions: system colors, typography and controls; clear content hierarchy; materials reserved for navigation and the main action. The native Liquid Glass start-button style is used when available, with an older-system fallback and unchanged minimum targets.

Wide windows show a sidebar. Below980 points or with accessibility text sizes, resource/Mod actions move into the single-column main area. Narrower layouts stack the settings and artwork vertically and remain scrollable. Existing artwork is reused without repainting. Resource validation, start behavior, import, Mod management, language, virtual-control editing, AutoPlay isolation and graphics-capability gates remain. Empty-inbox guidance hides once resources are ready; automatic inbox detection remains active.

Mac/iOS arm64 Release builds and localization/project syntax checks pass; the artwork matches its original SHA-256. A local candidate launch completed resource preflight without a captured constraint conflict or crash.

**Unqualified:** The preview-control connection repeatedly failed; no screenshot was captured. Final visual appearance, resizing, light/dark styles, accessibility text sizes and button/menu interaction have not been accepted. Compilation/log checks are not visual or interaction acceptance. This round makes no additional game-rendering/FPS/input claim and adds no iPad/iPhone device test.

Lightweight exports only; no game/Mod assets, XCI, keys, saves or development profiles. Re-sign the unsigned IPA with your own valid identity. Mac is arm64/ad-hoc and not notarized. Back up saves before updating in place.

## 参考 / References

[Apple: Modernize your AppKit app, macOS27 design updates](https://developer.apple.com/videos/play/wwdc2026/289/) · [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
