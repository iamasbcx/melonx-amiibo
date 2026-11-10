using System.Numerics;

namespace Ryujinx.Input
{
    /// <summary>
    /// 一次完整的运动采样，三个向量采用同一驱动坐标系。
    /// 加速度与重力单位为 g，角速度单位为 deg/s；Gravity 为 null 表示设备未提供独立重力。
    /// 独立重力只参与姿态融合，不替代游戏可读取的真实总加速度。
    /// </summary>
    public readonly record struct GamepadMotionSample(Vector3 Accelerometer, Vector3 Gyroscope, Vector3? Gravity);

    /// <summary>
    /// 支持完整运动快照的设备接口。实现必须在同一同步边界内读取各向量，避免混用不同帧。
    /// </summary>
    public interface IMotionSampleGamepad
    {
        GamepadMotionSample GetMotionSample();
    }
}
