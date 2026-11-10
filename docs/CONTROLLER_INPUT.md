# 手机运动输入、滑动视角与布局编辑

## 设置范围与存储

游戏内齿轮提供“输入设置”和“编辑虚拟手柄布局”，均可选择“当前游戏 / 全局默认”。输入页可切换范围，并跳转到同一范围的布局编辑器。没有有效游戏 ID 时只使用全局。

| 项目 | 存储及继承规则 |
| --- | --- |
| 手柄选择 | `SelectedControllerProfiles` 加游戏 ID 后缀；缺省读取全局。虚拟手柄使用稳定标识，实体手柄使用设备名称和同名序号 |
| 玩家类型 | `ControllerTypePlayer0...7` 分别覆盖；核心启动参数和设备绑定使用同一来源 |
| 按键、摇杆、扳机阈值、运动映射 | 全局 `controllerMappings.json`；游戏 `config/<titleId>/controllerMappings.json`，以设备映射为覆盖单位 |
| 键盘映射 | 全局 `keyboardConfig.json`；游戏 `config/<titleId>/keyboardConfig.json` |
| 触摸、倍率、方向控制、大小/透明度、L3/R3、默认显示及菜单按钮 | `NativeSettingsManager` 按键逐项回退；修改全局不替换已有游戏覆盖 |
| 左摇杆方向键模式 | `joystickDpad-global` / `joystickDpad-<titleId>`；游戏缺省时回退全局 |
| 控件位置/大小/显示、网格 | `LayoutManager` 按全局/游戏及 portrait/landscape 分别存储；重置只操作当前范围和方向 |

只浏览设置不会创建覆盖。“使用全局输入默认值”清除输入页覆盖，保留其他模拟器设置和布局文件，并重算游戏专属设置标记：没有其他设置才移除标记，值为 `false` 的其他覆盖仍然有效。布局在编辑器单独重置。不读取旧控制器选择格式，也不迁移旧配置。

## 编辑会话与输入生命周期

进入编辑时保存原暂停状态，挂起输入并释放按键、摇杆、原生触摸与运动；设置页跳转布局页保持同一会话。退出后应用当前游戏的有效配置、重新加载对应方向布局，再恢复原暂停状态。游戏已退出时不重新开放输入。

`InGameInputSession` 在开始游戏、结束游戏和挂起状态切换时推进代次。单设备 `InputAttachmentState` 分别管理绑定代次和传感器注册代次。后台回调捕获代次，提交时按 **会话锁 → 设备绑定锁** 校验；锁内只执行 native 写入，不读取 UI、不等待队列。旧游戏、旧设备绑定、已停止传感器的回调不能进入新会话。

解绑先废弃令牌，再由主线程停止 CoreMotion、GCController 或 Steam 传感器。固定虚拟手柄对象可重新绑定；过期停止任务不得关闭新绑定。停止运动只使运动注册失效，不关闭按键。参数修改不重新创建设备，只有选择、玩家顺序或类型变化才重新绑定。

`suspend_gamepad_motion(id)` 推进核心运动代次、清除瞬时运动并冻结游戏姿态。恢复后第一帧只重建时间基准，避免积分整个暂停时段。手机方向变化也推进核心代次，防止一次核心轮询间多次转屏被漏掉。

## 滑动视角与菜单命中

运行态 `ControllerView` 是唯一滑动视角输入层，使用与编辑器相同的手柄画布坐标。`MetalView` 只处理游戏原生触摸，不再存在第二个滑动区域。未绑定虚拟手柄、关闭滑动开关或隐藏区域时，不接管滑动视角。

可见按钮和摇杆优先命中。滑动与右摇杆分别保存输入状态；拖动摇杆时摇杆优先，滑动结束及归零定时器只能清除滑动来源，不能清掉正在使用的摇杆。隐藏或拆卸输入控件时清除自身状态。

游戏齿轮放在手柄输入层上方并遵守安全区，闲置时淡化但仍可点击；滑动开始可以唤醒菜单。此行为仍受“显示菜单按钮”设置控制。

布局画布可以延伸到全屏，但工具栏独立留在安全区内。顶部按钮至少有 44 点命中区域；长参数面板允许滚动，不能把工具栏挤到状态栏或刘海区域。四向微调和网格吸附使用实际画布尺寸，不使用固定的 320×180 换算。横竖屏布局和重置互相独立。

## 灵敏度倍数

