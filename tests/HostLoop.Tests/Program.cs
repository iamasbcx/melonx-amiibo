using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using Ryujinx.Input;
using Ryujinx.Input.HLE;
using Ryujinx.Library;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Numerics;
using System.Reflection;

int checks = 0;
void Require(bool condition, string message)
{
    checks++;
    if (!condition) throw new InvalidOperationException(message);
}

// 使用生产调度门验证暂停、队列唤醒、恢复与停止；宽松时间上界仅用于发现死锁。
using (HostLoopScheduler scheduler = new())
{
    Require(HostLoopScheduler.InputHeartbeatMilliseconds == 8, "输入心跳不是约定的 8ms");
    Stopwatch timer = Stopwatch.StartNew();
    int idleIterations = 0;
    while (timer.ElapsedMilliseconds < 96)
    {
        scheduler.ShouldUpdateInput();
        scheduler.WaitForWork();
        idleIterations++;
    }
    Require(idleIterations <= 20, "空闲输入仍有接近 1ms 的忙轮询");
    scheduler.SetPaused(true);
    scheduler.WaitForWork(); // 消费暂停状态切换事件。
    Require(!scheduler.CanUpdateInput, "暂停仍允许 HID 采样");
    using ManualResetEventSlim inputAwake = new();
    Thread inputWaiter = new(() => { scheduler.WaitForWork(); inputAwake.Set(); });
    inputWaiter.Start();
    Require(!inputAwake.Wait(35), "暂停状态仍按输入心跳唤醒");
    scheduler.SignalControl();
    Require(inputAwake.Wait(2000), "控制队列无法唤醒暂停循环");
    inputWaiter.Join();
    Require(!scheduler.CanUpdateInput, "处理控制队列意外恢复输入");

    using ManualResetEventSlim renderAwake = new();
    bool renderAllowed = false;
    Thread renderWaiter = new(() => { renderAllowed = scheduler.WaitForRender(); renderAwake.Set(); });
    renderWaiter.Start();
    Require(!renderAwake.Wait(35), "暂停未阻止 GPU 循环");
    scheduler.SetPaused(false);
    Require(renderAwake.Wait(2000) && renderAllowed && scheduler.CanUpdateInput, "恢复未放开 GPU/输入门");
    renderWaiter.Join();
    scheduler.SetPaused(true);
    using ManualResetEventSlim stopped = new();
    Thread stoppedWaiter = new(() => { renderAllowed = scheduler.WaitForRender(); stopped.Set(); });
    stoppedWaiter.Start();
    scheduler.Stop();
    Require(stopped.Wait(2000) && !renderAllowed && !scheduler.WaitForWork(), "退出没有释放暂停等待");
    stoppedWaiter.Join();
}

HostLoopScheduler disposedScheduler = new();
disposedScheduler.Stop();
disposedScheduler.Dispose();
disposedScheduler.SignalControl();
disposedScheduler.SignalInput();
disposedScheduler.SetPaused(false);
disposedScheduler.Stop();
Require(!disposedScheduler.CanUpdateInput, "迟到事件重新打开已释放调度器");

using (HostLoopScheduler clocked = new(1000))
{
    Require(clocked.TryUpdateInput(0), "初次输入未立即采样");
    for (long tick = 1; tick < 8; tick++)
    {
        clocked.SignalControl();
        Require(!clocked.TryUpdateInput(tick), "控制任务触发额外 HID 更新");
    }
    Require(clocked.GetWaitTimeout(7) == 1 && clocked.TryUpdateInput(8), "控制任务推迟绝对心跳");
    clocked.SignalInput();
    Require(clocked.TryUpdateInput(10), "真实输入未立即采样");
    Require(clocked.GetWaitTimeout(12) == 4 && clocked.TryUpdateInput(16), "真实输入重置了心跳相位");
    Require(clocked.TryUpdateInput(40) && !clocked.TryUpdateInput(40) && clocked.GetWaitTimeout(40) == 8, "延迟唤醒导致补帧忙循环");
    clocked.SetPaused(true);
    clocked.SignalInput();
    Require(!clocked.TryUpdateInput(100) && clocked.GetWaitTimeout(100) == Timeout.Infinite, "暂停仍按输入心跳轮询");
    clocked.SetPaused(false);
    Require(clocked.TryUpdateInput(100) && clocked.GetWaitTimeout(100) == 8, "恢复没有重建心跳");
}

