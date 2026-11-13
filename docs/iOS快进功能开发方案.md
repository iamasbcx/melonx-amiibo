# MeloNX iOS 快进功能开发方案

## 1. 当前基线（开发前）

核心模拟器已经有 `TurboMode`。`src/Ryujinx.HLE/Switch.cs` 会通过 `TickSource.TickScalar` 加快来宾时间，`100` 表示正常速度，当前桌面配置默认的快进倍率约为 `200%`。

iOS 目前没有把这条能力接到 Swift 界面：

- `src/Ryujinx.Library/Library.cs` 构造 iOS `HleConfiguration` 时把 `TickScalar` 固定为 `ITickSource.RealityTickScalar`。
- `src/MeloNX/MeloNX/Core/Ryujinx.swift` 只有暂停、停止和呈现帧率等桥接，没有快进接口。
- `src/MeloNX/MeloNX/UI/Emulation/Config/InGameConfigView.swift` 的齿轮菜单没有快进项。
- `src/MeloNX/MeloNX/UI/Emulation/Metal/MetalViewContainer.swift` 已经有“点按画面显示临时菜单按钮”的机制，但还没有独立的悬浮快进按钮。

因此，单纯把 iOS 屏幕刷新率或 VSync 改高不能实现快进，只会改变呈现节奏或丢帧。真正的快进必须修改模拟时钟倍率，再由 iOS 菜单控制。

## 2. 推荐的菜单交互

建议保留现有齿轮作为入口，再提供可选的悬浮快进按钮。两个入口共用同一套状态，避免出现“齿轮显示已关闭、悬浮按钮仍然有效”这种不一致。

### 齿轮菜单

齿轮菜单增加一个“快进”分组：

| 项目 | 行为 | 是否记忆 |
| --- | --- | --- |
| `启用快进功能` | 允许当前游戏使用快进按钮和快进设置；它不直接让游戏进入快进 | 按游戏记忆，默认开启 |
| `快进倍率` | 在小数编辑框输入 `1.0...20.0` 倍，支持 `1.1`、`1.4`、`6.5`、`20` | 按游戏记忆 |
| `显示悬浮快进按钮` | 控制游戏画面是否显示独立按钮 | 按游戏记忆 |
| `编辑悬浮按钮` | 进入拖动、大小和透明度编辑界面 | 编辑结果按游戏记忆 |

这里要区分“功能配置”和“当前运行状态”：启用开关、倍率和按钮显示可以保存；悬浮按钮当前是否处于按下状态只存在于本次运行中。松开按钮、暂停、切后台、退出游戏或核心异常时，都必须恢复正常速度。这样可以避免上一次按住按钮或误触导致下一次开游戏直接以 2 倍运行。

### 悬浮按钮

悬浮按钮采用“按住加速、松开恢复”，不使用点击切换：

- 未启用时显示 `forward.fill` 或速度表图标；按住期间使用高亮背景并显示当前小数倍率，例如 `1.4x`、`6.5x`。
- 按钮默认与现有齿轮同侧，沿用 `MetalViewContainer` 的安全区布局；不遮挡虚拟摇杆和性能 HUD。
- 手指按下时立即进入快进，手指抬起或触控取消时立即恢复正常速度；按钮不保存“按下”状态。
- 需要编辑位置时，从齿轮菜单进入“编辑悬浮按钮”，避免把普通按压误认为编辑操作。
- 编辑模式中可拖动按钮；松手时保存位置。退出编辑模式后恢复按住加速行为。
- 最小可点击尺寸保持 `44pt`，可配置范围建议为 `36–72pt`；透明度建议为 `0.3–1.0`。

位置不要保存屏幕像素，而要保存相对于安全区域的归一化坐标，例如 `x`、`y` 使用 `0...1`。横屏、竖屏和不同分辨率分别保存一组位置，加载时再按照当前安全区换算成点数。这样旋转屏幕或换设备不会把按钮放到屏幕外。

按钮位置在设置页的预览画布中自由拖动，保存为横屏/竖屏各自的归一化坐标；运行时按当前画布尺寸和安全边距换算位置。现有齿轮已经采用“点按画面显示、闲置后隐藏”的方式，悬浮按钮独立受显示开关控制。

### 按住状态机

悬浮按钮需要明确的状态转换，不能使用简单的 Toggle：

