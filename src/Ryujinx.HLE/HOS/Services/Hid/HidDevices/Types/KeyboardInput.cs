using Ryujinx.Common.Memory;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    public struct KeyboardInput
    {
        public int Modifier;
        // 256 个按键位随快照按值复制，避免每次宿主输入采样分配数组。
        public Array4<ulong> Keys;
    }
}
