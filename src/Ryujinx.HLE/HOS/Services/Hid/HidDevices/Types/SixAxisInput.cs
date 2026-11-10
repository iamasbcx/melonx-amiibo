using System.Numerics;
using Ryujinx.Common.Memory;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    public struct SixAxisInput
    {
        public PlayerIndex PlayerId;
        public Vector3 Accelerometer;
        public Vector3 Gyroscope;
        public Vector3 Rotation;
        // 姿态随采样按值拥有；下一帧更新不会覆盖已交给 HID 或测试保存的快照。
        public Array9<float> Orientation;
    }
}
