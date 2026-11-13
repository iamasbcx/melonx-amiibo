using Ryujinx.Cpu;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Common;

// 直接编译生产时钟、内核计时线程及队列；仅隔离无关的进程/内存初始化。
int checks = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    checks++;
}

const ulong frequency = 19_200_000;
long deadline = GuestTimerDeadline.Create(0, frequency, 1_000_000_000);
Check(deadline == 19_200_000, "一秒来宾期限换算错误");
foreach (long scalar in new long[] { 100, 110, 140, 200, 650, 2000, 100 })
{
    long hostDeadline = GuestTimerDeadline.ToHost(deadline, 0, frequency, 500, 1_000_000_000, scalar);
    long expected = 500 + (100_000_000_000L + scalar - 1) / scalar;
    Check(hostDeadline == expected, $"{scalar}% 没有按剩余来宾时间缩放等待");
}
Check(GuestTimerDeadline.ToHost(deadline, frequency / 2, frequency, 500, 1_000_000_000, 2000) == 25_000_500,
    "中途启用20X必须只缩短剩余半秒");
Check(GuestTimerDeadline.ToHost(deadline, frequency / 2, frequency, 500, 1_000_000_000, 100) == 500_000_500,
    "松开必须恢复剩余半秒，不能重启完整超时");
Check(GuestTimerDeadline.ToHost(deadline, frequency, frequency, 500, 1_000_000_000, 2000) == 500,
    "已到期不能重新等待");
Check(GuestTimerDeadline.Create(10, frequency, 1) == 11, "不足一个来宾tick不得提前到期");
Check(GuestTimerDeadline.Create((ulong)long.MaxValue - 1, frequency, long.MaxValue) == long.MaxValue,
    "超大截止点必须饱和");
Check(GuestTimerDeadline.ToHost(long.MaxValue, 0, frequency, 500, 1_000_000_000, 100) == long.MaxValue,
    "超大宿主期限不能回绕");

TickSource clock = new(frequency);
int notifications = 0;
clock.ClockChanged += () => { notifications++; _ = clock.TickScalar; };
clock.Suspend();
ulong frozen = clock.Counter;
clock.TickScalar = 2000;
Check(clock.Counter == frozen && !clock.IsRunning, "暂停时换倍率不能跳变计数器");
clock.TickScalar = 2000;
Check(notifications == 2, "同倍率不应再次发通知");
clock.TickScalar = 100;
Check(clock.Counter == frozen, "恢复1X不能倒退或突增时钟");
clock.Resume();
Check(notifications == 4 && clock.IsRunning, "恢复通知或状态丢失");

// 真实等待：已注册的3秒期限在20X后应迅速唤醒，不得继续沿用3秒墙钟。
using (KTimeManager timers = new(new KernelContext(clock)))
{
    TimerCallback accelerated = new();
    timers.ScheduleFutureInvocation(accelerated, 3_000_000_000);
    clock.TickScalar = 2000;
    Check(accelerated.Fired.Wait(1500), "在途内核等待未响应20X变化");
    Check(accelerated.Count == 1, "到期重复调用");

    // 暂停后在同一时间轴注册，确保回1X时没有残留的快进宿主期限。
    clock.Suspend();
    TimerCallback normal = new();
    timers.ScheduleFutureInvocation(normal, 500_000_000);
    clock.TickScalar = 100;
    Check(!normal.Fired.Wait(80), "暂停期间消耗了来宾超时");
    clock.Resume();
    Check(!normal.Fired.Wait(100), "恢复1X仍沿用20X期限");
    Check(normal.Fired.Wait(1500), "恢复后定时器未重新启动");

    clock.Suspend();
    TimerCallback cancelled = new();
    timers.ScheduleFutureInvocation(cancelled, 1_000_000);
    timers.UnscheduleFutureInvocation(cancelled);
    clock.TickScalar = 2000;
    clock.Resume();
    Check(!cancelled.Fired.Wait(80), "取消节点仍被倍率通知触发");
}
// Dispose后即使订阅委托曾被捕获，也不能继续访问已释放等待资源。
clock.TickScalar = 100;
clock.Suspend();
clock.Resume();

// 停止与注册/取消并发时不访问已释放事件；Dispose 返回后的节点不能触发回调。
clock.Suspend();
KTimeManager closing = new(new KernelContext(clock));
TimerCallback afterStop = new();
Task scheduling = Task.Run(() =>
{
    for (int index = 0; index < 1000; index++)
    {
        closing.ScheduleFutureInvocation(afterStop, 1_000_000);
        closing.UnscheduleFutureInvocation(afterStop);
    }
});
Task disposing = Task.Run(closing.Dispose);
Check(Task.WaitAll(new[] { scheduling, disposing }, 3000), "并发退出或调度发生死锁");
closing.Dispose();
closing.ScheduleFutureInvocation(afterStop, 1);
closing.UnscheduleFutureInvocation(afterStop);
clock.TickScalar = 2000;
clock.Resume();
Check(!afterStop.Fired.Wait(30), "Dispose返回后仍执行TimeUp");
checks += ClockSnapshotChecks.Run();
Console.WriteLine($"KernelTimingTests: {checks} checks passed (guest deadlines, scaling, in-flight waits, pause, cancellation)");

sealed class TimerCallback : IKFutureSchedulerObject
{
    public ManualResetEventSlim Fired { get; } = new();
    public int Count;
    public void TimeUp()
    {
        Interlocked.Increment(ref Count);
        Fired.Set();
    }
}