“视角灵敏度倍数”支持 `0.25...9999`，默认 `1.0`，支持小数；偏慢可先试 `2～3`，精细操作可试 `0.5`。点击“应用”或键盘“完成”保存；空值、非法字符、非有限值及越界值报错，保留输入内容。

配置键为 `TouchLookSensitivityMultiplier`，按全局/游戏范围保存。每个 UIKit 逻辑点的摇杆增量为 `0.012 × 倍数`，9999 倍对应 `119.988`。右摇杆输出仍限制在 `-1...1`，游戏本身最大转速不会因此提高 9999 倍。当前不读取旧 `TouchLookSensitivity` 设置。

## 六项手机运动控制

灵敏度下方提供平移左右/上下/前后，以及旋转左右转向/上下俯仰/左右倾斜；每项独立启用、反向。平移对应屏幕 X/Y/Z；旋转转向、俯仰、倾斜对应 Y/X/Z。

键名为 `PhoneMotion.<TranslationX|TranslationY|TranslationZ|RotationX|RotationY|RotationZ>.Enabled` 和 `.Inverted`。全部默认启用，仅左右平移默认反向。禁用、正向、反向的系数分别是 `0`、`1`、`-1`；禁用时保留反向选择。实体手柄保留自己的运动映射，滑动视角另有 X/Y 反向设置。

## 手机坐标与姿态契约

`PhoneMotionTransform` 接收 CoreMotion 的独立 `gravity`、`userAcceleration`（g）和已校正 `rotationRate`（rad/s），以及主线程取得的方向/控制值快照。三个物理向量执行同一基础变换；角速度另乘 `180/π`。

| UIInterfaceOrientation | 基础变换 `(x,y,z)` | ABI 方向值 |
| --- | --- | --- |
| portrait | `(x,-y,-z)` | 0 |
| portraitUpsideDown | `(-x,y,-z)` | 1 |
| landscapeLeft | `(y,x,-z)` | 2 |
| landscapeRight | `(-y,-x,-z)` | 3 |

`NpadController` 固定执行 `P(x,y,z)=(x,-z,y)`；Swift 提交前用逆变换 `(x,z,-y)` 抵消。旋转系数已处于核心屏幕坐标，不再次换轴。界面方向以手机主应用窗口为准，外接屏不覆盖手机方向；未知方向保留最近有效值。方向采用独立 ABI 编码，不使用 UIKit 枚举原始值。

手机游戏姿态采用相对四元数：首帧将当前握姿定义为游戏零点，并保存初始重力参考；后续只积分 `gyro * rotationFactors`。先屏蔽/反向，再判断死区和应用灵敏度，禁用轴的大幅运动不能让其他轴的小噪声越过门槛。

手机路径不再把 Mahony 重力反馈加入游戏姿态增量，避免转屏、暂停期间移动手机或禁用单轴后产生回拉/跨轴泄漏。转屏和暂停恢复只重建时间基准，保留游戏姿态及初始重力参考；新方向只影响后续输入轴。切换控制也不跳回物理姿态。没有独立手机元数据的实体手柄继续使用原有 Mahony 融合。

在屏幕坐标下，Swift 提交加速度 `g + u * translationFactors`。核心先分离已调整的平移分量，再加上随受控游戏姿态合成的虚拟重力，最后施加原有全局负号。物理重力仅用于分离平移，不再纠偏游戏视角。

平移加速度不是位移：匀速段接近零，刹停时加速度反向。左右平移反向同时影响加速与减速，不能保证整段向右位移一直向右转镜头，也不把加速度积分成位置。具体游戏对加速度、角速度和姿态的用途仍需实机确认。相对角速度积分没有绝对回正约束，真实传感器残余零偏可能累积，需实测漂移。

## Swift / C / C# 接口

`MotionBridge.h`、Swift 调用和 C# 导出使用同一签名：

```c
void set_gamepad_phone_motion_sample(
    void *id,
    float accelerationX, float accelerationY, float accelerationZ,
    float gyroscopeX, float gyroscopeY, float gyroscopeZ,
    float gravityX, float gravityY, float gravityZ,
    float rotationFactorX, float rotationFactorY, float rotationFactorZ,
    int32_t screenOrientation
);
void suspend_gamepad_motion(void *id);
```

完整手机采样在 `NativeGamepad` 同一把锁内保存/读取；物理向量必须有限，重力非零，系数只能为 `-1/0/1`，方向只能为 `0...3`。实体逐轴输入和重置清除手机元数据。旧手机导出已删除，构建和 IPA 门禁拒绝只有旧导出的核心，不自动兼容。

