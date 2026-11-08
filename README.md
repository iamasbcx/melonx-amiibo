# MeloNX 虚拟 Amiibo iPhone 定制版

这个仓库基于 MeloNX 2.7，给 iPhone 版增加游戏内虚拟 amiibo 选择功能。默认不内置角色数据，安装包不包含 amiibo 数据库、`.bin`、`.nfc` 或密钥。

## 使用数据目录

数据放在 MeloNX 的 Documents 目录，按当前游戏 Title ID 分开：

```text
MeloNX/
└─ Amiibo/
   └─ 01007EF00011E000/
      └─ amiibo.txt
```

《荒野之息》的 Title ID 是 `01007EF00011E000`。其他游戏使用它自己的 Title ID，不能把一个游戏的目录文件当作另一个游戏的目录。

TXT 格式：

```text
MELONX_AMIIBO_CATALOG 1

[林克（弓）]
0100000003530902

[米德娜与狼林克]
01030000024F0902
```

允许 UTF-8、BOM、CRLF 和 `#` 注释。名称后必须紧跟一个 16 位 ASCII 十六进制 amiibo ID。单个目录限制 1 MiB、4096 项；重复 ID、缺少 ID、非法名称或错误格式会报告行号，并保留原文件。

## 游戏内操作

运行游戏后点击屏幕齿轮，打开“虚拟 amiibo”。菜单按当前游戏 Title ID 读取 `Documents/Amiibo/<TitleID>/amiibo.txt`，支持刷新目录、导入 TXT 和添加自定义身份。把新 TXT 通过 USB 或 iOS 文件共享拷入对应目录后点“刷新目录”，不用重新编译或重装。

先在游戏内开启 amiibo 能力并进入等待读取状态，再选择角色并点“使用”。程序不会自动暂停游戏，也不需要 NFC 或实体卡。提交成功只表示虚拟身份交给了 NFP 核心，实际奖励由游戏决定。

## 边界

自定义输入的是身份 ID，不是金手指或任意游戏存档。普通身份注入与游戏奖励需要逐游戏实测；应用区存档、狼林克心数、成长数据等不能从 ID 推算，当前不承诺完整效果。

需要 JIT、内存权限和正常 MeloNX 运行环境。当前 Windows 已通过固定 .NET 10.0.100 的 managed build、虚拟 amiibo HLE 15 项并发/生命周期检查和 ABI 布局检查；Codemagic 的 Xcode/NativeAOT/IPA 门禁尚未在本机执行，IPA 和游戏实机效果不能提前宣称通过。


## Codemagic 编译

连接私有仓库 `iamasbcx/melonx-amiibo`，选择 `main` 分支和 `ios-unsigned` 工作流，点击 **Start new build**。成功后在 Artifacts 下载 `MeloNXAmiibo.ipa`。该包未签名，使用原有 MeloNX 侧载与 JIT 流程安装；首次安装前备份现有存档和配置。

构建依赖为 Apple Silicon macOS、Xcode 26.2 和固定 .NET SDK 10.0.100。完整说明见 [docs/BUILD.md](docs/BUILD.md)，目录契约见 [docs/VIRTUAL_AMIIBO.md](docs/VIRTUAL_AMIIBO.md)，汉化范围见 [docs/LOCALIZATION.md](docs/LOCALIZATION.md)。

源码基线为官方 [MeloNX 2.7](https://starforgejo.dev/projects/MeloNX/releases/tag/2.7)，上游提交 `13700519f3abc4e6d7ed8a065b118b2cc59bcd67`；保留 GPLv3 与第三方许可。原始项目说明保存在 [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md)。
