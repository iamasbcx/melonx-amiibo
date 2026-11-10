using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Library
{
    /// <summary>
    /// 宿主输入与 GPU 循环的等待门。真实输入立即采样，控制任务只唤醒队列，8ms 绝对心跳负责轮询来源。
    /// 暂停只关闭输入采样和 GPU 门，控制队列仍可唤醒；退出必须释放两个等待门。
    /// 所有线程均可 Signal/SetPaused/Stop，所有循环退出后由窗口唯一拥有者 Dispose。
    /// </summary>
    internal sealed class HostLoopScheduler : IDisposable
    {
        internal const int InputHeartbeatMilliseconds = 8;
        private readonly Lock _stateLock = new();
        private readonly AutoResetEvent _workAvailable = new(false);
        private readonly ManualResetEvent _renderAvailable = new(true);
        private volatile bool _paused;
        private volatile bool _stopped;
        private bool _disposed;
        private bool _inputPending = true;
        private bool _hasDeadline;
        private long _nextHeartbeat;
        private readonly long _frequency;
        private readonly long _heartbeatTicks;

        public HostLoopScheduler() : this(Stopwatch.Frequency) { }

        internal HostLoopScheduler(long frequency)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(frequency);
            _frequency = frequency;
            _heartbeatTicks = Math.Max(1, (frequency * InputHeartbeatMilliseconds + 999) / 1000);
        }

        public bool CanUpdateInput => !_paused && !_stopped;

        public void SignalInput()
        {
            lock (_stateLock)
            {
                if (_disposed || _stopped) return;
                _inputPending = true;
                _workAvailable.Set();
            }
        }

        public void SignalControl()
        {
            lock (_stateLock)
            {
                // 事件调用方可能已取得旧委托快照，解除订阅后仍允许迟到通知安全返回。
                if (!_disposed) _workAvailable.Set();
            }
        }

        public void SetPaused(bool paused)
        {
            lock (_stateLock)
            {
                if (_disposed || _stopped) return;
                if (_paused && !paused)
                {
                    _inputPending = true;
                    _hasDeadline = false;
                }
                _paused = paused;
                if (paused) _renderAvailable.Reset();
                else _renderAvailable.Set();
                _workAvailable.Set();
            }
        }

        public bool WaitForWork()
        {
            if (_stopped) return false;
            _workAvailable.WaitOne(GetWaitTimeout(Stopwatch.GetTimestamp()));
            return !_stopped;
        }

        public bool ShouldUpdateInput() => TryUpdateInput(Stopwatch.GetTimestamp());

        internal bool TryUpdateInput(long timestamp)
        {
            lock (_stateLock)
            {
                if (_paused || _stopped) return false;
                bool heartbeatDue = !_hasDeadline || timestamp >= _nextHeartbeat;
                if (!_inputPending && !heartbeatDue) return false;
                _inputPending = false;
                if (!_hasDeadline) _nextHeartbeat = timestamp + _heartbeatTicks;
                else if (heartbeatDue) _nextHeartbeat += ((timestamp - _nextHeartbeat) / _heartbeatTicks + 1) * _heartbeatTicks;
                _hasDeadline = true;
                return true;
            }
        }

        internal int GetWaitTimeout(long timestamp)
        {
            lock (_stateLock)
            {
                if (_stopped) return 0;
                if (_paused) return Timeout.Infinite;
                if (_inputPending || !_hasDeadline || timestamp >= _nextHeartbeat) return 0;
                long remaining = _nextHeartbeat - timestamp;
                return (int)Math.Min(int.MaxValue, (remaining * 1000 + _frequency - 1) / _frequency);
            }
        }

        public bool WaitForRender()
        {
            if (_stopped) return false;
            _renderAvailable.WaitOne();
            return !_stopped;
        }

        public void Stop()
        {
            lock (_stateLock)
            {
                if (_disposed) return;
                _stopped = true;
                _workAvailable.Set();
                _renderAvailable.Set();
            }
        }

        public void Dispose()
        {
            lock (_stateLock)
            {
                if (_disposed) return;
                _stopped = true;
                _disposed = true;
                _workAvailable.Dispose();
                _renderAvailable.Dispose();
            }
        }
    }
}
