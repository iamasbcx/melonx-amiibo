using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Cpu
{
    public class TickSource : ITickSource
    {
        private sealed class TickSnapshot
        {
            public long HostTicks { get; }
            public long ElapsedTicks { get; }
            public long TickScalar { get; }
            public bool IsRunning { get; }

            public TickSnapshot(long hostTicks, long elapsedTicks, long tickScalar, bool isRunning)
            {
                HostTicks = hostTicks;
                ElapsedTicks = elapsedTicks;
                TickScalar = tickScalar;
                IsRunning = isRunning;
            }

            public long GetElapsedTicks(long hostTicks)
            {
                if (!IsRunning)
                {
                    return ElapsedTicks;
                }

                Int128 elapsed = ElapsedTicks + (Int128)(hostTicks - HostTicks) * TickScalar / ITickSource.RealityTickScalar;
                return (long)Int128.Min(elapsed, long.MaxValue);
            }
        }

        private readonly double _hostTickFreq;
        private readonly object _tickScalarLock = new();
        private TickSnapshot _snapshot;
        // 奇数表示状态转换正在计算；读者检测到奇数或版本变化时重试，避免跨越转换点外推旧倍率。
        private long _snapshotRevision;

        /// <inheritdoc/>
        public ulong Frequency { get; }

        /// <inheritdoc/>
        public ulong Counter => (ulong)(ElapsedSeconds * Frequency);

        public bool IsRunning => Volatile.Read(ref _snapshot).IsRunning;

        public event Action ClockChanged;


        public long TickScalar
        {
            get => Volatile.Read(ref _snapshot).TickScalar;
            set
            {
                ArgumentOutOfRangeException.ThrowIfNegativeOrZero(value);
                lock (_tickScalarLock)
                {
                    TickSnapshot snapshot = Volatile.Read(ref _snapshot);

                    if (snapshot.TickScalar == value)
                    {
                        return;
                    }

                    Publish(snapshot, value, snapshot.IsRunning);
                }

                ClockChanged?.Invoke();
            }
        }

        private long ElapsedTicks
        {
            get
            {
                while (true)
                {
                    long revision = Volatile.Read(ref _snapshotRevision);
                    if ((revision & 1) != 0)
                    {
                        Thread.Yield();
                        continue;
                    }

                    TickSnapshot snapshot = Volatile.Read(ref _snapshot);
                    long elapsed = snapshot.GetElapsedTicks(Stopwatch.GetTimestamp());

                    // 写者在捕获转换时间前先置奇数版本；二次检查覆盖读者跨越转换点的窗口。
                    // ARM64 也必须完成快照/宿主时间读取后再检查版本，不能只依赖 x64 的读顺序。
                    Thread.MemoryBarrier();
                    if (revision == Volatile.Read(ref _snapshotRevision))
                    {
                        return elapsed;
                    }
                }
            }
        }

        /// <inheritdoc/>

        public TimeSpan ElapsedTime => Stopwatch.GetElapsedTime(0, ElapsedTicks);

        /// <inheritdoc/>
        public double ElapsedSeconds => ElapsedTicks * _hostTickFreq;

        public TickSource(ulong frequency)
        {
            Frequency = frequency;
            _hostTickFreq = 1.0 / Stopwatch.Frequency;
            _snapshot = new TickSnapshot(Stopwatch.GetTimestamp(), 0, ITickSource.RealityTickScalar, true);
            _snapshotRevision = 0;
        }

        /// <inheritdoc/>
        public void Suspend() => SetRunning(false);

        /// <inheritdoc/>
        public void Resume() => SetRunning(true);

        /// <summary>暂停与恢复原子发布完整快照；通知始终在写锁外调用，允许订阅方读取或切换时钟。</summary>
        private void SetRunning(bool running)
        {
            lock (_tickScalarLock)
            {
                TickSnapshot snapshot = Volatile.Read(ref _snapshot);
                if (snapshot.IsRunning == running) return;

                Publish(snapshot, snapshot.TickScalar, running);
            }

            ClockChanged?.Invoke();
        }

        /// <summary>
        /// 在版本写入临界区内捕获宿主转换点，再发布不可变快照。
        /// 读者因此不会用转换前的倍率外推到转换后的时间。
        /// </summary>
        private void Publish(TickSnapshot previous, long tickScalar, bool isRunning)
        {
            Interlocked.Increment(ref _snapshotRevision);
            try
            {
                long hostTicks = Stopwatch.GetTimestamp();
                long elapsedTicks = previous.GetElapsedTicks(hostTicks);
                Volatile.Write(ref _snapshot, new TickSnapshot(hostTicks, elapsedTicks, tickScalar, isRunning));
            }
            finally
            {
                Interlocked.Increment(ref _snapshotRevision);
            }
        }
    }
}