// 固定委托派发的零分配与真实跨线程串行提交；超时仅用于明确暴露死锁。
HostActionDispatcher inlineDispatcher = new(action => action());
Action noOperation = () => { };
for (int index = 0; index < 20; index++) inlineDispatcher.Invoke(noOperation);
long dispatcherBefore = GC.GetAllocatedBytesForCurrentThread();
for (int index = 0; index < 1000; index++) inlineDispatcher.Invoke(noOperation);
Require(GC.GetAllocatedBytesForCurrentThread() == dispatcherBefore, "宿主每次同步派发仍分配闭包");
using (BlockingCollection<Action> queue = new())
{
    HostActionDispatcher dispatcher = new(queue.Add);
    int executed = 0;
    Task consumer = Task.Run(() => { foreach (Action action in queue.GetConsumingEnumerable()) action(); });
    Action increment = () => Interlocked.Increment(ref executed);
    Task[] submissions = Enumerable.Range(0, 4).Select(_ => Task.Run(() =>
    {
        for (int index = 0; index < 50; index++) dispatcher.Invoke(increment);
    })).ToArray();
    Require(Task.WaitAll(submissions, TimeSpan.FromSeconds(5)) && executed == 200, "并发控制任务丢失完成通知");
    queue.CompleteAdding();
    Require(consumer.Wait(2000), "控制消费者未结束");
}

// 时间完全可控：关闭、首帧、限速、重复开启及新游戏不会依赖真实帧率。
StatisticsPublishGate statistics = new(1000);
Require(!statistics.TryPublishStatistics(0), "普通统计没有默认关闭");
Require(statistics.TryPublishFirstFrame(10), "隐藏 HUD 丢失首帧 started");
Require(!statistics.TryPublishFirstFrame(20), "首帧通知重复发送");
statistics.SetEnabled(true);
Require(!statistics.TryPublishStatistics(209) && statistics.TryPublishStatistics(210), "统计未限制到 5Hz");
statistics.SetEnabled(false);
Require(!statistics.TryPublishStatistics(5000), "隐藏 HUD 仍发布统计");
statistics.SetEnabled(true);
Require(statistics.TryPublishStatistics(5001), "重新显示 HUD 未恢复统计");
statistics.SetEnabled(true);
Require(!statistics.TryPublishStatistics(5002), "重复启用绕过限速");
Require(new StatisticsPublishGate(1000).TryPublishFirstFrame(0), "新游戏没有独立首帧通知");

NativeViewportState viewport = new(1280, 720);
Require(viewport.SetNativeSize(390, 844), "UI 初始尺寸未保存");
viewport.InitializeFallback(1280, 720);
Require(viewport.Size == new Size(390, 844), "窗口创建覆盖 UI 已提交的尺寸");
Require(!viewport.SetNativeSize(390, 844), "重复尺寸没有去重");
viewport.InitializeFallback(1280, 720);
Require(viewport.Size == new Size(390, 844), "第二局同尺寸丢失缓存");
Require(!viewport.SetNativeSize(0, 0) && !viewport.SetNativeSize(-1, 390) && viewport.Size == new Size(390, 844), "无效布局覆盖有效尺寸");
Require(viewport.SetNativeSize(844, 390) && viewport.Size == new Size(844, 390), "旋转尺寸未更新");

NativeTouchState touches = new();
Span<TouchSnapshot> snapshot = stackalloc TouchSnapshot[ITouchScreen.MaxTouches];
Require(touches.Begin(10, new(100, 200)) && touches.Begin(20, new(300, 400)), "多点触摸未记录");
int count = touches.CopyTo(snapshot);
Require(count == 2 && snapshot[0].Id == 10 && snapshot[1].Id == 20, "触点 Id 丢失");
Require(!touches.Move(999, Vector2.One) && !touches.Begin(99, new(float.NaN, 1)), "非法触摸进入状态");
TouchScreenFrameBuilder frames = new();
Span<TouchPoint> frame = stackalloc TouchPoint[2 * ITouchScreen.MaxTouches];
int frameCount = frames.BuildFrame(snapshot[..count], new Size(400, 800), frame, out int activeCount);
Require(frameCount == 2 && activeCount == 2 && frame[0].Attribute == TouchAttribute.Start && frame[0].X == 320 && frame[0].Y == 180, "开始触摸或画面坐标缩放错误");
touches.End(10);
count = touches.CopyTo(snapshot);
frameCount = frames.BuildFrame(snapshot[..count], new Size(400, 800), frame, out activeCount);
Require(activeCount == 1 && frame[0].FingerId == 20 && frame[0].Attribute == TouchAttribute.None, "释放第一指导致第二指重新开始");
Require(frameCount == 2 && frame[1].FingerId == 10 && frame[1].Attribute == TouchAttribute.End, "结束触点错误");
frameCount = frames.BuildFrame(ReadOnlySpan<TouchSnapshot>.Empty, new Size(400, 800), frame, out activeCount);
Require(frameCount == 1 && frame[0].FingerId == 20 && frame[0].Attribute == TouchAttribute.End, "失焦未释放所有触点");
Require(frames.BuildFrame(ReadOnlySpan<TouchSnapshot>.Empty, Size.Empty, frame, out _) == 0, "空闲触摸残留");
touches.Clear();
for (int index = 0; index < ITouchScreen.MaxTouches; index++) Require(touches.Begin(index, new(index, index)), "有效触点被截断");
Require(!touches.Begin(100, Vector2.Zero) && touches.CopyTo(snapshot) == ITouchScreen.MaxTouches, "16 点容量边界错误");
touches.Clear();
touches.Begin(1, Vector2.One);
ConcurrentQueue<Exception> concurrencyErrors = new();
Thread producer = new(() =>
{
    try { for (int index = 0; index < 20000; index++) touches.Move(1, new Vector2(index, -index)); }
    catch (Exception exception) { concurrencyErrors.Enqueue(exception); }
});
producer.Start();
while (producer.IsAlive)
{
    touches.CopyTo(snapshot);
    // 初始化值可能是 (1,1)，之后每个原子采样必须满足 Y=-X。
    if (snapshot[0].Position != Vector2.One && snapshot[0].Position.Y != -snapshot[0].Position.X)
        concurrencyErrors.Enqueue(new InvalidOperationException("触摸坐标撕裂"));
}
producer.Join();
Require(concurrencyErrors.IsEmpty, "并发触摸快照不一致");

