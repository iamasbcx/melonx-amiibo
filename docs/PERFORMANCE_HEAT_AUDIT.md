# MeloNX 手机发热与性能审计

日期：2026-11-10。代码基线：`497ee7e6bc9c38ce5ebef81f1c6409a5354209b8`。

用户场景：iPhone 18 Pro，MeloNX 运行《塞尔达传说：旷野之息》，用户报告 30 FPS、720p、有线充电。

本次只审计代码，没有修改运行逻辑。未采集该手机的 Instruments、GPU trace、温度或功耗数据；“确定”表示代码路径可以确认，不表示已测得其占用或降温幅度。实际帧率 30 FPS 不足以判断是否启用了正常同步、无上限模式或帧率补丁；下文的条件性建议不能视为当前设备配置。

后续实施记录见 [PERFORMANCE_HEAT_OPTIMIZATION.md](PERFORMANCE_HEAT_OPTIMIZATION.md)。本文保留优化前基线的证据与行号，不作为修改后源码行号或真机测量结果。

## 结论与实施顺序

有多处不需要先降低画质就能处理的额外开销。优先修资源生命周期、性能统计刷新、无设备蓝牙扫描，以及无需运动输入时的采样；输入和渲染线程的调度优化收益值得测量，但必须保留唤醒与退出协议，不能简单增加 sleep 或无限等待。

| 顺序 | 工作 | 预期改善方向 | 实现风险 |
| --- | --- | --- | --- |
| 1 | 修复性能条内存监测任务生命周期，按显示需要采样 | 防止反复进出/旋转后累积任务和定时唤醒 | 低 |
| 1 | 统计显示改为 2～5 Hz，关闭 HUD 停普通统计；分离首次启动通知 | 减少跨语言调用、主线程任务和 SwiftUI 失效 | 低至中 |
| 1 | 无 Steam 手柄需求时停止持续广泛蓝牙发现 | 减少前台射频扫描与重复广告回调 | 中：需保留配对和重连 |
| 1 | 暂停、非活跃、全部手机运动轴禁用时停采样；配置用快照 | 减少无效 CoreMotion 和主线程同步 | 中：需验证恢复和方向连续性 |
| 2 | 调整输入 1ms 轮询及暂停宿主线程；去掉循环内重复分配 | 减少 CPU 唤醒和 GC 压力 | 中至高：事件、队列与 HID 节奏相关 |
| 2 | 修复重复刷新率设置重置无上限呈现节流 | 保持原有节流有效 | 低，但仅 Unbounded 生效 |
| 3 | 收敛 Amiibo、震动、Steam 保活等低频任务 | 减少空闲常驻工作 | 中：各自协议需回归 |

当前不能量化以上项目各自占整机热量的比例。720p/30 FPS 下，模拟来宾 CPU、GPU 仍可能是主要负载；充电产生的额外热量不由模拟器优化直接消除。

## A. 可以从代码确认的优化点

### A1. 性能条内存监测存在强引用循环

证据：`src/MeloNX/MeloNX/UI/Emulation/PerformanceDisplay/PerformanceOverlay.swift:18` 保存 `Task`，任务强捕获对象并进入 `monitorMemoryUsage()`；`:28` 无限循环，每 200ms 采样；取消只在 `:23` 的 `deinit` 中。对象持有任务，任务又持有对象，不能依赖 `deinit` 来结束循环。

`PerformanceOverlayView:64` 为每个视图实例创建监测器；显示分支在 `MetalViewContainer.swift:49/64` 随总开关和横竖屏位置改变。退出视图没有显式停止监测，反复重建具备累积监测器的条件。关闭 RAM 显示也只隐藏文本（`PerformanceOverlay.swift:76`），没有停止采样。

