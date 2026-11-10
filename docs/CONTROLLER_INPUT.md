# 手机运动输入与滑动视角

## 灵敏度倍数

全局设置和单游戏设置共用“视角灵敏度倍数”输入行。输入后点击“应用”或键盘“完成”保存；未应用的草稿不会影响游戏。支持小数，空值、非法字符和范围外数值会显示错误并保留输入内容。

- 范围 `0.25...100`，默认 `1.0`；感觉偏慢可先试 `2～3`，精细操作可试 `0.5`。
- 持久化键为 `TouchLookSensitivityMultiplier`，通过 `NativeSettingsManager` 使用全局/单游戏作用域。
- 系数统一为 `0.012 × 倍数`（每个 UIKit 逻辑点对应的摇杆增量）。`EmulationView` 的独立触摸层和 `MetalView` 使用同一配置，100 倍对应 `1.2`，不会被旧的 10 倍上限截断。
- 输出仍限制为右摇杆 `-1...1`，受游戏自身的转向速度上限约束。高倍率更快达到摇杆满幅，100 倍输入系数不等于游戏视角转速提高 100 倍。
- 当前设计不读取旧的 `TouchLookSensitivity` 配置；第一次使用新倍数设置默认为 `1.0`。

## 陀螺仪坐标契约

`PhoneMotionTransform` 是无状态数学模块，可从 CoreMotion 后台回调调用。输入为手机独立重力 `gravity`、平移加速度 `userAcceleration`（g）及 `rotationRate`（rad/s），输出为 NativeGamepad 的总加速度、独立重力与 deg/s 角速度。三项使用同一坐标变换，按完整采样原子提交。

三个向量使用同一右手旋转：先 `D(x,y,z)=(x,-y,-z)`，再按当前 `UIInterfaceOrientation` 在屏幕平面旋转。最终送入核心的向量如下；角速度额外乘以 `180/π`。

| 界面方向 | CoreMotion 向量 `(x,y,z)` 的最终结果 |
| --- | --- |
| portrait | `(x,-y,-z)` |
| portraitUpsideDown | `(-x,y,-z)` |
| landscapeLeft | `(y,x,-z)` |
| landscapeRight | `(-y,-x,-z)` |

`NpadController` 固定执行 `P(x,y,z)=(x,-z,y)`，因此 Swift 在提交前使用逆变换 `(x,z,-y)`。手机回调串行提交，每次采样仍读取当前界面方向；未知界面方向沿用最近有效值。实体手柄的 `GCController.motion` 路径不使用此模块。

此前加速度为 `(-x,-y,-z)`，角速度为 `(x,-y,-z)`，两者不在同一坐标系；竖屏还额外交换了 Y/Z。横屏绕手机 Y 轴抬起 θ 时，错误映射得到 `(0,-sinθ,cosθ)`，而角速度积分对应 `(0,+sinθ,cosθ)`，导致停止后 Mahony 重力反馈把正向俯仰拉向负向。

修复统一传感器坐标，保留原横屏角速度方向并修正竖屏换轴。不新增会将慢速瞄准误当作零偏的自动学习；核心原有死区仍生效。

## 平移与姿态分离

“手机姿势不变，整部手机向左/右平移”与“朝左/右转向”不同。平移的理想角速度为零，只有 `userAcceleration` 改变，不能直接当成方向反转而给陀螺仪轴取反。

此前 Mahony 用总加速度判断重力方向，平移中的加速/减速会让该方向发生偏转，从而在零角速度下制造视角变化。当前手机路径把 `gravity` 单独传给姿态滤波；游戏读取的总加速度仍包含平移分量，保留摇晃等加速度玩法。

