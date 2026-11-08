# iOS 构建与交付

本项目在 MeloNX 2.7 上增加离线虚拟 Amiibo。交付必须重新编译 C# NativeAOT 核心与 Swift 前端，不能只替换菜单或沿用官方旧核心。本文件描述当前构建入口；首次 macOS 构建和手机实测完成前，不应宣称 IPA 已可运行。

## 固定工具链与输入

| 项目 | 当前约束 |
|---|---|
| 构建机 | Apple Silicon macOS；Xcode 26.2 |
| .NET SDK | 10.0.100，按 Microsoft 发布元数据中的 SHA-512 校验下载 |
| 核心 | `src/Ryujinx.Library/Ryujinx.Library.csproj`；`net10.0`、`ios-arm64`、NativeAOT |
| NuGet | `Directory.Packages.props` 中的固定版本；来源见 `nuget.config` |
| Swift 包 | 已提交的 `Package.resolved`；只允许使用锁定版本，不自动升级 |
| 原生依赖 | `src/MeloNX/MeloNX/Dependencies` 中已提交的 framework/xcframework/dylib |
| iOS 工程 | `src/MeloNX/MeloNX.xcodeproj`，scheme 为 `MeloNX` |

`scripts/bootstrap-dotnet.sh` 把 SDK 安装到 `build/tools/dotnet-10.0.100`，不修改系统 SDK，不读取账号或签名凭据。SDK 下载地址及 SHA-512 固定在脚本中，来源为 [Microsoft 10.0 发布元数据](https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json)。

NativeAOT 库沿上游使用 `net10.0` 和 `ios-arm64` 发布，不额外把项目改成 `net10.0-ios` 应用，也不以忽略 Xcode 版本检查或自动更新 workload 掩盖依赖问题。首次还原若报告缺失 workload、外部包源不可访问或原生链接失败，构建即停止并保留原始日志，应据日志修正固定构建输入。

`Ryujinx.LibHac 0.21.0-alpha.129` 依赖 `https://git.ryujinx.app/api/packages/projects/nuget/index.json`。原配置中的迁移后 `Ryulynx` 源没有此包，已修正为仍提供同版包的原 `projects` 源；已确认同版 nupkg 可下载，没有降低依赖版本。完整 NativeAOT 还原与链接仍需以云端日志确认。预编译第三方输入能够按文件摘要锁定，但本阶段不宣称已从其各自源码重建全部依赖。

## Codemagic

1. 将本仓库连接到自己的 Codemagic 账户，选择仓库根目录的 `codemagic.yaml`。
2. 运行 `ios-unsigned` 工作流。该工作流使用 `mac_mini_m2` 和 Xcode 26.2，不要求 Apple 签名材料。
3. 下载 `build/artifacts` 中的 `MeloNXAmiibo.ipa`、`SHA256SUMS`、`ipa-verification.json`、`build-inputs.json`，并保存 `build/logs`。
4. 只有工作流全部通过后，才将该次 IPA 标记为“编译及包校验通过”。手机启动、扫描与游戏奖励仍需要单独实测。

`push` 触发依赖 Codemagic 与仓库连接及 webhook 已启用；提交配置文件本身不代表已连接、已触发或已消耗云端构建额度。本工作流不自动上传 App Store、TestFlight 或向其他人发送消息。

## 本地 macOS

```bash
bash scripts/build-ios-unsigned.sh
```

可以使用 `DEVELOPER_DIR` 选择本机 Xcode 26.2，例如：

```bash
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer bash scripts/build-ios-unsigned.sh
```

GitHub Actions 的手动工作流执行同一入口；如果托管镜像不包含固定 Xcode 26.2，会明确失败，不回退到不同版本。其 artifacts 默认保留 14 天。

## 构建步骤与失败边界

构建入口依次执行：

