using ARMeilleure.State;
using System;

namespace Ryujinx.Cpu
{
    /// <summary>
    /// Tick source interface.
    /// </summary>
    public interface ITickSource : ICounter
    {
        public const long RealityTickScalar = 100;

        /// <summary>
        /// Time elapsed since the counter was created.
        /// </summary>
        TimeSpan ElapsedTime { get; }

        /// <summary>
        /// Clock tick scalar, in percent points (100 = 1.0).
        /// </summary>
        long TickScalar { get; set; }

        /// <summary>时钟是否正在推进；暂停期间来宾定时器不得消耗超时预算。</summary>
        bool IsRunning { get; }

        /// <summary>
        /// 倍率、暂停或恢复已生效后通知等待方重算宿主期限。
        /// 回调在时钟锁外同步执行；订阅方负责退出时取消订阅。
        /// </summary>
        event Action ClockChanged;

        /// <summary>
        /// Time elapsed since the counter was created, in seconds.
        /// </summary>
        double ElapsedSeconds { get; }

        /// <summary>
        /// Stops counting.
        /// </summary>
        void Suspend();

        /// <summary>
        /// Resumes counting after a call to <see cref="Suspend"/>.
        /// </summary>
        void Resume();
    }
}
