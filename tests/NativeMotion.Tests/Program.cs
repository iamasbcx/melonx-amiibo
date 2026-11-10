using System.Numerics;
using Ryujinx.Input;
using Ryujinx.Input.Native;

// 通过生产驱动的公共入口验证采样事务、输入源切换和重置，避免用替身重复实现锁逻辑。
using var driver = new NativeGamepadDriver();
nint id = new(0x2345);
NativeGamepadDriver.AttachGamepad("Motion regression", id);
var gamepad = (NativeGamepad)driver.GetGamepad(id.ToInt64().ToString("X"));
var first = new GamepadMotionSample(new Vector3(1, 2, 3), new Vector3(4, 5, 6), Vector3.UnitZ);
var second = new GamepadMotionSample(new Vector3(7, 8, 9), new Vector3(10, 11, 12), Vector3.UnitY);

void Submit(GamepadMotionSample sample) => NativeGamepadDriver.SetMotionSample(id, sample.Accelerometer, sample.Gyroscope, sample.Gravity!.Value);
void Require(bool success, string message)
{
    if (!success) throw new InvalidOperationException(message);
}

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
            if (sample != first && sample != second) Interlocked.Increment(ref inconsistent);
        }
    }));
Require(inconsistent == 0, "原子读取看到了混合帧");

// 相同角速度也必须清除重力，否则手机采样切换为实体手柄后会遗留融合来源。
Submit(first);
NativeGamepadDriver.SetMotionData(id, (int)MotionInputId.Gyroscope, first.Gyroscope.X, first.Gyroscope.Y, first.Gyroscope.Z);
Require(gamepad.GetMotionSample().Gravity is null, "逐轴角速度输入没有清除独立重力");
Submit(first);
NativeGamepadDriver.SetMotionData(id, (int)MotionInputId.Accelerometer, first.Accelerometer.X, first.Accelerometer.Y, first.Accelerometer.Z);
Require(gamepad.GetMotionSample().Gravity is null, "逐轴加速度输入没有清除独立重力");
Submit(second);
NativeGamepadDriver.ResetState(id);
Require(gamepad.GetMotionSample() == new GamepadMotionSample(Vector3.Zero, Vector3.Zero, null), "重置未清除完整运动状态");

Console.WriteLine("NativeMotion.Tests: 完整采样、并发原子读取、切换实体手柄与重置通过");
