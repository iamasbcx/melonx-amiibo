using System;
using System.Threading;

namespace Ryujinx.Library
{
    /// <summary>
    /// 宿主输入与 GPU 循环的等待门。事件立即唤醒输入，8ms 心跳补偿只能轮询的设备和震动队列。
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

        public bool CanUpdateInput => !_paused && !_stopped;

        public void Signal()
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
                _paused = paused;
                if (paused) _renderAvailable.Reset();
                else _renderAvailable.Set();
                _workAvailable.Set();
            }
        }

        public bool WaitForWork()
        {
            if (_stopped) return false;
            _workAvailable.WaitOne(_paused ? Timeout.Infinite : InputHeartbeatMilliseconds);
            return !_stopped;
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