1. 执行 IPA 校验器测试，校验 Apple Silicon、Xcode 26.2、固定 .NET 10.0.100；记录工具版本。使用 Xcode 的 `swiftc` 将应用同一份 TXT parser 与 `tests/AmiiboCatalogParserTests.swift` 编译为 macOS 控制台测试；运行纯 `net10.0` 的 `AmiiboContract.Tests`、`HleAmiibo.Tests`。这些测试不使用 `ios-arm64` 运行时，不在构建机执行 iOS 产物；随后 NativeAOT 发布会为 `ios-arm64` 单独还原构建。
2. 为 SDK、NuGet/Swift 配置及原生依赖生成输入 SHA-256 清单。Swift 包仅按 `Package.resolved` 解析，解析后锁文件内容必须保持一致。
3. 将已有 `ios-arm64` 发布目录整体移到 `build/backups/<UTC时间>/`，执行 `dotnet publish`，要求新核心生成于本次发布开始之后。发布失败不恢复旧核心继续打包。
4. 检查本次生成的核心是 arm64 iOS dylib，并用 `nm -gU` 验证 `mlx_amiibo_get_abi`、`mlx_amiibo_get_state`、`mlx_amiibo_scan` 三个导出。
5. Xcode 真机 Release 构建，禁止签名，保留 `MeloNXRamDonor.appex`。上游 `Ryujinx` Legacy 依赖仍执行 `distribution/ios/build.sh`，CI 通过 `MLX_FIXED_DOTNET`、`MLX_PREBUILT_CORE_SHA256` 传入本次固定 SDK 与刚生成核心的 SHA-256；依赖目标必须校验当前核心完全一致才跳过重复发布，文件或摘要错误立即失败。普通本地 Xcode 构建没有此标记时仍正常发布核心，并强制 SDK 10.0.100；该入口不读取个人 shell 配置。
6. 在独立打包目录复制应用、加入本次 NativeAOT 发布所需的 ICU 数据。只在打包副本去除上游代码签名，第三方原始文件保持不变。
7. 比较包内核心与本次重编核心的规范化摘要，校验 Mach-O 真机平台、应用/扩展身份、动态库依赖闭合、三个导出及无签名状态。
8. 验证全部通过后移动正式 IPA 到 artifacts，生成 IPA SHA-256。

任何步骤失败都会以非零退出码终止；日志用于定位首次环境或源码问题，不能把缺失的核心、扩展、依赖或符号标记为“已验证”。

## 安装与真机验证

IPA 是未签名 arm64 真机包，包含主应用、NativeAOT 核心和内存扩展。安装应使用现有 MeloNX 所需的侧载、签名和 JIT 流程。LiveContainer 是否保留并支持内存扩展、JIT 和权限取决于其实际版本；本阶段未验证，不能仅因 IPA 可导入就宣称能运行模拟器。

正式安装前应备份手机现有 MeloNX 的存档、配置及虚拟标签数据。继续使用 `com.stossy11.MeloNX` 与 `com.stossy11.MeloNX.RamDonor` 标识，避免因无意改 Bundle ID 导致原数据不可见；实际侧载工具可能附加开发者后缀，需要单独确认。

最小真机验收为：冷启动、正常进入《荒野之息》、保持游戏运行并启用游戏内 Amiibo 功能、导入当前游戏目录的 TXT 并通过屏幕齿轮菜单选择其中的身份、确认游戏实际响应；还需检查重复扫描、取消、游戏停止/重启以及恢复原版。默认没有内置角色。包结构校验不代替这些结果。

## 当前验证范围

Windows 已通过 Python/YAML/Bash 语法校验；`python scripts/test_verify_ipa.py` 的 10 个测试通过，覆盖合法包、旧核心、缺少扩展、依赖未嵌入、模拟器平台、残留签名、路径穿越、损坏 Mach-O 和导出表边界。构建入口自动执行同一组测试。原生 Mach-O 解析也已用于检查仓库中的 MoltenVK、FFmpeg、SDL3 真机输入。以上未运行应用代码，不能代替 Xcode 或真机结果。本阶段构建配置和交付门禁已提供；云端 NativeAOT 还原/编译、Xcode 构建、侧载以及 Amiibo 实机效果均需以对应日志和设备结果补充。

本项目保留上游 GPLv3 许可证及第三方许可说明；分发修改版时应一并提供对应源码、修改说明和许可证。构建过程不包含游戏、固件、密钥或签名材料。

## 首次 Codemagic 日志修复（2026-11-08）

用户提供的日志已进入 Xcode 26.2 的 Swift 前端编译，随后以 `status code 65` 结束。本次按日志修复以下问题：

- 设置页和引导按钮直接使用已有 `LocalizedStringKey`，移除重复转换；拆分设置页分类栏与设备信息表达式，降低类型推断复杂度。分类枚举、配置读写与点击动作保留原值。
- `EmulationView` 提供明确的 `init(game:)`，移除未使用的私有 `air` 字段，避免合成初始化器被设为私有。
- 移除固定 Xcode 26.2 SDK 中不存在的 iOS 27 场景附件 API；继续使用 `Info.plist` 已有的两种外接显示场景注册和 `ExternalDisplaySceneDelegate` / `Air.play`。这并不证明 iOS 27 的外接显示行为已验证。
- 后台 JIT 轮询通过 `await jitEnabled()` 等待主 actor 检测，修正日志中的隔离调用警告。

Windows 已完成源码差异审查、字符串资源参数检查及外接显示场景配置检查，没有 Apple SDK，不能在此重新编译 SwiftUI。本轮修复仍需在 Codemagic 的 `main` / `ios-unsigned` 上重跑；只有实际构建及 IPA 校验全部通过后才能下载交付包。原始日志只有失败片段，不能据此宣称 NativeAOT、最终打包或真机使用均已通过。

