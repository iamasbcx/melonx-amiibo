using System;

namespace Ryujinx.Audio.Renderer.Dsp
{
    /// <summary>按绝对纳秒期限计算阻塞等待，向上取整避免每毫秒轮询，唤醒后仍校验期限。</summary>
    internal static class AudioDeadlineWait
    {
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
