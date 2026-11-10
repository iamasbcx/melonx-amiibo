# MeloNX 第二轮性能优化实施记录

日期：2026-11-11。基线：`2efb3307038506154ddca55c8d500fe672467851`。本轮落实二轮审计中有代码证据且可保持游戏语义的改进。用户测试场景为 iPhone 18 Pro、《旷野之息》、720p、30 FPS、有线充电。

## 实现与适用范围

| 模块 | 实现 | 边界与维护契约 |
| --- | --- | --- |
| 纹理上传 | 小中型上传复用既有 16 MiB staging，减少临时 Vulkan buffer；修正非零起点的 mip 数据边界 | 不足或超大请求仍独立分配；保留 command buffer fence、压缩块、D24S8 和局部更新路径 |
| 音频输出 | Apple 直接接收 PCM16，合并转换与非交错声道写入；DSP 同步 Span 路径省去中间数组/包对象；完成后复用原生 PCM buffer | 保留混音到 PCM16 的饱和量化，以及 PCM16 到 float 的 `/32767` 精度；空闲池最多 8 项、2 MiB，不裁掉播放中的包 |
| 音频生命周期 | 首包才创建/启动 AVAudioEngine；稳定输出不重复调用 Play；PCM 完成使用独立可撤销标识 | 完成前不复用；乱序完成按标签记账；关闭先撤销注册，锁外 Stop，迟到 block 副本不访问已释放 GCHandle |
| 音频周期 | 用剩余绝对期限阻塞替代每 1 ms 轮询；停止信号同时唤醒暂停门和期限等待；渲染会话描述改值类型 | 保留 48 kHz、240 帧/5 ms、目标缓冲及追赶策略；退出仍完成邮箱握手并等待 DSP 线程结束 |
| DSP 帧边界 | 缺少输入声道时补零到完整硬件帧；完整声道不再额外清零；异常时也归还池数组 | 修正单声道输入/双声道输出时的半包和残留样本风险；HardwareDeviceImpl 明确拒绝尺寸错误 |
| 宿主调度 | 控制队列与真实输入分别唤醒；保留绝对 8 ms 轮询心跳；复用 SDL 派发委托和完成事件 | 控制任务不额外触发 HID；暂停仍处理控制消息；iOS SDL 只初始化仍使用的 Events/Video |
| 内核计时器 | 缓存最早期限，仅最早期限改变才通知等待线程 | 保持原超时精度、同期限顺序和取消语义；没有改内核自旋预算 |
| JIT | 双映射 AArch64 同地址首次编译协调；发布与失效共用代次；失败/重入明确处理 | 热命中仍直接查缓存；不同地址可并行；ARM/Thumb 和旧 NoWx 路径保持原行为 |
| IPC / 震动 | HostTracked 单连续段直接返回序列；震动名称缓存、44 字节同步栈传递 | 多段地址验证和读跟踪保留；震动 native 回调必须在返回前复制，不得持有栈指针 |
| shader 编译 | 默认路径与异步路径都进入有限 worker 队列；翻译加载器共用预算规则，按需启动 | 各阶段分别有预算，不能误解为全进程总共两个线程；默认仍等待编译，不自动开启跳过绘制；阻塞需求可提升优先级 |
| pipeline 缓存 | 修改、成功保存、合并分别计代，未改变的 worker 快照不重复写盘 | 保存失败不能清 dirty；加载的 worker 快照仍须合并到主缓存，主缓存按合并结果判断保存 |
| 多 slice 回读 | Vulkan GPU 提交线程把符合条件的 slice 合并到最多 16 MiB 的缓冲，显式 host 可见性屏障并等待写 fence | 仅 `tracked=false`；CPU 线程、已有预取、缩放、深度/模板、多采样等走原路径，保留 guest 可见性与跟踪顺序 |
| 页面与回调 | 每名称一个常驻 native 入口，锁内替换 handler、锁外调用；Air 订阅可撤销；加载进度按会话投递 | 原生借用地址不因注销失效；旧排队进度不能进入新游戏；Alert 应用级只注册一次 |
| native 回调隔离 | handler 明确为 `@Sendable`；MetalFX 私有请求/状态及 bridge 退出默认 MainActor 隔离 | MetalFX 的共享可变状态仍由原 NSLock 独占；原生请求同步写回，不能转异步后使用借用指针 |
| 游戏库 | 按文件身份/大小/时间及密钥、语言、更新依赖缓存元数据；排序日期预读；显式释放 ROM 和更新 NSP 文件流 | 缓存仅在本次进程内；解析失败不缓存；更新流在 NCA 元数据/图标全部读取后或异常退出时关闭，外部目录授权有明确所有者 |
| 图标 | 按像素尺寸及圆角形式缓存，最多 128 项/32 MiB，内存警告清理 | 不修改原始 iconData，原图导出语义保持；界面仍持有的 UIImage 不计入缓存自身上限 |
| Steam | 直接借用 Data 解码，缓存按钮表，只提交变化值；无新运动数据且完全静止时跳过输入队列 | 保留原 GCController 输入线程、菜单/映射捕获、快速按下释放顺序；切换映射/会话/绑定重发状态 |

