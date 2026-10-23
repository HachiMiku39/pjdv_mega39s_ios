# iPad 文件导入回归

只在独立测试 App／设备容器操作；不要用合成密钥覆盖已有游戏 App 的真实导入密钥。

1. 运行 `Tests/ImportVariants/build_fixtures.py` 生成测试夹具。它们不含真实游戏或生产密钥。
2. 使用独立 bundle ID 构建 iPad 测试 App；将生成的 `fixture.keys`、`base-only.xci`，以及两个无效内容的 `.keys`／`.xci` 小文件放入该测试 App 的 Documents。
3. 资源管理 → 选择密钥：文件应可点选，选择器关闭；无效密钥显示具体错误，不应覆盖旧密钥。
4. 导入 XCI：缺少密钥时显示错误；关闭系统窗口后应能再次打开选择器。取消应显示未开始导入，按钮恢复可用。
5. 在独立容器选择合成 `fixture.keys`，再选择 `base-only.xci`。应生成 `GameResources/game-content.json` 和 `romfs/complete.json`，Title ID 为 `0100F3100DA46000`，语言仅日语，无 DLC。源 XCI 仍在原位，SHA-256 与夹具一致。
6. 再次打开选择器并取消，确认旧资源清单未变。分别检查本机文件、外置盘与第三方 Files 提供方；不能以一个提供方通过代替全部覆盖。

2026-10-23 实测：iPadOS 27.2／iPad (A16) 模拟器，上述本机文件选择、无效密钥、缺失密钥、合成完整导入、取消路径通过；不是游戏运行测试。iPad Pro 2021 M1／iPadOS 18 和其他 Files 提供方仍待回测。真实 40+ GB XCI 本轮未重复导入。
