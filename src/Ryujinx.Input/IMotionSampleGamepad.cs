using System.Numerics;

namespace Ryujinx.Input
{
    /// <summary>
    /// 一次完整的运动采样，三个向量采用同一驱动坐标系。
    /// 加速度与重力单位为 g，角速度单位为 deg/s；手机须同时提供 Gravity、RotationFactors、ScreenOrientation。
    /// 独立重力用于分离平移；游戏重力随相对姿态合成，不参与手机视角纠偏。实体设备三项均为 null。
    /// RotationFactors 为核心屏幕坐标的逐轴控制系数，只接受 -1、0、1，不跟随驱动换轴。
    /// ScreenOrientation 为 0 portrait、1 portraitUpsideDown、2 landscapeLeft、3 landscapeRight；改变时只重建时间基准。
    /// MotionEpoch 在暂停及坐标基变化时递增；IsMotionSuspended 为 true 时冻结积分。所有元数据与向量在同一锁内读写。
    /// 无暂停能力的设备使用 epoch 0；消费者检测边界后只重建时间基准，不清空当前游戏姿态。
    /// </summary>
    public readonly record struct GamepadMotionSample(Vector3 Accelerometer, Vector3 Gyroscope, Vector3? Gravity, Vector3? RotationFactors,
        int? ScreenOrientation = null, ulong MotionEpoch = 0, bool IsMotionSuspended = false)
    {
        public static bool AreRotationFactorsValid(Vector3 factors) =>
            IsFactor(factors.X) && IsFactor(factors.Y) && IsFactor(factors.Z);

        private static bool IsFactor(float value) => value is -1f or 0f or 1f;

        public static bool IsPhoneSampleValid(Vector3 acceleration, Vector3 gyroscope, Vector3 gravity, Vector3 factors, int orientation) =>
            IsFinite(acceleration) && IsFinite(gyroscope) && IsFinite(gravity) && gravity.LengthSquared() > 0f &&
            float.IsFinite(gravity.LengthSquared()) && AreRotationFactorsValid(factors) && orientation is >= 0 and <= 3;

        private static bool IsFinite(Vector3 value) => float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);
    }

    /// <summary>
    /// 支持完整运动快照的设备接口。实现必须在同一同步边界内读取各向量，避免混用不同帧。
    /// </summary>
    public interface IMotionSampleGamepad
    {
        GamepadMotionSample GetMotionSample();
    }
}