## 验证

所有新增回归和原有门禁已接入 `scripts/build-ios-unsigned.sh`。固定 .NET SDK 为 `10.0.100`；Swift 纯状态测试使用与应用一致的 `-default-isolation MainActor`，并显式导入 Foundation、Combine、CoreGraphics 等依赖。

Windows 已完成：

- `AppleAudio.Tests`：77,719 次断言，包含 PCM16 全部 65,536 种值的逐位精度、声道拆分、DSP 完整帧/补零、缓冲复用与限额、乱序完成、启动失败清理、迟到回调、暂停退出和重复启动。使用生产 Audio/Apple 会话代码，AVFoundation 边界用测试 shim；不是 Apple 播放实测。
- `CoreOptimization.Tests`：6,033 次断言，覆盖真实 A64 编译及缓存发布/失效、同地址并发、失败/重入、HostTracked IPC 和震动 ABI；Windows 不执行生成的 ARM64 机器码。
- `HostLoop.Tests`：98 次断言，覆盖真实输入/控制队列分离、绝对心跳、暂停恢复、退出以及已有输入/渲染释放回归。
- `GraphicsOptimization.Tests`：上传布局/偏移边界、回读打包、dirty/merge 代次及真实编译调度器并发、优先级、退出取消通过。
- `GraphicsLink.Tests`：直接执行生产 `ShaderCollection.CheckProgramLink` 的失败、取消、完成发布与等待状态检查；不创建 Vulkan 设备。
- 既有 `NativeMotion.Tests` / `MotionInput.Tests` 通过；`AmiiboContract.Tests` 10 项、`HleAmiibo.Tests` 15 项、`PresentationPacing.Tests` 118 次断言通过。运动日志中的非法样本拒绝为预期测试；本机未重新生成 Swift 运动轨迹。
- `python scripts/test_verify_ipa.py`：20 项通过；`check_localization.py`：516 个键、408 个中文条目，占位符保持。
- 构建脚本语法与差异空白检查通过。

图形 Vulkan/Gpu/OpenGL 托管 Release 编译已通过。完整 `Ryujinx.Library` 的 Windows 托管 Release 构建通过：12 个原有/平台告警、0 个错误。命令：`dotnet build src/Ryujinx.Library/Ryujinx.Library.csproj -c Release -p:RuntimeIdentifiers=win-x64 -p:RuntimeIdentifier=win-x64 -p:PublishAot=false -p:UseNativeAOTRuntime=false -p:HybridGlobalization=false`。这些覆盖仅用于 Windows 契约检查，正式 iOS 参数未放宽。验证日志归档于本地 `_杂项/验证日志/`。

`UIRuntimeOptimizationTests.swift` 覆盖回调替换/重入、观察者撤销、会话隔离、真实临时文件及密钥/更新依赖失效、LRU 限额和 Steam 报告/有序输入。当前 Windows 无 Swift/Xcode/Apple SDK，尚未运行这套 Swift 测试，未生成本轮 IPA，也未用真实加密更新 NSP 验证元数据资源释放。必须由 Codemagic/Xcode 完成 Swift、iOS NativeAOT、Apple 框架编译，再安装验证。

## 保留的参数和真机验收

没有修改 Apple AutoFlush 的 1/1.5 ms 阈值、内核线程自旋预算、来宾时钟、分辨率或画质；这些候选缺少该设备 Metal/Instruments 证据，直接改变可能影响帧时间、同步或游戏速度。本轮没有该 iPhone 的前后功耗、温度或 FPS 数据，不能据此给出降温度数或性能百分比。

真机使用同一存档、路线、720p/30 FPS、亮度和环境；分别比较充电/不充电、首次编译/缓存命中。至少检查：长时间音画同步/欠载、暂停中退出、连续进入退出 20 次、外接屏切换、Steam 快按与重连、四方向体感、纹理更新/读回、冷缓存编译及第二次启动。比较线程唤醒、分配率、CPU/GPU 时间与帧时间分布，再记录温度和 thermalState。

## 备份与回退

修改前文件保存在项目 `备份/二轮优化*/`、`备份/二轮界面复核*/` 等任务目录。提交保持源码、测试、脚本及本文一致。出现回归时回退本轮提交并重新构建整套应用和核心，不能单独混用旧 dylib 绕过 ABI 门禁。
