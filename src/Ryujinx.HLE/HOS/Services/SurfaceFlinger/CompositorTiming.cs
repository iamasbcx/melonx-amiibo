using System;

namespace Ryujinx.HLE.HOS.Services.SurfaceFlinger
{
    /// <summary>
    /// 集中计算 SurfaceFlinger 的宿主等待周期，避免快进倍率改变后继续使用旧缓存。
    /// 该类只做计时换算，不持有线程或设备状态，便于独立验证边界条件。
    /// </summary>
    internal static class CompositorTiming
    {
        /// <summary>真实时间倍率，100 表示 1.0 倍。</summary>
        public const long RealityTickScalar = 100;

        /// <summary>关闭游戏 VSync 时使用的基础宿主刷新率。</summary>
        public const long UnboundedBaseFrameRate = 60;

        /// <summary>
        /// 按来宾倍率把目标刷新周期换算为宿主 Stopwatch tick。
        /// 参数使用和 Switch.TickScalar 相同的百分比单位。
        /// </summary>
        /// <param name="hostFrequency">Stopwatch 每秒 tick 数，必须为正数。</param>
        /// <param name="targetFrameRate">目标刷新率，必须为正数。</param>
        /// <param name="tickScalar">来宾时间倍率百分比，低于 1.0 倍时按 1.0 倍计算。</param>
        /// <returns>至少为一个宿主 tick 的等待周期。</returns>
        public static long CalculateTicksPerFrame(long hostFrequency, long targetFrameRate, long tickScalar)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(hostFrequency);
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(targetFrameRate);

            tickScalar = Math.Max(RealityTickScalar, tickScalar);

            // 先在 128 位中计算，避免 hostFrequency * 100 溢出或提前截断基础周期。
            UInt128 ticks = (UInt128)(ulong)hostFrequency * (ulong)RealityTickScalar /
                (ulong)targetFrameRate / (ulong)tickScalar;

            return Math.Max(1, (long)ticks);
        }

        /// <summary>
        /// 计算无 VSync 模式在没有新 buffer 时的最大等待时间。
        /// 等待仍以宿主时间为基准，但随来宾倍率缩短，避免固定 17 ms 把快进限制在约 1 倍。
        /// </summary>
        public static long CalculateUnboundedWaitTicks(long hostFrequency, long tickScalar)
        {
            return CalculateTicksPerFrame(hostFrequency, UnboundedBaseFrameRate, tickScalar);
        }

        /// <summary>快进时启用宿主丢帧路径，避免呈现队列反过来限制来宾线程。</summary>
        public static bool IsTurbo(long tickScalar)
        {
            return tickScalar > RealityTickScalar;
        }
    }
}
