# build23：启动更新检查、Mac 像素输出与资源预检

2026-11-19；build23 精简预览。[发布与下载](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b23)。

## 中文

### 已实现

- 每次进程冷启动后台读取公开仓库 Releases。包含预览版，按 `v主.次.修订b构建号` 数值比较，忽略草稿、未知标签及没有当前平台已上传 IPA／DMG 的版本。使用发布记录返回的 GitHub 页面，提示后由玩家决定是否打开；不下载安装，不访问私有凭据，不上传设备、资源或存档。
- 同一次进程的重复进入启动页复用结果，并发请求合并。提供手动重查、跨启动 ETag／304 缓存、403／429 等待期限。请求 8 秒、资源 12 秒超时；响应限制 2 MiB。失败时继续游戏。
- 所有 Apple Silicon Mac 开放普通放大的“窗口像素 1:1”与“桌面像素 1:1”。窗口模式跟随当前窗口 backing pixels；桌面模式读取游戏窗口所在屏幕的 backing pixels，再保持 16:9。窗口移动、全屏及显示缩放变化触发布局刷新，尺寸不变时不重复分配 drawable。无法读取显示信息时回落 1080p。
- 这里的 1:1 是最终输出表面像素匹配，**不改变游戏内部 NVN 渲染目标、模型 LOD 或纹理分辨率**。小窗口选择桌面模式仍会由系统缩小显示；要观察桌面像素匹配应使用全屏。Retina 缩放模式可能由窗口系统再次映射到面板，不承诺所有显示设置下都对应液晶物理像素。
- 该选项不自动提高 M1／M2 默认档位，不开放低配 HDR／RT／120，不改变 iPhone／低配 iPad 的 1080p 上限。高分辨率会增加输出处理和显存成本，不保证 M1 保持 60 FPS。
- 启动页资源预检、语言探测及已选 Mod 准备移到后台。App 内不可变的 RendererAssets 首次完整校验后，只在当前进程按资源路径＋翻译链复用成功结果；校验失败不缓存，外部／模拟器可变资源继续每次校验，重启或更新后重新完整检查。完整导入与 Mod 校验规则不变。

### 验证与测量

| 项目 | 结果与边界 |
| --- | --- |
| 更新策略与网络状态 | 自动化假响应覆盖数值版本、预览版、平台安装包、草稿、外部链接、并发、每进程一次、ETag／304、无认证、超时、坏 JSON、过大响应、持久限流等待，通过 |
| GitHub 实际访问 | M3 Max 启动页读到公开发布记录；当前候选 build23 高于公开 build22，显示没有更新版本。新版本提示分支有自动化结果，没有另伪造公开发布 |
| 显示策略 | family 7／8／9 的 Mac 允许桌面／窗口输出；移动端仍拦截桌面输出和超限档位；异常尺寸回落与 16:9 用例通过 |
| Mac 运行 | M3 Max，16 CPU／40 GPU／64 GiB；窗口像素输出 2048×1152，桌面输出 3456×1944，进入／退出全屏、窗口→桌面→1440p MetalFX 往返后仍持续提交画面。使用独立测试存档，无 Mod、AutoPlay 关闭；恢复测试前 1440p MetalFX 和调试信息隐藏设置 |
| 着色器校验 | 并发只完整检查一次，翻译链变化重新检查，失败后可重试，实际完整缓存通过 |
| 编译 | Mac Catalyst arm64 与 iOS arm64 Release 通过，保留现有最低系统目标 |
| 尚未验证 | M1／M2 真机、旧系统、iPad 本次实测、多显示器实际移动、更新弹窗真机外观、整曲冷／暖载入、持续帧时间及功耗 |

实测随 App 提供的着色器预检，单位毫秒：

| 测量 | 样本 |
| --- | --- |
| 第一次完整检查 | 327.254（不是保证清空 OS 文件缓存后的冷启动） |
| 重复完整检查 ×5 | 181.450 / 167.473 / 170.372 / 168.672 / 168.459；中位数 168.672 |
| 成功结果复用 ×5 | 0.00842 / 0.00354 / 0.00317 / 0.00317 / 0.00312；中位数 0.00317 |

