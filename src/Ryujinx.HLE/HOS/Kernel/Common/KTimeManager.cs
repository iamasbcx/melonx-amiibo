using Ryujinx.Common;
using Ryujinx.Common.PreciseSleep;
using System;
using System.Threading;

namespace Ryujinx.HLE.HOS.Kernel.Common
{
    class KTimeManager : IDisposable
    {
        public static readonly long DefaultTimeIncrementNanoseconds = ConvertGuestTicksToNanoseconds(2);

        private readonly KernelContext _context;
        private readonly ScheduledObjectQueue<IKFutureSchedulerObject> _waitingObjects;
        private readonly IPreciseSleepEvent _waitEvent;
        private readonly Thread _workerThread;
        private volatile bool _keepRunning;
        private long _enforceWakeupFromSpinWait;

        private const long NanosecondsPerSecond = 1000000000L;
        private const long NanosecondsPerMillisecond = 1000000L;

        public KTimeManager(KernelContext context)
        {
            _context = context;
            _waitingObjects = new();
            // 在工作线程启动前创建事件，首次注册不能依赖另一个线程已执行到 using。
            _waitEvent = PreciseSleepHelper.CreateEvent();
            _keepRunning = true;
            _context.TickSource.ClockChanged += OnClockChanged;

            _workerThread = new(WaitAndCheckScheduledObjects)
            {
                Name = "HLE.TimeManager",
            };

            if (OperatingSystem.IsIOS())
            {
                _workerThread.Priority = ThreadPriority.AboveNormal;
            }

            _workerThread.Start();
        }

        public void ScheduleFutureInvocation(IKFutureSchedulerObject schedulerObj, long timeout)
        {
            // 保存来宾期限，让按下/松开快进时已经注册的 SleepThread 和同步等待也随倍率调整。
            long timePoint = GuestTimerDeadline.Create(_context.TickSource.Counter, _context.TickSource.Frequency, timeout);

            lock (_context.CriticalSection.Lock)
            {
                if (!_keepRunning) return;
                if (_waitingObjects.Add(schedulerObj, timePoint))
                {
                    Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                    _waitEvent.Signal();
                }
            }
        }

        /// <summary>与队列更新使用同一锁，避免读出旧倍率后丢失唤醒；停止后不再访问等待资源。</summary>
        private void OnClockChanged()
        {
            lock (_context.CriticalSection.Lock)
            {
                if (!_keepRunning) return;
                Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                _waitEvent.Signal();
            }
        }

        public void UnscheduleFutureInvocation(IKFutureSchedulerObject schedulerObj)
        {
            lock (_context.CriticalSection.Lock)
            {
                if (!_keepRunning) return;
                if (_waitingObjects.Remove(schedulerObj))
                {
                    Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                    _waitEvent.Signal();
                }
            }
        }

        private void WaitAndCheckScheduledObjects()
        {
            ScheduledObjectQueue<IKFutureSchedulerObject>.Entry next;

            using (_waitEvent)
            {
                while (_keepRunning)
                {
                    long hostDeadline = 0;
                    lock (_context.CriticalSection.Lock)
                    {
                        if (!_keepRunning) break;
                        Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 0);

                        // 暂停时保留全部来宾期限，由恢复通知唤醒，不循环消耗暂停预算。
                        next = _context.TickSource.IsRunning ? _waitingObjects.Head : null;
                        if (next != null)
                        {
                            hostDeadline = GuestTimerDeadline.ToHost(next.TimePoint,
                                _context.TickSource.Counter, _context.TickSource.Frequency,
                                PerformanceCounter.ElapsedTicks, PerformanceCounter.TicksPerSecond,
                                _context.TickSource.TickScalar);
                        }
                    }

                    if (next != null)
                    {
                        long timePoint = PerformanceCounter.ElapsedTicks;

                        if (hostDeadline > timePoint)
                        {
                            // 快进的亚毫秒尾段不能走 iOS 的 1ms 低功耗回退，否则 20X 又被固定下限截断。
                            bool turboTail = _context.TickSource.TickScalar > 100 &&
                                hostDeadline - timePoint < PerformanceCounter.TicksPerMillisecond;
                            if (turboTail || !_waitEvent.SleepUntil(hostDeadline))
                            {
                                PreciseSleepHelper.SpinWaitUntilTimePoint(hostDeadline, ref _enforceWakeupFromSpinWait);
                            }
                        }

                        lock (_context.CriticalSection.Lock)
                        {
                            // 宿主等待可能因取消或换倍率提前返回，必须重新核对来宾时间和节点身份。
                            if (_keepRunning && (Int128)_context.TickSource.Counter >= next.TimePoint && _waitingObjects.TryRemove(next))
                            {
                                next.Object.TimeUp();
                            }
                        }
                    }
                    else
                    {
                        _waitEvent.Sleep();
                    }
                }
            }
        }

        public static long ConvertNanosecondsToMilliseconds(long time)
        {
            time /= NanosecondsPerMillisecond;

            if ((ulong)time > int.MaxValue)
            {
                return int.MaxValue;
            }

            return time;
        }

        public static long ConvertMillisecondsToNanoseconds(long time)
        {
            return time * NanosecondsPerMillisecond;
        }

        public static long ConvertNanosecondsToHostTicks(long ns)
        {
            long nsDiv = ns / NanosecondsPerSecond;
            long nsMod = ns % NanosecondsPerSecond;
            long tickDiv = PerformanceCounter.TicksPerSecond / NanosecondsPerSecond;
            long tickMod = PerformanceCounter.TicksPerSecond % NanosecondsPerSecond;

            long baseTicks = (nsMod * tickMod + PerformanceCounter.TicksPerSecond - 1) / NanosecondsPerSecond;
            return (nsDiv * tickDiv) * NanosecondsPerSecond + nsDiv * tickMod + nsMod * tickDiv + baseTicks;
        }

        public static long ConvertGuestTicksToNanoseconds(long ticks)
        {
            return (long)Math.Ceiling(ticks * (1000000000.0 / 19200000.0));
        }

        public static long ConvertHostTicksToTicks(long time)
        {
            return (long)((time / (double)PerformanceCounter.TicksPerSecond) * 19200000.0);
        }

        public void Dispose()
        {
            lock (_context.CriticalSection.Lock)
            {
                if (_keepRunning)
                {
                    _keepRunning = false;
                    _context.TickSource.ClockChanged -= OnClockChanged;
                    Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                    _waitEvent.Signal();
                }
            }

            // 等待线程离开 using 作用域后才释放事件；不能让 Dispose 返回后仍访问已释放句柄。
            if (Thread.CurrentThread != _workerThread)
            {
                _workerThread.Join();
            }
        }
    }
}
