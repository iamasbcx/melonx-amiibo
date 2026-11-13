using Ryujinx.Common;
using Ryujinx.Cpu;
using System;
using System.Threading;

namespace Ryujinx.Audio.Renderer.Dsp
{
    /// <summary>计算音频节拍与绝对期限等待；正常播放阻塞等待，快进保留亚毫秒精度。</summary>
    internal static class AudioDeadlineWait
    {
        /// <summary>返回一次 240 样本 DSP 更新对应的真实时间；倍率单位为百分比，结果至少 1 ns。</summary>
        public static long NanosecondsPerUpdate(long tickScalar)
        {
            if (tickScalar <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(tickScalar));
            }

            return Math.Max(1, Constants.AudioProcessorMaxUpdateTimeTarget * ITickSource.RealityTickScalar / tickScalar);
        }

        /// <summary>
        /// 管理线程等待快进音频期限；剩余整毫秒可阻塞，最后不足 1 ms 的部分短暂自旋。
        /// 每轮检查停止与暂停事件，不使用会自动 Sleep(1) 的 SpinWait，避免限制 20X 的 0.25 ms 节拍。
        /// </summary>
        public static void WaitUntil(ManualResetEvent stopEvent, ManualResetEvent pauseEvent, long deadline)
        {
            while (true)
            {
                long now = PerformanceCounter.ElapsedNanoseconds;
                if (now >= deadline || stopEvent.WaitOne(0) || (pauseEvent != null && !pauseEvent.WaitOne(0)))
                {
                    return;
                }

                long wholeMilliseconds = (deadline - now) / 1_000_000;
                if (wholeMilliseconds > 0)
                {
                    if (stopEvent.WaitOne((int)Math.Min(wholeMilliseconds, int.MaxValue)))
                    {
                        return;
                    }
                }
                else
                {
                    Thread.SpinWait(32);
                }
            }
        }

        public static int MillisecondsUntil(long now, long deadline)
        {
            if (now >= deadline)
            {
                return 0;
            }

            ulong remaining = unchecked((ulong)deadline - (ulong)now);
            return (int)Math.Min((remaining - 1) / 1_000_000 + 1, int.MaxValue);
        }
    }
}