- `MotionBridge.h` 声明 `set_gamepad_motion_sample`：手柄标识加 9 个 `float`，顺序为总加速度 XYZ、角速度 XYZ、重力 XYZ。C# 与 Swift 同步更新，构建会拒绝缺少该导出的核心。
- `NativeGamepad` 在同一把锁内保存/读取完整采样；`NpadController` 通过 `IMotionSampleGamepad` 读取，分别对三个向量应用固定换轴。
- `MotionInput.Update` 使用独立重力做姿态校正，`Accelerometer` 仍输出总加速度。真实转向、俯仰及侧倾的角速度符号保持不变。
- 没有独立重力的实体手柄仍使用其传感器数据；每次逐轴提交及状态重置清除旧的手机重力，避免切换来源后残留。
- 该修复消除模拟器额外滤波造成的假倾斜；若游戏本身根据原始加速度旋转镜头，其行为仍由游戏决定。CoreMotion 的实际重力分离效果须在手机上验收。

## 验证与构建

在项目固定 `.NET 10.0.100` 下运行：

```powershell
& '_杂项/工具/dotnet-10.0.100/dotnet.exe' run --project tests/MotionInput.Tests/MotionInput.Tests.csproj -c Release
```

测试直接链接生产 `MotionInput.cs` 和 `MotionSensorFilter.cs`。合成“静止 0.5 秒 → 抬起 30° → 静止 3 秒”的结果：

| 轨迹 | 运动末端 | 静止末端 |
| --- | --- | --- |
| 一致坐标 | `+28.00°` | `+29.87°` |
| 原错误加速度对照 | `+8.41°` | `-27.37°` |

同时检查零角速度静止、角度积分、有限值、静止段不反转及停后角速度归零。慢速轨迹测试关闭测试死区，用于单独检验滤波积分，不能据此推断游戏接受小于实际配置死区的运动。

平移回归直接使用生产 `MotionInput`：原总加速度融合在零角速度下出现 `18.19°` 最大假转角；独立重力路径与无平移基线的姿态偏差为 `0.0000°`。真实俯仰叠加平移后静止末端仍为 `29.87°`，并检查总加速度没有被重力替代。以上均为合成轨迹结果，不代表手机实测数据。

Codemagic 的 `scripts/build-ios-unsigned.sh` 已加入：

1. 编译应用同一份 `PhoneMotionTransform.swift`、`TouchLookSensitivityConfiguration.swift` 与 `tests/ControllerInputTests.swift`，使用应用的 `MainActor` 默认隔离规则。
2. 检查 100 倍解析、上下界、非有限值、四种方向的俯仰/左右映射，并生成 `build/controller-motion-traces.json`。
3. 把 Swift 生成的 4 组俯仰和 12 组平移轨迹送入生产 C# 滤波器再次验证。平移覆盖四个界面方向以及平放、竖持、斜持，逐帧与同姿势无平移基线比较。
4. 执行 `tests/NativeMotion.Tests`，验证完整采样、来源切换和重置；检查 C 桥接声明及新导出。

回放 JSON 当前契约为 `name/kind/samples`，`kind` 为 `pitch` 或 `translation`；采样必须包含 `acceleration/gyroscope/gravity/timestamp`。缺少字段会明确失败。

对应日志为 `controller-input-build.log`、`controller-input-tests.log`、`controller-motion-tests.log`。

Windows 已执行 C# 合成轨迹、本地化检查及差异检查；没有 Apple SDK，Swift 编译、完整 IPA 构建及手机效果须由 Codemagic 和实机验收。数学轨迹通过不等于游戏实测通过。

## 实机验收

- 分别输入 `0.5`、`2.5`、`10`、`50`、`100` 并应用，确认系数变化和重启保存；清空、输入非数字和 `100.01` 应报错。
- 单游戏覆盖与全局值分别验证；关闭滑动视角时不接管触摸，启用后仍给按钮和摇杆让出命中。
- 两侧横屏分别上下转动后保持不动至少 3 秒，检查停止后的反向回拉；左右转向保持原效果。
- 竖屏检查左右及上下；切换屏幕方向后重复，分别测试初次进入、返回后再次进入游戏。
- 保持手机姿势不变做左右平移，覆盖加速、减速与停下；与原地不动比较，检查不再额外扭转镜头。随后检查左右倾斜与真正转向的方向仍正确。
- 若仍有持续漂移，需记录真实传感器采样和核心姿态，不能只凭画面推定剩余问题是零偏。
