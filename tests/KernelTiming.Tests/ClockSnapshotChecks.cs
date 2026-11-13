using Ryujinx.Cpu;

/// <summary>验证生产时钟的不可变快照、单读者单调性与锁外通知；不替换计数器或线程实现。</summary>
internal static class ClockSnapshotChecks
{
    public static int Run()
    {
        int checks = 0;
        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
            checks++;
        }

        TickSource paused = new(19_200_000);
        int notifications = 0;
        paused.ClockChanged += () => notifications++;
        paused.Suspend();
        ulong frozenCounter = paused.Counter;
        TimeSpan frozenTime = paused.ElapsedTime;
        double frozenSeconds = paused.ElapsedSeconds;
        paused.Suspend();
        Check(notifications == 1, "重复暂停不能发送时钟通知");
        foreach (long scalar in new long[] { 110, 2000, 100, 650 })
        {
            paused.TickScalar = scalar;
            for (int i = 0; i < 1000; i++)
            {
                Check(paused.Counter == frozenCounter && paused.ElapsedTime == frozenTime && paused.ElapsedSeconds == frozenSeconds,
                    "暂停期间读取或换倍率改变了时钟");
            }
        }
        int beforeResume = notifications;
        paused.Resume();
        paused.Resume();
        Check(paused.IsRunning && notifications == beforeResume + 1, "重复恢复不能发送时钟通知");
        Check(paused.Counter >= frozenCounter, "恢复后计数器倒退");

        // 通知中等待另一个线程修改同一时钟，若通知仍在写锁内会发生锁等待死结。
        TickSource reentrant = new(19_200_000);
        int entered = 0;
        int nestedNotifications = 0;
        reentrant.ClockChanged += () =>
        {
            Interlocked.Increment(ref nestedNotifications);
            _ = reentrant.Counter;
            if (Interlocked.Exchange(ref entered, 1) != 0) return;

            Thread nestedWriter = new(() =>
            {
                reentrant.Suspend();
                reentrant.TickScalar = 110;
                reentrant.Resume();
            }) { IsBackground = true };
            nestedWriter.Start();
            Check(nestedWriter.Join(TimeSpan.FromSeconds(2)), "ClockChanged 持有时钟写锁，跨线程重入被阻塞");
        };
        reentrant.TickScalar = 2000;
        Check(nestedNotifications == 4 && reentrant.IsRunning && reentrant.TickScalar == 110, "时钟通知重入丢失状态或通知");

        // 两个独立写者分别切换暂停和倍率；只有当前线程读取并检查自身观察序列。
        TickSource concurrent = new(19_200_000);
        using ManualResetEventSlim start = new(false);
        int remainingWriters = 2;
        Thread pauseWriter = new(() =>
        {
            start.Wait();
            for (int i = 0; i < 100_000; i++)
            {
                concurrent.Suspend();
                concurrent.Resume();
            }
            Interlocked.Decrement(ref remainingWriters);
        }) { IsBackground = true };
        Thread scalarWriter = new(() =>
        {
            start.Wait();
            for (int i = 0; i < 100_000; i++) concurrent.TickScalar = (i & 1) == 0 ? 2000 : 100;
            Interlocked.Decrement(ref remainingWriters);
        }) { IsBackground = true };
        pauseWriter.Start();
        scalarWriter.Start();
        ulong previousCounter = concurrent.Counter;
        long previousTimeTicks = concurrent.ElapsedTime.Ticks;
        int regressions = 0;
        int reads = 0;
        start.Set();
        while (Volatile.Read(ref remainingWriters) != 0)
        {
            ulong counter = concurrent.Counter;
            long timeTicks = concurrent.ElapsedTime.Ticks;
            if (counter < previousCounter || timeTicks < previousTimeTicks) regressions++;
            previousCounter = counter;
            previousTimeTicks = timeTicks;
            reads++;
        }
        pauseWriter.Join();
        scalarWriter.Join();
        Check(reads > 0, "并发时钟测试未产生读取样本");
        Check(regressions == 0, $"暂停/恢复与倍率并发切换导致单读者时钟倒退 {regressions} 次");
        Console.WriteLine($"ClockSnapshotChecks: {reads} concurrent reads, no regressions; paused state and reentrant notifications passed");
        return checks;
    }
}