建议：让采样任务由视图生命周期拥有，或显式 start/stop，避免对象跨无限异步循环强持有自身；仅 HUD 可见且需要 RAM 时采样，普通显示可用 1～2 Hz。缓存 `ByteCountFormatter`，显示数值未变化时不发布。需要用实例计数、deinit 记录和 Allocations 验证泄漏消失，不能只看界面关闭。

### A2. 普通统计目标刷新率过高，HUD 关闭仍刷新父视图

证据：`src/Ryujinx.Library/Window/WindowBase.cs:40/115` 将统计周期设为 60 Hz；`:245/255` 按累计时间调用 `SendStatistics`，`:408` 编码后跨边界调用 `push_statistics`。实际频率受渲染循环节奏限制，不能当成已实测的固定 60 次/秒。

`src/MeloNX/MeloNX/Common/StatisticsHandler.swift:34` 每次创建主线程任务，`:36` 起连续写入四个 `@Published` 属性。`EmulationView.swift:22` 和 `MetalViewContainer.swift:17` 都订阅整个对象，关闭 HUD 也不取消普通统计。SwiftUI 可能合并更新，因此不能宣称每次上报必然完整重绘四次；能确认的是多次发布和较大视图范围的失效。

建议：普通统计降为 2～5 Hz，结构体快照合并发布，只有内容变化才刷新；让 HUD 订阅频繁变化的数据，父页面仅关心启动状态。HUD 隐藏时停普通统计，但必须保留 `WindowBase.cs:240` 的首帧通知，防止加载界面无法关闭。字体变小、胶囊背景本身不是主要节能手段。

### A3. 输入循环空闲时仍用 1ms 超时等待

证据：`src/Ryujinx.Library/Window/WindowBase.cs:315` 的 `MainLoop()` 每轮执行 `UpdateFrame()`、控制队列，再在 `:323` 调用 `_inputUpdatedEvent.WaitOne(1)`。每轮处理 Npad、触屏、DebugPad、鼠标。无事件时仍反复超时；实际频率取决于执行耗时和系统调度，不能等同于测得 1000 Hz。

循环内还有可避免分配：`src/Ryujinx.Input/HLE/NpadController.cs:461` 创建姿态 `float[9]`；`src/Ryujinx.Library/Native/NativeTouchDriver.cs:139` 每次 `GetGamepad()` 新建 `NativeMouse`，触摸坐标路径还有数组和 LINQ 投影。

建议：先取消暂停期间无效工作和缓存设备包装对象，再用输入事件与受控采样节拍共同驱动；对输入延迟和组合按键做回归。复用姿态/触摸缓冲区前要核对下游是否保留引用，跨线程触摸字典必须有一致快照。

禁止直接改为无限等待：`NativeTouchDriver.cs:38/46/55` 的触摸更新没有发出当前输入事件；`WindowBase.QueueMainThreadAction:44` 也仅入队，而 `Library.cs:170` 的 SDL 调用方可能同步等待执行。必须补齐触摸、键盘、配置、控制队列、恢复与退出唤醒，或保留必要期限。

### A4. 暂停没有阻塞全部宿主循环

证据：`src/Ryujinx.Library/Library.cs:230` 将暂停传给 `Horizon.TogglePauseEmulation`（`src/Ryujinx.HLE/HOS/Horizon.cs:825`），暂停来宾应用、音频和时间源。窗口 `_pauseEvent` 在 `WindowBase.cs:120` 初始化为已置位，`:222` 等待，`:296` 退出时置位，未找到使其进入等待状态的 `Reset`。

因此输入循环仍运行；GPU 无命令时还会经过 `src/Ryujinx.Graphics.Gpu/Engine/GPFifo/GPFifoDevice.cs:195` 的 8ms 超时等待。属于持续唤醒，不是已证明的满核忙自旋。iOS 真正挂起进程后是否调度由系统决定，不能据此声称后台整夜运行。

建议：暂停/非活跃时统一管理宿主循环，恢复和退出明确唤醒；控制消息不能被一起堵死。验证暂停后 CPU 回落、恢复无卡死、退出无等待死锁，以及触摸/体感无旧帧跳变。