// 回归无循环分配；先预热实际方法，计数仅包含生产触摸采样和状态转换。
for (int index = 0; index < 100; index++)
{
    count = touches.CopyTo(snapshot);
    frames.BuildFrame(snapshot[..count], new Size(400, 800), frame, out _);
}
long beforeAllocation = GC.GetAllocatedBytesForCurrentThread();
for (int index = 0; index < 10000; index++)
{
    touches.Move(1, new(index % 300, index % 600));
    count = touches.CopyTo(snapshot);
    frames.BuildFrame(snapshot[..count], new Size(400, 800), frame, out _);
}
long touchAllocation = GC.GetAllocatedBytesForCurrentThread() - beforeAllocation;
Require(touchAllocation == 0, $"触摸采样/转换分配 {touchAllocation} 字节");

using (NativeTouchDriver driver = new(HideCursorMode.Never))
{
    Require(ReferenceEquals(driver.GetGamepad("0"), driver.GetGamepad("0")), "NativeMouse 仍逐帧新建");
    int notifications = 0;
    void InputChanged() => notifications++;
    NativeTouchDriver.OnInputUpdated += InputChanged;
    unsafe
    {
        delegate* unmanaged<float, float, int, void> begin = &NativeTouchDriver.TouchBeganAtPoint;
        delegate* unmanaged<float, float, int, void> move = &NativeTouchDriver.TouchMovedAtPoint;
        delegate* unmanaged<int, void> end = &NativeTouchDriver.TouchEndedForIndex;
        begin(12, 13, 7);
        move(14, 15, 7);
        move(14, 15, 7);
        end(7);
    }
    NativeTouchDriver.OnInputUpdated -= InputChanged;
    Require(notifications == 3, "触摸 ABI 缺少唤醒或相同状态重复唤醒");
    Require(driver.CopyTouches(snapshot) == 0, "触摸 ABI 未抬起");
}

KeyboardStateSnapshot keyboard = default;
keyboard.SetPressed(Key.A, true);
KeyboardStateSnapshot retainedKeyboard = keyboard;
keyboard.SetPressed(Key.A, false);
keyboard.SetPressed(Key.F12, true);
Require(retainedKeyboard.IsPressed(Key.A) && !retainedKeyboard.IsPressed(Key.F12), "键盘值快照被后续更新覆盖");
Require(!keyboard.IsPressed((Key)(-1)) && !keyboard.IsPressed(Key.Count) && (int)Key.Count <= 256, "键盘快照边界错误");
SixAxisInput motion = default;
motion.Orientation[0] = 1;
SixAxisInput retainedMotion = motion;
motion.Orientation[0] = 0.5f;
Require(retainedMotion.Orientation[0] == 1 && motion.Orientation[0] == 0.5f, "姿态值快照被后续更新覆盖");

// 使用真实 ThreadedRenderer 和无设备 IRenderer 代理验证外部 Dispose 的等待顺序，不调用 Vulkan。
for (int attempt = 0; attempt < 8; attempt++)
{
    IRenderer backend = DispatchProxy.Create<IRenderer, RendererStub>();
    ThreadedRenderer renderer = new(backend);
    using ManualResetEventSlim gpuFinished = new();
    Exception? renderError = null;
    Thread renderThread = new(() =>
    {
        try { renderer.RunLoop(() => gpuFinished.Set()); }
        catch (Exception exception) { renderError = exception; }
    });
    renderThread.Start();
    Require(gpuFinished.Wait(2000), "测试 GPU 回调未启动");
    Task disposeTask = Task.Run(renderer.Dispose);
    Require(disposeTask.Wait(TimeSpan.FromSeconds(5)), "后端释放死锁");
    Require(renderThread.Join(2000) && renderError == null && ((RendererStub)backend).Disposed, "后端循环/事件未按序释放");
}
Console.WriteLine($"HostLoop.Tests: {checks} checks passed; touch hot path allocation={touchAllocation} bytes.");

public class RendererStub : DispatchProxy
{
    public bool Disposed { get; private set; }
    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        if (targetMethod!.Name == nameof(IDisposable.Dispose)) Disposed = true;
        return targetMethod.ReturnType != typeof(void) && targetMethod.ReturnType.IsValueType ? Activator.CreateInstance(targetMethod.ReturnType) : null;
    }
}
