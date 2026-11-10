#nullable enable
using System;
using System.Threading;

namespace Ryujinx.Library
{
    /// <summary>
    /// SDL 应用级同步派发入口。串行提交只借用一个完成事件及固定队列委托，避免每 10ms 构造闭包。
    /// 宿主队列必须独立于调用线程执行；执行异常仍由宿主处理，finally 保证提交线程不会遗留等待。
    /// 本对象随 SDL 应用级驱动存活，不在单局窗口退出时销毁。
    /// </summary>
    internal sealed class HostActionDispatcher
    {
        private readonly object _submitLock = new();
        private readonly AutoResetEvent _completed = new(false);
        private readonly Action<Action> _enqueue;
        private readonly Action _runPending;
        private Action? _pending;

        public HostActionDispatcher(Action<Action> enqueue)
        {
            _enqueue = enqueue;
            _runPending = RunPending;
        }

        public void Invoke(Action action)
        {
            ArgumentNullException.ThrowIfNull(action);
            lock (_submitLock)
            {
                _pending = action;
                _enqueue(_runPending);
                _completed.WaitOne();
            }
        }

        private void RunPending()
        {
            try { (_pending ?? throw new InvalidOperationException("No host action is pending."))(); }
            finally
            {
                _pending = null;
                _completed.Set();
            }
        }
    }
}