```text
Idle
  └─ touchDown（功能已启用且核心可用）→ TurboPressed
TurboPressed
  ├─ touchUp → Idle，并调用 set_turbo_mode(false)
  ├─ touchCancel → Idle，并调用 set_turbo_mode(false)
  ├─ pause/background/stop → Idle，并调用 set_turbo_mode(false)
  └─ coreUnavailable → Idle
```

SwiftUI 可以用 `DragGesture(minimumDistance: 0)` 或等价的按压手势捕获 touch-down/touch-up；手势结束和视图销毁路径都必须执行释放逻辑。按钮按下后即使手指滑出按钮范围，也要在最终 touch-up/cancel 时恢复正常，不能遗留快进状态。

## 3. 配置归属和持久化

建议按职责拆分配置：

### Swift UI 配置

以下字段属于 iOS 界面层，放在 `NativeSettingsManager`，并使用现有的游戏标题 ID 作用域：

```text
fastForwardButtonVisible: Bool
fastForwardButtonSize: Double
fastForwardButtonOpacity: Double
fastForwardButtonPositionPortraitX/Y: Double
fastForwardButtonPositionLandscapeX/Y: Double
fastForwardEnabled: Bool
fastForwardMultiplier: Double // 1.0...20.0，默认 2.0
```

`NativeSettingsManager(titleId, true)` 已支持“游戏专属值覆盖全局值”的读取方式，因此设置保存后，下一次打开同一游戏可以直接恢复；没有游戏专属值时回退到全局默认值。现有的“显示菜单按钮”、触摸布局和输入设置也采用同一套机制。

### 模拟器配置

以下字段会影响核心模拟时钟，应该进入 `Options`、`Options+Codable.swift`、`NativeOptions.h`，再由 `Library.cs` 传入 `HleConfiguration`：

```text
turboMultiplier: Int32   // 100 = 正常，200 = 2 倍，2000 = 20 倍
```

倍率必须在 C# 侧再次限制为 `100...2000`，不能只依赖 Swift 输入校验。Swift 以 `Double` 保存一位小数，调用 ABI 时转换为整数百分比，例如 `1.1 → 110`、`6.5 → 650`、`20 → 2000`。开发阶段可以直接采用当前最新版配置契约；如果字段契约发生变化，应明确报错并同步更新当前调用方，不增加旧布局兼容分支。

“启用快进功能”只作为持久化的功能开关，不代表当前已经按下按钮。游戏启动时始终进入正常速度；只有按钮收到有效的 touch-down 才调用运行时快进接口。

## 4. 核心和 C ABI 设计

不要让 Swift 直接调用“切换”语义作为唯一接口，因为重复点击、界面重建或恢复前台时可能造成状态反转。建议新增幂等接口：

```text
set_turbo_mode(bool enabled)
get_turbo_mode() -> bool
set_turbo_multiplier(int32 multiplier)
```

C# 侧在 `Switch` 增加了 `SetTurboMode(bool)`，并保留现有桌面端 `ToggleTurbo()` 作为快捷键实现。`SetTurboMode` 的契约是：

1. `enabled == true` 时把 `TickScalar` 设为 `Configuration.TickScalar`。
2. `enabled == false` 时恢复 `ITickSource.RealityTickScalar`。
3. 重复设置同一值不产生额外状态转换。
4. `set_turbo_multiplier` 先在 C# 侧限制范围，再更新配置；快进已经开启时立即应用新倍率。
5. 模拟上下文为空或正在退出时，接口安全返回，不访问已经释放的对象。

`TickSource.TickScalar` 已经通过快照和锁保护倍率切换，适合从 Swift UI 线程发起调用。核心接口仍需使用当前项目的生命周期保护，不能在 `mainRyu` 返回后继续持有 `Switch` 引用。

Swift 层在 `Ryujinx.swift` 增加包装函数和 `@_silgen_name` 声明；`RyujinxController` 持有当前 `turboMode`，在开始游戏时加载配置，在停止、崩溃和重新启动时清零运行态。菜单只通过控制器调用，不直接操作 C ABI。

## 5. 音频、画面和设备温度

快进改变的是来宾时间，不是 iOS 屏幕刷新率。画面仍然受到当前 VSync 和 GPU 吞吐限制，设备性能不足时不会保证达到所选倍率。

