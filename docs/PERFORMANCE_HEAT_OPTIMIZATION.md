# 手机发热优化实施记录

日期：2026-11-10。修改前基线为 `497ee7e6bc9c38ce5ebef81f1c6409a5354209b8`，审计依据见 [PERFORMANCE_HEAT_AUDIT.md](PERFORMANCE_HEAT_AUDIT.md)。用户已授权落实所有有代码证据、可保持现有游戏语义的优化。

本页记录第一轮交付。后续音频、纹理、编译预算、调度和生命周期优化见 [第二轮实施记录](PERFORMANCE_OPTIMIZATION_ROUND2.md)，以其中的当前实现和验证边界为准。

## 已实现范围

| 模块 | 当前行为 | 需要保持的契约 |
| --- | --- | --- |
| 性能条内存监测 | 视图拥有可取消任务，RAM 开启且游戏活跃时每秒采样；复用格式化器 | 隐藏、暂停、离开时结束；外观及全局/游戏设置保留 |
| 性能统计 | 普通统计最多 5 Hz，HUD 隐藏、暂停、非活跃时关闭；单独的数据对象只刷新性能条 | 首帧通知始终可达；33 字节包使用非对齐读取；会话代次拒绝主队列旧包 |
| 输入循环 | 输入事件立即唤醒，8 ms 心跳覆盖只能轮询的外设和震动队列 | 心跳不是固定输入延迟；轮询来源的最坏等待需真机评估 |
| 暂停调度 | 暂停时阻塞宿主输入采样和 GPU 工作循环，仍处理控制队列 | 恢复、退出、触摸、键盘、配置和控制消息都必须唤醒；不改变来宾时钟 |
| 退出释放 | GPU 提交结束后依序释放 HLE、GPU 和窗口线程；异常入口也等待 GPU 完成 | 退出中拒绝前后台再暂停；不会把共享渲染器内部循环与宿主线程所有权混为一体 |
| 输入分配 | 缓存原生鼠标包装；触摸一致快照；键盘和姿态使用固定容量值结构 | 不让旧 HID 帧引用后续可变数组；保留触摸释放事件 |
| 手机体感 | 无启用轴、暂停、编辑、非活跃时停采样；主线程更新方向/配置快照 | 有效采样维持 60 Hz；四个界面方向、会话与绑定代次不变 |
| Steam 蓝牙 | 手动配对页搜索；已知设备定向重连，失败退避 | 首次配对入口保留；不持续广扫、不启用重复广告回调 |
| 震动 | 有实际振动才启动引擎/高频发送，暂停与解绑停止 | 持续/定时/零强度振动区分；Steam 保活与 40 ms 振动发送分离 |
| Amiibo | 菜单打开或自动使用开启时才轮询，非活跃取消；相同状态不发布 | 自动提交轮次和重试保持；每局校验 ABI，结构检查仍随状态查询执行 |
| 呈现配置 | 尺寸/刷新率改变才跨 ABI；同值 FPS 不重置节流；保留启动前配置 | Unbounded 呈现语义保持；首个有效尺寸和 FPS 不丢失 |
| Metal 宿主 | 停用仅提供 CAMetalLayer 的 MTKView 自身定时刷新 | Vulkan 仍负责实际呈现，需要真机验证首帧、旋转及外接屏 |
| MetalFX | 输出精确覆盖整张 drawable 且 usage 合法时直接写入 | 2x/3x 倍率、黑边、二次缩放及跨 API fence 保留；不满足条件走原路径 |

`set_statistics_enabled(int32_t enabled)` 是本次新增核心导出，默认关闭普通统计。Swift 和 NativeAOT 核心必须一起重编；构建脚本检查 C 头、导出和实际 IPA 中核心，拒绝混入缺接口的旧 dylib。

应用级 `push_statistics` 回调仅注册一次，避免每局替换时积累保留的回调对象。没有修改通用 CallbackManager 的跨线程释放协议，以免在途 native 回调访问已经释放的对象。

