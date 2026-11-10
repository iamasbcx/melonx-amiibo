using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    public struct TouchPoint
    {
        public TouchAttribute Attribute;
        // 宿主触点标识不随数组压缩而变化；鼠标模拟单指时使用默认值 0。
        public uint FingerId;
        public uint X;
        public uint Y;
        public uint DiameterX;
        public uint DiameterY;
        public uint Angle;
    }
}