只衡量重复着色器预检，**不能推导为歌曲提速比例、稳定 60 FPS 或降低功耗**。游戏资源读取、解压、GPU 上传和着色器准备仍应按歌曲分别测量；本次没有更改这些阶段的运行逻辑。

### 使用

启动页显示更新检查状态；发现新版后可选择稍后或查看 GitHub 发布页。网络不可用时可直接开始游戏，稍后点击状态重试。

Mac 游戏内顶部“输出／画质”选择“桌面像素 1:1（普通放大）”或“窗口像素 1:1（普通放大）”。普通缩放与 MetalFX 仍是不同选项。高分辨率吃紧时可切回 1080p／720p。

本地只导出不含游戏／Mod 资源、XCI、prod.keys、个人存档或开发签名配置的精简包。IPA 未签名；Mac 为 arm64 ad-hoc 签名、未公证。覆盖安装前请备份存档。未重新制作全量包或删除原始 XCI／无关 exFAT 内容。

## English

Build23 is a lightweight preview. [Release and downloads](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b23).

- Cold launches check public Releases asynchronously, including previews. Numeric versions and uploaded platform-specific installers determine availability. The user can open the returned release page; no asset is downloaded or installed automatically. No account token, cookies, device telemetry, resources or saves are sent. Requests are coalesced and cached per process, with manual retry, ETag/304 caching, rate-limit backoff, 8/12-second deadlines and a 2 MiB response bound. Network failure never blocks play.
- Every Apple Silicon Mac may explicitly select window-pixel or desktop-pixel output. AppKit supplies the active window/display backing coordinates; the 16:9 output responds to layout and display changes. **This is final-surface matching using ordinary scaling, not native desktop-resolution 3D rendering.** Internal NVN render targets, LOD and textures are unchanged. A small window still scales down desktop-sized output, and Retina desktop scaling may add another system mapping. Conservative defaults and lower-tier effect/mobile caps remain; higher output has a cost and is not an M1 60-FPS guarantee.
- Launcher resource/language/Mod preflight runs off the main thread. Immutable bundled shader assets receive one complete check per process/path/translation chain; successful results are reused. Failed or external/mutable assets are rechecked. Import and Mod integrity checks are unchanged.
- Update-network simulations, display policies, concurrent shader checks and Mac/iOS Release builds pass. Live M3 Max testing reached GitHub and exercised window/full-screen and window-pixel → desktop-pixel → 1440p MetalFX round trips. Observed surfaces were 2048×1152 and 3456×1944 with continuing frames. The separate test save had no Mods or AutoPlay; earlier display/debug preferences were restored.
- Initial shader preflight measured 327.254 ms. Five repeated complete checks had median 168.672 ms; five success-cache hits had median 0.00317 ms. **This measures one repeated preflight step, not complete-song loading, FPS or energy improvement.** No M1/M2, older-OS, iPad, multi-monitor movement or sustained gameplay/performance acceptance was performed this round. The newer-release alert policy is tested automatically; its device appearance remains unqualified.
- Lightweight exports only. The IPA needs the user's valid signing; the Mac build is arm64/ad-hoc signed and not notarized. Back up saves before updating in place. Game/Mod payloads, XCI, keys, saves and development profiles are excluded.

## 官方资料 / Primary references

公开资源可无认证读取；Releases 列表适合包含预览版的检查：[GitHub Releases API](https://docs.github.com/en/rest/releases/releases#list-releases)。条件请求、等待限流与串行请求依据 [GitHub REST best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)。无认证的 304 不声称免除请求额度。

屏幕／窗口坐标通过 backing 转换取得输出像素，而不是直接把 UI 点当作像素：[Apple NSScreen](https://developer.apple.com/documentation/appkit/nsscreen)、[Apple NSWindow backing conversion](https://developer.apple.com/documentation/appkit/nswindow/converttobacking(_:))。