暂停期间仍接收 SDL 的宿主控制任务，目前该应用级事件线程约每 10 ms 投递一次；本次停止无效 HID/GPU 处理，不声称暂停后完全没有线程唤醒。

## 测试与构建

新增回归直接链接生产模块：统计包解析/会话隔离/Amiibo需求、输入资源策略、Metal 输出资格和配置去重、呈现节拍、宿主等待/恢复/退出及输入快照。固定 SDK 为 .NET 10.0.100；Swift 测试纳入 `scripts/build-ios-unsigned.sh` 并采用生产的 MainActor 默认隔离。

本次 Windows 验证结果：

| 检查 | 结果与范围 |
| --- | --- |
| `HostLoop.Tests` | 81 项通过；含暂停/控制唤醒/恢复/退出、启动尺寸、真实 ThreadedRenderer 8 轮释放；触摸采样与转换 10,000 次的当前线程分配为 0 字节 |
| `PresentationPacing.Tests` | 118 项通过；同值更新、呈现间隔、模式/目标改变和时钟边界 |
| `MotionInput.Tests` / `NativeMotion.Tests` | 通过；姿态快照 20,000 次当前线程分配为 0 字节；非法采样的两条错误日志是预期拒绝测试 |
| `AmiiboContract.Tests` / `HleAmiibo.Tests` | 10 项 / 15 项通过 |
| `python scripts/test_verify_ipa.py` | 20 项通过；含缺少统计门控导出的拒绝用例 |
| `python scripts/check_localization.py` | 516 个键、408 个中文条目，占位符保持 |
| `bash -n scripts/build-ios-unsigned.sh` / `git diff --check` | 通过 |
| `Ryujinx.Library` 托管全依赖编译 | `win-x64`、Release、固定 SDK；0 错误，存在平台及原有编译告警；不是 iOS NativeAOT 构建 |

托管编译命令为 `dotnet build src/Ryujinx.Library/Ryujinx.Library.csproj -c Release -p:RuntimeIdentifiers=win-x64 -p:RuntimeIdentifier=win-x64 -p:PublishAot=false -p:UseNativeAOTRuntime=false -p:HybridGlobalization=false`，只用于 Windows 静态契约/依赖编译检查；正式 iOS 构建参数未放宽。核心验证日志保存在本地 `_杂项/验证日志/热优化核心-20261110/`。

Swift/Apple 框架、iOS NativeAOT、Metal 与真机功耗必须由 Codemagic/Xcode 和设备验证；本机没有执行新增 Swift 测试，也没有生成或验证本次实际 IPA。上述合成包门禁和纯状态测试不能替代这些检查，热路径的零分配结果也不代表整个模拟器零分配。

## 保留参数及实测边界

未修改来宾同步时钟、Custom VSync/SwapInterval、精准等待自旋预算、默认着色器缓存及预载线程数，也未强制降低分辨率、关闭特效或改变 MetalFX 倍率。审计 B 类中的这些候选需要真机 CPU/GPU 记录证明瓶颈，直接修改可能影响速度、帧时间或画质。

当前没有该 iPhone 的优化前后功耗、温度、FPS 或帧时间测量，不能承诺提升百分比或降温度数。有线充电产生的热量也不能由这些代码修改消除。

验收使用《旷野之息》同一存档和路线、720p、30 FPS、相同亮度与环境；充电和不充电分别做同条件版本对比。检查首帧、HUD/RAM 开关、四方向体感、滑动视角与按键多点触控、输入编辑返回、暂停一分钟恢复、暂停中退出、连续重开、Steam 首次配对/断连重连/震动，以及 MetalFX 与外接屏。记录线程唤醒/分配、帧时间和 thermalState，再决定是否调整上述时序候选。

## 备份与回退

修改前文件已分别保存在项目 `备份/热优化主线-20261110-222720/` 和各子任务的集中备份目录。正式版本通过 Git 提交保持源码、测试、构建门禁与文档一致。若新 IPA 出现回归，回退整次优化提交并重新构建，不能单独替换旧核心绕过 ABI 校验。
