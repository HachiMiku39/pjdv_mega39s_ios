# PJDV M39 · Switch → iOS 移植研究

`pjdv_mega39s_ios` 记录《初音未来 Project DIVA MEGA39’s》Switch 版运行于 iPhone / iPad 的兼容层研究。App 名称为 **PJDV M39**。

目前已经能在 iPad 模拟器中进入原游戏标题、菜单和实时 3D 节奏游戏场景。**角色材质、眼睛颜色和光照仍存在异常，完整游戏音频、触控体验和稳定真实 60 FPS 尚未验收。**

本仓库当前仅发布研究介绍和进展 README；游戏文件、密钥、提取资源、商业游戏可执行文件、着色器缓存与安装包均不包含在仓库中。

## 目标

- 支持 iPhone 和 iPad，横屏显示，按原始 16:9 比例适配。
- 还原 Switch 版实际的角色材质、舞台光照、反射和后处理。
- 保留原作谱面、歌曲时间轴、判定、HOLD、SLIDE 与计分行为。
- 支持原作触屏输入、可开关的虚拟手柄，以及 DualSense / Xbox 实体手柄；连接实体手柄后隐藏虚拟手柄。
- 以真实 60 FPS 和 1920×1080 输出为性能目标；正确渲染之后再评估 MetalFX。
- 先完成模拟器功能验证，再测试真机。

## 技术路线

CPU 采用原游戏 ARM64 程序适配路线，配合执行文件重写、模块载入和 Horizon 系统接口兼容。图形侧将实际 NVN 调用映射到 Metal，原始 Maxwell 着色器经 Ryujinx 翻译链转换为 SPIR-V / MSL。

Switch 与 Apple 设备都使用 ARM64，并不使二进制直接兼容；内存布局、系统服务、线程、输入、音频、图形与着色器语义仍需逐项实现和验证。

```text
Switch 游戏程序与资源
  ├─ ARM64 重写 / 模块载入 → Horizon 服务兼容 → 游戏逻辑
  ├─ NVN 命令 / 资源 / 状态 → Metal 后端
  ├─ Maxwell Shader → Ryujinx → SPIR-V → MSL
  ├─ AVC 视频 → VideoToolbox
  └─ 输入 / 音频 / 文件系统 → iOS 宿主接口
```

研究基线为 JP 版 v1.0.9（更新版本 589824），基础 Title ID `0100F3100DA46000`，包含 27 个 DLC。当前模拟器使用 Metal 3 路径；工程另有 Metal 4 真机路径，尚待真机验证。

## 当前验证状态

截至 **2026-10-14**。表中的“验证”仅适用于所述范围。

| 模块 | 已完成或已观察到 | 尚待验证 / 修复 |
| --- | --- | --- |
| 游戏资源 | 基础与更新 ExeFS、合并 RomFS、27 个 DLC 的提取及完整性检查 | 最终资源导入、分卷接入与发布流程 |
| ARM64 运行 | 6 个模块的重写站点检查；4 个有效模块初始化并进入 `nnMain` | 全流程系统服务与程序行为正确性 |
| 图形运行 | 808 个游戏着色器已转换；标题、菜单、教程和歌曲实时 3D 可显示 | 材质、眼睛、光照、高光和反射一致性 |
| 视频 | 修复 YUV / NV12 布局边界；片头视频颜色已经用户确认 | 更多视频与切换场景回归 |
| 输入 | 虚拟按键、键盘、GameController 和多点触控桥已接入；部分输入契约测试通过 | 直接触控的坐标、事件和原游戏操作流程；真实 PS5 / Xbox 手柄 |
| 音频 | AudioOut 的 PCM / CoreAudio 路径已接入 | 游戏使用的 AudioRenderer DSP 混音与完成状态；当前模拟器为明确标识的静音诊断 |
| 输出分辨率 | 游戏内部 1280×720，最终 1920×1080 双线性放大 | 原生 1080p 与 MetalFX 超分 |
| 帧率监测 | FPS、进程 CPU、RAM 浮窗与帧时间日志 | GPU 完成回调计数不等同于稳定真实 60 FPS；实际呈现、重复帧和持续运行需单独测量 |
| 解锁 | 包内 DLC 已识别和提取 | DLC 运行加载、歌曲 / 服装 / 道具初始全可用及存档验证 |
| 真机 | 工程有未签名设备目标构建记录 | 实机安装、输入、音频、画质、性能和发热 |

主要功能测试环境是 **iPad Pro 13-inch (M5) / iPadOS 27.2 模拟器**；模拟器设备名称不构成 M5 真机性能证据。独立 GPU 检查运行于 Mac 的 Apple M3 Max，也单独标记为 macOS 测试。

