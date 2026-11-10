using System.Numerics;

namespace Ryujinx.Input
{
    /// <summary>
    /// 一次完整的运动采样，三个向量采用同一驱动坐标系。
    /// 加速度与重力单位为 g，角速度单位为 deg/s；Gravity 为 null 表示设备未提供独立重力。
    /// 调用方可独立校正平移控制方向；独立重力用于物理融合和分离平移，游戏重力可随旋转控制重新合成。
    /// RotationFactors 为核心屏幕坐标的逐轴控制系数，只接受 -1、0、1，不跟随驱动换轴。
    /// 为 null 表示独立的实体手柄输入路径，不启用手机方向控制。
    /// MotionEpoch 在暂停边界递增；IsMotionSuspended 为 true 时冻结积分。两者与向量必须在同一锁内读写。
    /// 无暂停能力的设备使用 epoch 0；消费者检测边界后只重建时间基准，不清空当前游戏姿态。
    /// </summary>
    public readonly record struct GamepadMotionSample(Vector3 Accelerometer, Vector3 Gyroscope, Vector3? Gravity, Vector3? RotationFactors,
        ulong MotionEpoch = 0, bool IsMotionSuspended = false)
    {
        public static bool AreRotationFactorsValid(Vector3 factors) =>
            IsFactor(factors.X) && IsFactor(factors.Y) && IsFactor(factors.Z);

        private static bool IsFactor(float value) => value is -1f or 0f or 1f;
    }

    /// <summary>
    /// 支持完整运动快照的设备接口。实现必须在同一同步边界内读取各向量，避免混用不同帧。
    /// </summary>
    public interface IMotionSampleGamepad
    {
        GamepadMotionSample GetMotionSample();
    }
}
