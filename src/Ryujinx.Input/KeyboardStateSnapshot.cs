using System.Runtime.CompilerServices;
using Ryujinx.Common.Memory;

namespace Ryujinx.Input
{
    /// <summary>
    /// 键盘状态的独立值快照；固定 256 位覆盖 Key 枚举，不保留设备或共享数组引用。
    /// </summary>
    public struct KeyboardStateSnapshot
    {
        private Array4<ulong> _keys;

        /// <summary>
        /// 写入有效按键位；超出当前枚举的输入不改变快照。
        /// </summary>
        public void SetPressed(Key key, bool pressed)
        {
            if ((uint)key >= (uint)Key.Count) return;
            ulong mask = 1UL << ((int)key & 63);
            ref ulong bits = ref _keys[(int)key >> 6];
            if (pressed) bits |= mask;
            else bits &= ~mask;
        }

        /// <summary>
        /// Check if a given key is pressed.
        /// </summary>
        /// <param name="key">The key</param>
        /// <returns>True if the given key is pressed</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool IsPressed(Key key) => (uint)key < (uint)Key.Count && (_keys[(int)key >> 6] & (1UL << ((int)key & 63))) != 0;
    }
}
