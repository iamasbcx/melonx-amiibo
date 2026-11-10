using System;
using System.Threading;

namespace Ryujinx.Library
{
    /// <summary>
    /// 每个游戏窗口独占一个门控：普通统计默认关闭且最多 5Hz，首帧通知独立于显示开关。
    /// 时间参数统一使用 Stopwatch 时钟；UI 线程可切换开关，GPU 线程负责发布。
    /// </summary>
    internal sealed class StatisticsPublishGate
    {
        private readonly Lock _lock = new();
        private readonly long _interval;
        private bool _enabled;
        private bool _started;
        private bool _hasPublished;
        private long _lastPublished;

        public StatisticsPublishGate(long timestampFrequency)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(timestampFrequency);
            _interval = Math.Max(1, (timestampFrequency + 4) / 5);
        }

        public void SetEnabled(bool enabled)
        {
            lock (_lock) _enabled = enabled;
        }

        public bool TryPublishFirstFrame(long timestamp)
        {
            lock (_lock)
            {
                if (_started) return false;
                _started = true;
                _hasPublished = true;
                _lastPublished = timestamp;
                return true;
            }
        }

        public bool TryPublishStatistics(long timestamp)
        {
            lock (_lock)
            {
                if (!_enabled || (_hasPublished && timestamp - _lastPublished < _interval)) return false;
                _hasPublished = true;
                _lastPublished = timestamp;
                return true;
            }
        }
    }
}