## 回归与构建

本地固定 SDK 命令：

```powershell
& '_杂项/工具/dotnet-10.0.100/dotnet.exe' run --project tests/MotionInput.Tests/MotionInput.Tests.csproj -c Release
& '_杂项/工具/dotnet-10.0.100/dotnet.exe' run --project tests/NativeMotion.Tests/NativeMotion.Tests.csproj -c Release
python scripts/check_localization.py
python scripts/test_verify_ipa.py
```

测试直接使用生产代码。C# 回归覆盖转屏零角速度、暂停改变握姿后恢复、倾斜初态禁用轴、三轴正反/禁用、组合运动、死区、虚拟重力、来源切换、原子采样、暂停/方向代次、无效输入和实际 HLE 加速度出口。保留实体融合对照；手机测试以新相对姿态契约为准，不要求复现旧实现的错误结果。

`scripts/build-ios-unsigned.sh` 在 Xcode 26.2 上执行以下门禁，再构建 IPA：

- C11 桥接头严格警告检查；应用默认 MainActor 隔离下编译 `ControllerInputTests.swift`，验证四方向、六轴控制及 9999 倍边界，并生成 Swift 回放供 C# 消费。
- `InputProfileTests.swift` 使用隔离 UserDefaults suite 检查作用域、动态继承、重置和启动投影。
- `InputLifecycleTests.swift` 检查游戏/设备/运动注册代次及专属标记重算。
- `VirtualControllerInteractionTests.swift` 直接编译生产输入仲裁、命中及布局数学模块，检查滑动归零不清摇杆、区域边界和真实画布微调。
- C# 运动回归、NativeMotion、本地化、IPA 验证器测试；产物必须包含新手机运动导出和挂起导出。

Swift 回放 JSON 为 `name/kind/samples`，`kind` 为 `pitch` 或 `translation`；每个采样必须包含 `acceleration/gyroscope/gravity/rotationFactors/screenOrientation/timestamp`。缺字段或非法值明确失败。Swift 回放覆盖四方向俯仰，以及四方向和三种握姿的平移；组合控制由独立 C# 回归覆盖。

Windows 可执行 .NET/Python 检查，无法执行 Apple SDK 下的 Swift 编译和 iOS UI。Swift 构建、完整 IPA 及触摸安全区效果需 Codemagic 和实机验收；数学回归通过不等于真机通过。原审计证据保留在 `_杂项/审计/`。

2026-11-10 本次本地验证：`MotionInput.Tests`、`NativeMotion.Tests` 均通过；IPA 验证器 19 项通过；本地化检查通过（516 个键，408 个中文条目，占位符完整）；构建脚本 `bash -n` 和 `git diff --check` 通过。NativeMotion 的两条非法采样错误日志为拒绝非法输入测试的预期结果。Swift 回放和新增 Swift 测试尚未在本机执行，不包含在以上通过结论中。

## 实机验收

1. 竖屏进入游戏 → 齿轮 → 编辑布局，逐个点击顶部隐藏、选项、重置、完成；滚动长参数面板、选中滑动区域后再试。横竖屏切换后菜单保持可点。
2. 将滑动区域放大到全屏；分别用按钮、左右摇杆和齿轮。持续拖右摇杆时结束另一根手指的滑动，摇杆不能被清零。隐藏区域或不选择虚拟手柄后，游戏原生触摸不被幽灵区域拦截。
3. 在两种横屏和竖屏中转动后停住至少 3 秒；打开设置时改变手机姿势，关闭后静置；转屏后静置。检查无反向回拉，再检查六轴正反/禁用及斜握时的单轴控制。
4. 当前游戏/全局、横屏/竖屏分别微调、网格吸附和重置，确认范围独立；游戏输入恢复全局时保留其他图形/CPU覆盖。输入 `0.5`、`2.5`、`500`、`9999` 并重启检查保存；非法及越界值应报错。
5. 编辑期间无按钮、触摸或运动透传；原先手动暂停的游戏关闭编辑后仍暂停。反复退出/进入游戏、解绑/重绑虚拟手柄、开关运动，检查无旧输入或持续漂移。
6. 左右平移分别观察加速、减速和停止；确认旋转控制独立。若仍漂移，记录真实传感器与核心姿态，不能只凭画面推定剩余原因。
