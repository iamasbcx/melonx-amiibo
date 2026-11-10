using Ryujinx.Common;
using Ryujinx.Common.PreciseSleep;
using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.HLE.HOS.Kernel.Common
{
    class KTimeManager : IDisposable
    {
        public static readonly long DefaultTimeIncrementNanoseconds = ConvertGuestTicksToNanoseconds(2);

        private readonly KernelContext _context;
        private readonly ScheduledObjectQueue<IKFutureSchedulerObject> _waitingObjects;
        private IPreciseSleepEvent _waitEvent;
        private bool _keepRunning;
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

            Thread work = new(WaitAndCheckScheduledObjects)
            {
                Name = "HLE.TimeManager",
            };

            if (OperatingSystem.IsIOS())
            {
                work.Priority = ThreadPriority.AboveNormal;
            }

            work.Start();
        }

        public void ScheduleFutureInvocation(IKFutureSchedulerObject schedulerObj, long timeout)
        {
            long startTime = PerformanceCounter.ElapsedTicks;
            long timePoint = startTime + ConvertNanosecondsToHostTicks(timeout);

            if (timePoint < startTime)
            {
                timePoint = long.MaxValue;
            }

            timePoint = _waitEvent.AdjustTimePoint(timePoint, timeout);

            lock (_context.CriticalSection.Lock)
            {
                if (_waitingObjects.Add(schedulerObj, timePoint))
                {
                    Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                    _waitEvent.Signal();
                }
            }
        }

        public void UnscheduleFutureInvocation(IKFutureSchedulerObject schedulerObj)
        {
            lock (_context.CriticalSection.Lock)
            {
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
                    lock (_context.CriticalSection.Lock)
                    {
                        Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 0);

                        next = _waitingObjects.Head;
                    }

                    if (next != null)
                    {
                        long timePoint = PerformanceCounter.ElapsedTicks;

                        if (next.TimePoint > timePoint)
                        {
                            if (!_waitEvent.SleepUntil(next.TimePoint))
                            {
                                PreciseSleepHelper.SpinWaitUntilTimePoint(next.TimePoint, ref _enforceWakeupFromSpinWait);
                            }
                        }

                        bool timeUp = PerformanceCounter.ElapsedTicks >= next.TimePoint;

                        if (timeUp)
                        {
                            lock (_context.CriticalSection.Lock)
                            {
                                if (_waitingObjects.TryRemove(next))
                                {
                                    next.Object.TimeUp();
                                }
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
            _keepRunning = false;
            _waitEvent?.Signal();
        }
    }
}