### A5. 手机运动采样未按需要停止，每帧重复访问主线程配置

证据：`BaseController+Motion.swift:57` 的手机分支仅检查 CoreMotion 可用，`:61` 以 60 Hz 采样。六项方向全部关闭也不停止传感器。已有 `motionEnabled` 检查位于有自身 motion 的实体设备分支，不能当作手机采样总开关。

编辑设置时输入屏障只让回调丢帧，没有停止传感器。手动暂停/前后台流程也没有统一停止采样。已解绑时会推进令牌并停传感器，这部分上轮已处理，不应重复报告为退出后必然仍采样。

每个有效采样还在 `BaseController+Motion.swift:142` 同步进入主线程读取方向及配置，`:174` 枚举场景；`NativeSettingsManager.swift:134` 读取六轴 12 个设置。按 60 Hz 目标计算，每个手机采样实例可能产生约 60 次主线程同步、720 次设置值访问/秒；这是代码推算，不是实测耗时。

建议：没有运动需求、暂停或非活跃时停止采样；有效体感保留现有采样率，避免先降低瞄准质量。方向、配置、游戏范围改变时更新不可变快照，采样回调读取快照。重新启用继续遵守注册代次和首帧时间基准，避免恢复后回拉或积分旧时段。

### A6. 无 Steam 手柄需求时仍持续前台蓝牙发现

证据：`ContentView.swift:60` → `ControllerManager.swift:50` 启动 Steam 后端。`SteamControllerBackend.swift:76` 在蓝牙可用且前台时扫描所有服务，开启重复广告回调；`:77` 起每扫描 15 秒、停止 15 秒后重新扫描，没有以“需要配对/有已知设备”为启动条件。

建议：广泛扫描改为进入配对页或明确搜索时启动；已知设备按标识重连，连接完成停止发现。后台已有 `suspend()` 停扫描，不能报告为后台持续扫描。避免简单按服务 UUID 过滤导致旧 Steam 固件无法发现。

### A7. 无上限模式的呈现节流会被重复刷新率设置重置

证据链：`MetalView.swift:82` 原生触摸移动 → `setAspectRatio():19` → `Ryujinx.swift:159` → `Library.cs:195` → `Switch.cs:193` → `src/Ryujinx.Graphics.Gpu/Window.cs:318`。最后的 setter 即使目标 FPS 未变化，也在 `:323` 清零上次呈现时间；`:281` 对零值直接允许呈现。窗口/布局回调也重复执行同一设置。

建议：Swift 只在尺寸/屏幕目标改变时提交，核心相同值直接返回。仅 Unbounded 分支受影响；默认 Switch 模式不能把此项当作当前发热主因。

### A8. Amiibo 和震动等低频任务可以按需运行

- `AmiiboService.swift:130` 每 250ms 轮询；`:273` 每次创建异步任务、查询 ABI/状态并发布。自动使用关闭且菜单未打开仍轮询。建议菜单可见或自动使用开启时才轮询，非活跃停止，状态变化才发布；打开菜单时立即补读。
- `BaseController.swift:70` 普通解绑只停传感器，不释放常驻虚拟手柄持有的震动对象。`RumbleController.swift:137/181` 每 19 秒重启播放器；初始播放器强度为零，不能称为持续物理震动。建议解绑/暂停停止引擎，实际震动时按需启动。
- `SteamControllerBackend.swift:483` 的 40ms 定时器在无震动时只需维持 3 秒一次的保活。建议拆分低频保活与有效震动期间的高频发送，不能破坏设备对震动刷新间隔的要求。

这些通常应排在核心负载、输入唤醒和 HUD 生命周期之后，收益大小需要实测。

## B. 与画质/时序有关的候选项

