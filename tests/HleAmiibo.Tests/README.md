# HLE 虚拟 amiibo 回归验证

本工程引用实际 `Ryujinx.HLE` 项目，通过反射建立不启动整机模拟的最小 `Horizon` 状态，直接测试生产程序集。测试不复制核心实现。

运行命令：

```powershell
dotnet run --project tests/HleAmiibo.Tests/HleAmiibo.Tests.csproj
```

工程保留已通过的 15 项检查：检测状态、坏 ID、过期轮次、事件未就绪、失败后状态、32 路并发提交、发布 ID、UUID 的 BCC、关闭后拒绝、跨会话提交与 UUID 持久化、坏 JSON 错误与原文件保留、100 轮 worker 替换/停止、关闭状态。

测试为内核事件使用未初始化占位对象，因此不触发真实 `KEvent.Signal`，也不启动 Switch 内核或游戏。此结果不能替代 iPhone 上的激活事件、游戏奖励、BOTW 狼林克效果或 IPA 安装验证。持久化测试数据使用独立临时目录，运行结束时会输出路径。