## 已确认的渲染缺口：过滤拷贝未生成 mip

NVN 后端原先直接跳过不同尺寸的 Texture → Texture 拷贝。《愛言葉》的实际帧中，512×512 阴影纹理需要线性缩放写入 256×256、128×128 和 64×64 的 mip；旧实现使被采样的 mip 1 保持全黑。

已为实际观察到的 **Metal 3 / 2D / RGBA8_UNORM / 线性过滤**形态补充渲染式缩放，并限制读取与写入的 mip 视图，保留原始颜色与 alpha 语义。

验证结果：

- 修改后的模拟器 App 编译通过并进入实际歌曲场景。
- 第 19398 帧的 mip 0 → mip 1 / 2 / 3 拷贝均有执行记录。
- GPU 回读的 mip 1 不再全黑；与同帧 mip 0 的独立 CPU 双线性参考相比，RGB 最大误差 **0.5/255**、平均误差约 **0.0052/255**。
- 6 项独立 macOS GPU 检查通过，覆盖采样格式、sRGB、BGRA 顺序、双线性缩放和透明合成。

这证明了局部 mip 缺口的修复，**没有证明整体材质、颜色和光照已经正确**。该修复目前覆盖 Metal 3 的已观察形态，其他格式、拷贝形态和 Metal 4 仍需单独处理。

## 材质与光照的排查方向

当前执行的是翻译后的原版游戏着色器。已观察到浮点 3D 中间目标、曝光、色调映射、FXAA 和 UI 合成过程；“画面简单”不能直接推出这些功能完全缺失。

下一步对照原游戏绑定和社区研究，逐项核对：

1. CLOTH / HAIR / SKIN / EYEBALL 等材质变体与实际 shader 的对应关系。
2. Diffuse、Normal、Specular、Environment Cube 的格式、纹理视图、mip、采样器与绑定槽。
3. 法线 / 切线变换、灯光常量、各向异性高光与眼睛采样。
4. cubemap 六面、浮点 HDR 中间值、运算顺序和 Tone Mapping。
5. 同歌曲、同服装、同镜头的对照与回归。

旧的 CPU 纹理转储为零，不能作为资源上传一致性的证据。已加入提交完成后的 GPU 池回读、cubemap 六面和原始浮点导出诊断；最新诊断构建已通过，新增诊断结果尚待运行验证。

修复以 Switch 版实际效果为基线，不通过全局饱和度、曝光或反光滤镜掩盖问题，也不直接套用 Future Tone 的渲染参数。

## 参考资料与致谢

- [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)：原生兼容层与 NVN → Metal 的主要工程参考。D2R 专用地址、钩子与 shader 参数不能直接用于 MEGA39’s。
- [jiayx/d2r-mobile-build](https://github.com/jiayx/d2r-mobile-build)：构建流程参考。
- [korenkonder/AFTMods · DivaGL](https://github.com/korenkonder/AFTMods)：DIVA 图形迁移研究。[v0.11.0.0](https://github.com/korenkonder/AFTMods/releases/tag/DivaGL-v0.11.0.0) 记录了 BLINN 高光修复，[v0.10.0.1](https://github.com/korenkonder/AFTMods/releases/tag/DivaGL-v0.10.0.1) 记录了 Tone Map / NPR 修复。这些是排查线索，尚未证明与本项目是同一根因。
- [korenkonder/ReDIVA](https://github.com/korenkonder/ReDIVA)：系列数据结构和渲染实现研究参考，具体与 Switch 版的对应关系待核对。
- [korenkonder/PD_Tool](https://github.com/korenkonder/PD_Tool)：多版本资源结构参考。各转换器的版本范围不同，不能将所有灯光 / 颜色工具都视为已支持 M39。
- [DivaDocs · Shaders](https://docs.divamodarchive.com/Shaders)：社区对角色 / 舞台材质与纹理语义的记录，需结合本作实际数据验证。
- [SEGA 官方技术文章：DIVA Arcade、演唱会与 Virtua Fighter 5](https://info.miku.sega.jp/565)：早期引擎与渲染技术背景，不直接证明 Switch 版沿用完全相同的实现。

感谢上述项目作者和文档贡献者。参考资料所述能力与本项目已经验证的能力分别记录；复用代码时须保留对应许可证与署名要求。

## 近期顺序

**触控链路与正确渲染 → 模拟器完整歌曲回归 → 实际帧时间与真实 60 FPS → 1080p / MetalFX → 真机测试。**

触控测试优先直接操作游戏画面，核对横屏和 16:9 视口换算、触点 ID、时间戳、多指及按下 / 移动 / 释放，不以模拟手柄导航替代触控验证。

每项进展分别记录：**代码已修改、编译已通过、实际渲染已验证**。