音频使用独立的硬件播放时钟。模拟器加速后，来宾音频生产速度可能超过硬件消费速度，出现缓冲不足、断续或延迟增加。第一版应明确选择一种策略：

- 默认保留音频，先通过实机测试确认可接受的缓冲行为；或
- 快进期间静音，退出快进后恢复用户原来的音量。

建议第一版先保留音频并在菜单说明“快进可能造成音频断续”，不要偷偷修改用户音量；如果实机测试表明断续明显，再单独设计“快进时静音”选项。发热和功耗也应在 iPhone 真机上验证，不能仅凭 FPS 推断。

## 6. 开发阶段

### 阶段一：最小闭环（已完成代码，待 iOS 真机验证）

1. 修正 iOS `HleConfiguration` 的 turbo 倍率来源，不再固定传入 `RealityTickScalar`。
2. 增加 `set_turbo_mode`、`get_turbo_mode` ABI 和 Swift 包装。
3. 在齿轮菜单加入“快进”开关和 `1.0...20.0` 小数倍率编辑框，默认 `2.0`。
4. 使用 `NativeSettingsManager` 保存“启用快进功能”和“显示按钮”。
5. 增加悬浮按钮，支持显示/隐藏、按住加速、松开恢复和按下高亮状态；位置编辑在第二阶段接入。

### 阶段二：自由拖动编辑（代码已完成，待 iOS 真机验证）

1. 增加拖动编辑模式。
2. 按横屏/竖屏保存归一化位置。
3. 增加归一化坐标重置；按钮大小和透明度设置已在第一阶段实现。
4. 在设置页显示并编辑当前倍率，按钮按下时显示实际倍率。

### 阶段三：音频策略和真机体验

1. 根据真机测试结果决定是否增加“快进时静音”或音频缓冲策略。
2. 继续观察 `20x` 等高倍率下的稳定性、温度和功耗。

## 7. 验证清单

- 齿轮中的启用开关可以在运行中立即禁止或允许按钮；关闭开关时必须强制释放正在按下的按钮。
- 在多个倍率（包括 `1.1x`、`6.5x` 和 `20x`）下通过游戏内计时、物理移动和帧时间确认确实是模拟时钟加速，而不是只丢帧。
- 开关、倍率、按钮显示、按钮位置、大小、透明度在退出后重新打开同一游戏仍然恢复。
- 全局设置和游戏专属设置的覆盖关系符合 `NativeSettingsManager` 现有行为。
- 横屏/竖屏、刘海安全区、外接屏和不同窗口大小下按钮不出界、不挡住主要触控区域。
- 暂停、恢复、切后台、停止游戏、崩溃退出和连续重开不会留下 turbo 状态或悬空 native 调用。
- 快进开关期间检查音频断续、GPU/CPU 占用、温度和 `thermalState`。
- Windows 上先运行托管测试；iOS 最终需要 macOS/Xcode 和真机验证，不能用 Windows 构建结果代替 iOS 验收。

## 8. 推荐的第一版交互结论

第一版采用“齿轮菜单配置 + 可选悬浮按钮”的组合：齿轮中设置是否启用功能、按钮显示、倍率、自由位置、大小和透明度；悬浮按钮只负责按住期间加速，松开立即恢复正常。按钮默认位于右上安全区、`44pt`、`0.7` 透明度，倍率默认 `2.0x`。归一化坐标按横屏/竖屏分别保存，并在运行时按安全边距换算。

## 9. 本次实现状态

本次已经完成快进闭环和自由位置编辑：

- C# 核心通过 `set_turbo_mode`、`get_turbo_mode` 暴露幂等运行时接口；iOS 默认快进倍率为 `200%`。
- 齿轮菜单保存每个游戏的“启用快进功能”“显示快进按钮”和 `1.0...20.0` 小数倍率。
- 悬浮按钮按下加速，抬起或取消恢复正常；暂停、切后台、停止和核心异常也会释放快进状态。
- 设置页支持自由拖动、横竖屏独立归一化坐标、按钮大小 `36...72pt` 和透明度 `0.3...1.0`，配置使用 `NativeSettingsManager` 按游戏记忆。
- 当前 Windows 已完成托管编译与相关测试；Swift/iOS 真机编译和音频、温度体验仍需在 macOS/Xcode 上验证。
