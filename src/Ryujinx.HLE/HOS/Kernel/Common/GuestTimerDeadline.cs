using System;

namespace Ryujinx.HLE.HOS.Kernel.Common
{
    /// <summary>
    /// 内核超时统一保存在来宾计数器时间轴上；倍率变化只重算宿主等待，不修改来宾截止点。
    /// 纯整数换算向上取整，避免提前唤醒；超大期限饱和而不回绕成已到期。
    /// </summary>
    internal static class GuestTimerDeadline
    {
        public static long Create(ulong counter, ulong frequency, long timeoutNanoseconds)
        {
            ArgumentOutOfRangeException.ThrowIfZero(frequency);
            Int128 duration = ((Int128)Math.Max(0, timeoutNanoseconds) * frequency + 999_999_999) / 1_000_000_000;
            return Saturate((Int128)counter + duration);
        }

        /// <summary>把剩余来宾 tick 换成宿主绝对期限；参数频率为每秒 tick 数，倍率百分比 100 表示 1X。</summary>
        public static long ToHost(long deadline, ulong counter, ulong frequency, long hostNow, long hostFrequency, long tickScalar)
        {
            ArgumentOutOfRangeException.ThrowIfZero(frequency);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(hostFrequency);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(tickScalar);
            Int128 remaining = (Int128)deadline - counter;
            if (remaining <= 0) return hostNow;
            Int128 denominator = (Int128)frequency * tickScalar;
            Int128 duration = (remaining * hostFrequency * 100 + denominator - 1) / denominator;
            return Saturate((Int128)hostNow + duration);
        }

        private static long Saturate(Int128 value) => value >= long.MaxValue ? long.MaxValue : (long)value;
    }
}
