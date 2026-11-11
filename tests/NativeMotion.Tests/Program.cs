using System.Numerics;
using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Configuration.Hid.Controller;
using Ryujinx.Common.Configuration.Hid.Controller.Motion;
using Ryujinx.Input;
using Ryujinx.Input.HLE;
using Ryujinx.Input.Native;

// CI 可能把未捕获托管异常显示为 134；记录原始异常和阶段名。
AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
    Console.Error.WriteLine($"NativeMotion.Tests: unhandled exception (terminating={eventArgs.IsTerminating}): {eventArgs.ExceptionObject}");
TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
{
    Console.Error.WriteLine($"NativeMotion.Tests: unobserved task exception: {eventArgs.Exception}");
    eventArgs.SetObserved();
};
void Stage(string name) => Console.WriteLine($"NativeMotion.Tests: stage={name}");

// 通过生产驱动的公共入口验证采样事务、输入源切换和重置，避免用替身重复实现锁逻辑。
Stage("init");
using var driver = new NativeGamepadDriver();
nint id = new(0x2345);
NativeGamepadDriver.AttachGamepad("Motion regression", id);
var gamepad = (NativeGamepad)driver.GetGamepad(id.ToInt64().ToString("X"));
var first = new GamepadMotionSample(new Vector3(1, 2, 3), new Vector3(4, 5, 6), Vector3.UnitZ, Vector3.One, 0);
var second = new GamepadMotionSample(new Vector3(7, 8, 9), new Vector3(10, 11, 12), Vector3.UnitY, new Vector3(-1, 0, 1), 2);

void Submit(GamepadMotionSample sample) => NativeGamepadDriver.SetMotionSample(id, sample.Accelerometer, sample.Gyroscope, sample.Gravity!.Value, sample.RotationFactors!.Value, sample.ScreenOrientation!.Value);
void Require(bool success, string message)
{
    if (!success) throw new InvalidOperationException(message);
}

Stage("sample-concurrency");
Submit(first);
Require(gamepad.GetMotionSample() == first, "完整采样没有保留全部向量");
int inconsistent = 0;
await Task.WhenAll(
    Task.Run(() =>
    {
        for (int index = 0; index < 40_000; index++) Submit(index % 2 == 0 ? first : second);
    }),
    Task.Run(() =>
    {
        for (int index = 0; index < 40_000; index++)
        {
            GamepadMotionSample sample = gamepad.GetMotionSample();
            var values = sample with { MotionEpoch = 0 };
            if (values != first && values != second) Interlocked.Increment(ref inconsistent);
        }
    }));
Require(inconsistent == 0, "原子读取看到了混合帧");

// 相同角速度也必须清除重力，否则手机采样切换为实体手柄后会遗留融合来源。
Submit(first);
Stage("axis-reset");
NativeGamepadDriver.SetMotionData(id, (int)MotionInputId.Gyroscope, first.Gyroscope.X, first.Gyroscope.Y, first.Gyroscope.Z);
Require(gamepad.GetMotionSample().Gravity is null && gamepad.GetMotionSample().RotationFactors is null && gamepad.GetMotionSample().ScreenOrientation is null, "逐轴角速度输入没有清除手机元数据");
Submit(first);
NativeGamepadDriver.SetMotionData(id, (int)MotionInputId.Accelerometer, first.Accelerometer.X, first.Accelerometer.Y, first.Accelerometer.Z);
Require(gamepad.GetMotionSample().Gravity is null && gamepad.GetMotionSample().RotationFactors is null && gamepad.GetMotionSample().ScreenOrientation is null, "逐轴加速度输入没有清除手机元数据");
Submit(second);
ulong beforeResetEpoch = gamepad.GetMotionSample().MotionEpoch;
NativeGamepadDriver.ResetState(id);
Require(gamepad.GetMotionSample() == new GamepadMotionSample(Vector3.Zero, Vector3.Zero, null, null, MotionEpoch: beforeResetEpoch), "重置未清除完整运动状态，或代次被倒退");
Submit(first);
var validBeforeInvalid = gamepad.GetMotionSample();
NativeGamepadDriver.SetMotionSample(id, second.Accelerometer, second.Gyroscope, second.Gravity!.Value, new Vector3(float.NaN, 1, 1), 0);
Require(gamepad.GetMotionSample() == validBeforeInvalid, "非法方向系数改变了采样状态");
NativeGamepadDriver.SetMotionSample(id, second.Accelerometer, second.Gyroscope, second.Gravity!.Value, Vector3.One, 4);
Require(gamepad.GetMotionSample() == validBeforeInvalid, "非法屏幕方向改变了采样状态");