1. **确认同步模式。** 现有 Unbounded 的上限是在 `ProcessFrame()` 之后对现成帧做 Present/DropFrame，不能省掉前面已经执行的模拟和渲染。目标还取 `UIScreen.maximumFramesPerSecond`，不等于当前游戏目标 30 FPS。只把最终显示上限改成 30，不能宣称整个模拟器就按 30 FPS 省电。
2. **不要盲目修改 Custom VSync FPS。** UI 值会乘 2 写入，核心以此作为同步时钟，游戏再按 swap interval 决定节奏。它不是通用的独立屏幕帧率限制；对《旷野之息》须验证速度、音画和物理模拟后再调整。
3. **默认画质已经较保守。** `Options.swift:172/198/207/208` 为掌机、1x、无附加 AA、Bilinear。若用户另外启用了 MetalFX，固定 2x/3x 输出可能再经 Lanczos 缩到实际显示尺寸；它不是自动降低内部渲染分辨率。需要 GPU trace 后再决定关闭或按实际输出尺寸配置，不能盲删跨 API fence。
4. **精准等待的自旋尾段。** `SurfaceFlinger.cs:343` 和 `PreciseSleepHelper.cs:96` 有主动自旋，iOS 睡眠偏差参数还沿用 macOS/M1 条件。先测 `SurfaceFlinger.Composer` CPU，再调自旋预算；不能把阈值 2ms 直接当作每帧固定自旋时间。
5. **MTKView 自身刷新需测量。** 代码使用 MTKView 提供 CAMetalLayer，真正呈现来自 Vulkan，但未显式暂停 MTKView 刷新调度。可比较暂停内部定时或纯 CAMetalLayer 宿主，现有证据不足以证明有重复 GPU 绘制。
6. **磁盘着色器缓存默认关闭。** `Options.swift:170`、解码缺省和核心开关一致，内存缓存仍存在。可对当前游戏单独 A/B 开启，比较第二次同路线的编译卡顿和 CPU 峰值。缓存预载固定并行线程会集中启动工作，不能承诺持续降温，也不能称其完全避免 Metal 原生编译。

不建议在没有测量时同时切换分辨率、MetalFX、缓存、线程模式和同步；否则无法判断收益来源。

## C. 验收方案

固定同一存档、相同场景/路线、720p、目标 30 FPS、屏幕亮度、环境和散热条件；先跑热稳定基线，再逐项 A/B。区分首次着色器编译和相同路线的第二次运行。

分别记录有线充电与不充电两组；同一组内比较软件版本，尽量保持接近的电量区间。不能拿“旧版充电”与“新版不充电”的温度差当作代码优化收益。

| 测量 | 验证目标 |
| --- | --- |
| Instruments Time Profiler、线程唤醒/分配记录 | 输入轮询、UI 发布、主线程同步及 GC 是否下降 |
| Metal System Trace / GPU Counters（设备支持时） | GPU 工作时长、额外后处理、呈现和等待是否下降 |
| Allocations / Memory Graph、监测器实例计数 | 反复旋转、开关 HUD、进出游戏后任务是否累积 |
| 帧时间分布与游戏速度 | 保持 30 FPS 的稳定性、音画同步和游戏速度 |
| 能耗记录、系统 thermalState；固定测点温度（有仪器时） | 判断持续功耗/热压力变化，不把 FPS 单项当能耗结论 |

必须覆盖：HUD 开/关及 RAM 隐藏、无外设/有 Steam、运动轴全部关闭/启用、横竖屏、暂停 1 分钟后恢复、退到游戏库、连续退出重进、失焦返回和正在暂停时退出。

## 未修改范围与审计状态

本次没有改生产源码、参数或构建脚本，也没有生成“已降温”的测试结论。记录的是可定位的优化机会及实现约束。建议第一批先处理 A1/A2/A5/A6，再对 A3/A4 做带唤醒回归的调度优化；A7 可作为独立小修复合并，B 类待实际配置与性能数据确认。