// 直接经过生产 NpadController，验证游戏最终收到的符号，而不是仅检查驱动中的中间值。
// CemuHook 在 GamepadDriver 模式下不会使用；本测试只注入真实 Native 驱动。
Stage("npad-hle");
using var npad = new NpadController(null!);
var configuration = new StandardControllerInputConfig
{
    Id = gamepad.Id,
    ControllerType = ControllerType.ProController,
    Motion = new StandardMotionConfigController
    {
        EnableMotion = true,
        MotionBackend = MotionInputBackendType.GamepadDriver,
        Sensitivity = 100,
        GyroDeadzone = 0,
    },
};
Require(npad.UpdateDriverConfiguration(driver, configuration), "NpadController 未连接 Native 驱动");
var driverGravity = Vector3.UnitY; // Npad 固定换轴后为 +Z，是水平静止姿态。
Submit(new GamepadMotionSample(driverGravity, Vector3.Zero, driverGravity, Vector3.One, 0));
npad.Update(); // MotionInput 第一帧仅记录时间戳，先完成初始化再验证游戏输出。
Thread.Sleep(1);

foreach (float inputX in new[] { -0.4f, 0.4f })
{
    const float vertical = 0.2f;
    const float depth = 0.3f;
    // Swift 已将屏幕平移 X 取反；Y/Z 保持原值，再转换到 driver 坐标。
    // 此处输入对应 Npad 换轴前 (-inputX, 1+depth, -vertical)。
    var corrected = new GamepadMotionSample(new Vector3(-inputX, 1 + depth, -vertical), Vector3.Zero, driverGravity, Vector3.One, 0);
    Submit(corrected);
    npad.Update();
    var output = npad.GetHLEMotionState();
    var expectedAcceleration = new Vector3(inputX, -vertical, -(1 + depth));
    Require(Vector3.Distance(output.Accelerometer, expectedAcceleration) < 0.002f,
        $"游戏加速度方向不符：inputX={inputX}，actual={output.Accelerometer}，expected={expectedAcceleration}");
    Require(MathF.Sign(output.Accelerometer.X) == MathF.Sign(inputX), "游戏收到的水平平移符号仍相反");
    Require(output.Gyroscope == Vector3.Zero && output.Rotation == Vector3.Zero, "纯平移生成了角速度或角度积分");
    for (int index = 0; index < output.Orientation.Length; index++)
    {
        float expected = index % 4 == 0 ? 1f : 0f;
        Require(MathF.Abs(output.Orientation[index] - expected) < 0.0001f, "独立重力未阻止平移改变姿态");
    }
    Require(gamepad.GetMotionSample().Gravity == driverGravity, "平移校正改变了独立重力");
}

// 检查角速度仍采用原有 P(x,y,z)=(x,-z,y) 和 HLE 单位缩放，不随平移方向校正取反。
Submit(new GamepadMotionSample(driverGravity, new Vector3(10, 20, 30), driverGravity, Vector3.One, 0));
npad.Update();
var rotated = npad.GetHLEMotionState();
Require(Vector3.Distance(rotated.Gyroscope, new Vector3(0.027f, -0.081f, 0.054f)) < 0.002f, "角速度方向或单位发生变化");

// 控制系数属于核心屏幕坐标，不能被 Npad 的固定传感器换轴再次旋转。
Submit(new GamepadMotionSample(driverGravity, new Vector3(10, 20, 30), driverGravity, new Vector3(-1, 0, 1), 0));
npad.Update();
var controlled = npad.GetHLEMotionState();
Require(Vector3.Distance(controlled.Gyroscope, new Vector3(-0.027f, 0, 0.054f)) < 0.002f, "HLE 未应用各轴启用/反向控制，或控制系数被重复换轴");

// 设置挂起不能用逐轴写零代替，否则来源会变成实体设备并清除手机姿态控制。
Stage("suspend-resume");
ulong beforeSuspensionEpoch = gamepad.GetMotionSample().MotionEpoch;
NativeGamepadDriver.SuspendMotion(id);
var suspended = gamepad.GetMotionSample();
Require(suspended.IsMotionSuspended && suspended.MotionEpoch == beforeSuspensionEpoch + 1 && suspended.Gyroscope == Vector3.Zero,
    "挂起没有标记积分边界或清除角速度");
Require(suspended.Gravity == driverGravity && suspended.RotationFactors == new Vector3(-1, 0, 1) && suspended.ScreenOrientation == 0 && suspended.Accelerometer == driverGravity,
    "挂起丢失手机来源或残留平移输入");
NativeGamepadDriver.SuspendMotion(id);
Require(gamepad.GetMotionSample() == suspended, "重复挂起不是幂等操作");
npad.Update();
var held = npad.GetHLEMotionState();
Require(held.Gyroscope == Vector3.Zero && held.Rotation == controlled.Rotation && held.Orientation.AsSpan().SequenceEqual(controlled.Orientation.AsSpan()),
    "Npad 暂停轮询清空了受控姿态或继续积分");
// 与挂起后的静止值完全相同也必须恢复，不能被数据去重提前返回。
Submit(suspended);
Require(!gamepad.GetMotionSample().IsMotionSuspended && gamepad.GetMotionSample().MotionEpoch == suspended.MotionEpoch,
    "相同静止采样没有恢复或错误清除了暂停代数");
npad.Update();
var resumed = npad.GetHLEMotionState();
Require(resumed.Gyroscope == Vector3.Zero && resumed.Rotation == held.Rotation && resumed.Orientation.AsSpan().SequenceEqual(held.Orientation.AsSpan()),
    "恢复首帧没有保留游戏姿态");

// 暂停与恢复都发生在两次 Npad 轮询之间时，递增代数仍必须阻止旧时间段积分。
NativeGamepadDriver.SuspendMotion(id);
Submit(new GamepadMotionSample(driverGravity, new Vector3(10, 20, 30), driverGravity, new Vector3(-1, 0, 1), 0));
npad.Update();
var unobservedPause = npad.GetHLEMotionState();
Require(unobservedPause.Gyroscope == Vector3.Zero && unobservedPause.Rotation == held.Rotation && unobservedPause.Orientation.AsSpan().SequenceEqual(held.Orientation.AsSpan()),
    "没有轮询到暂停标记时丢失时间边界");
npad.Update();
Require(Vector3.Distance(npad.GetHLEMotionState().Gyroscope, new Vector3(-0.027f, 0, 0.054f)) < 0.002f,
    "暂停恢复后未继续输出受控旋转");

// 从完整 Native 样本穿过真实 Npad 到 HLE，验证转屏与暂停期间姿态变化不会延迟回拉。
Stage("orientation-boundary");
var beforeBoundary = npad.GetHLEMotionState();
Vector3 changedDriverGravity = Vector3.Normalize(new Vector3(0.5f, 0.5f, 0.7071f));
Submit(new GamepadMotionSample(changedDriverGravity, Vector3.Zero, changedDriverGravity, new Vector3(-1, 0, 1), 2));
npad.Update();
for (int index = 0; index < 30; index++)
{
    Thread.Sleep(1);
    npad.Update();
}
var afterOrientation = npad.GetHLEMotionState();
Require(afterOrientation.Orientation.AsSpan().SequenceEqual(beforeBoundary.Orientation.AsSpan()) && afterOrientation.Accelerometer == beforeBoundary.Accelerometer,
    "界面方向变化使 HLE 姿态或虚拟重力延迟回拉");
NativeGamepadDriver.SuspendMotion(id);
Submit(new GamepadMotionSample(Vector3.UnitX, Vector3.Zero, Vector3.UnitX, new Vector3(-1, 0, 1), 2));
npad.Update();
for (int index = 0; index < 30; index++)
{
    Thread.Sleep(1);
    npad.Update();
}
var afterChangedPause = npad.GetHLEMotionState();
Require(afterChangedPause.Orientation.AsSpan().SequenceEqual(beforeBoundary.Orientation.AsSpan()) && afterChangedPause.Accelerometer == beforeBoundary.Accelerometer,
    "暂停期间改变手机姿态后 HLE 仍持续运动");

// 两次方向切换在同一次轮询前完成，最终方向码相同也必须保留时间边界。
Stage("unobserved-orientation");
var beforeUnobservedOrientation = npad.GetHLEMotionState();
Submit(new GamepadMotionSample(Vector3.UnitX, new Vector3(100, 0, 0), Vector3.UnitX, Vector3.One, 3));
Submit(new GamepadMotionSample(Vector3.UnitX, new Vector3(100, 0, 0), Vector3.UnitX, Vector3.One, 2));
npad.Update();
var afterUnobservedOrientation = npad.GetHLEMotionState();
Require(afterUnobservedOrientation.Orientation.AsSpan().SequenceEqual(beforeUnobservedOrientation.Orientation.AsSpan()) && afterUnobservedOrientation.Gyroscope == Vector3.Zero,
    "未轮询到中间方向时丢失坐标基变化边界");
// 使用已配置手机运动源的真实 Npad 采样，验证左右姿态快照不产生逐帧堆数组。
Stage("allocation-free-snapshot");
for (int index = 0; index < 100; index++) _ = npad.GetHLEMotionState();
long allocationBefore = GC.GetAllocatedBytesForCurrentThread();
for (int index = 0; index < 10000; index++)
{
    _ = npad.GetHLEMotionState();
    _ = npad.GetHLEMotionState(true);
}
long motionAllocation = GC.GetAllocatedBytesForCurrentThread() - allocationBefore;
Require(motionAllocation == 0, $"Npad 姿态采样仍分配 {motionAllocation} 字节");
Console.WriteLine("NativeMotion.Tests: 完整采样、并发、手机元数据校验、HLE平移/旋转、转屏、暂停姿态变化及姿态采样零分配通过");
