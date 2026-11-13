using Ryujinx.Common;
using Ryujinx.Common.PreciseSleep;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.HLE.HOS.Services.SurfaceFlinger;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using GuestSwitch = Ryujinx.HLE.Switch;

internal static class TurboIntegrationTests
{
    public static void Run(Action<bool, string> check)
    {
        // 不启动原生图形或线程：在真实合成循环的等待边界暂停，让倍率转换与空 buffer 分支可重复验证。
        using CompositorFixture fixture = new();
        long normal = Stopwatch.Frequency / 60;
        foreach (long scalar in new long[] { 100, 200, 2000, 100, 110, 140, 650, 100 })
        {
            fixture.Device.TickScalar = scalar;
            fixture.RunUntilSleep(0);
            long period = fixture.Field<long>("_ticksPerFrame");
            double actualRatio = normal / (double)period;
            check(Math.Abs(period - normal / (scalar / 100.0)) <= 1,
                $"空 buffer 下切换到 {scalar / 100.0:0.0}x 后，真实合成循环仍使用旧周期（normal={normal}, period={period}, ratio={actualRatio:0.000000}）");
            check(fixture.Field<long>("_tickScalar") == scalar, "空 buffer 时倍率缓存没有更新");
        }

        // SwapInterval=2 必须保留隔一次 VSync 合成一次的规则；不能把它误写为每次 VSync 都合成。
        fixture.SetSwapInterval(2);
        fixture.Device.TickScalar = 2000;
        fixture.RunUntilSleep(0);
        long turboPeriod = fixture.Field<long>("_ticksPerFrame");
        fixture.RunUntilSleep(turboPeriod);
        check(fixture.Field<int>("_swapInterval") == 2 && fixture.Field<int>("_swapIntervalDelay") == 1,
            "20x 时 swap interval=2 的隔帧计数未保留");
        fixture.RunUntilSleep(turboPeriod);
        check(fixture.Field<int>("_swapIntervalDelay") == 0, "第二个 VSync 没有推进 swap interval 延迟");

        fixture.SetSwapInterval(0);
        fixture.RunUntilSleep(0);
        check(fixture.LastSleepDeadline > 0 && fixture.LastSleepDeadline < Stopwatch.Frequency / 1000,
            "真实 Unbounded 空队列等待把 20x 向上取整成了 1ms");
        fixture.SetSwapInterval(2);
        fixture.RunUntilSleep(0);

        // 从真实 RefreshTiming 传播到真实 Window，验证 Turbo 时可消费所有已就绪帧但只呈现一帧。
        Window window = fixture.Device.Gpu.Window;
        fixture.Device.Gpu.PhysicalMemoryRegistry.Add(1, new PhysicalMemory());
        int acquired = 0;
        int released = 0;
        int callbacks = 0;
        void Enqueue(int count, bool ready = true)
        {
            for (int index = 0; index < count; index++)
            {
                check(window.EnqueueFrameThreadSafe(1, 0, 1, 1, 4, true, 1, Format.R8G8B8A8Unorm, 4,
                    default, (_, _) => acquired++, _ => released++, new object()), "测试帧未入生产队列");
                if (ready) window.SignalFrameReady();
            }
        }
        Enqueue(3);
        check(window.PresentLoop(() => callbacks++), "Turbo 丢帧路径未呈现首帧");
        check(acquired == 1 && released == 3 && callbacks == 1 && !window.IsFrameAvailable,
            "Turbo 没有释放所有已就绪帧，或仍把所有帧提交到宿主");

        // 不得跨过来宾 GPU fence 就绪门：未 signal 的队列项保持原样，直到生产路径收到 signal。
        Enqueue(1, ready: false);
        check(!window.PresentLoop(() => callbacks++) && released == 3,
            "Turbo 丢帧路径错误释放了未就绪的来宾帧");
        fixture.Device.TickScalar = 100;
        fixture.RunUntilSleep(0);
        window.SignalFrameReady();
        Enqueue(2);
        check(window.PresentLoop(() => callbacks++), "退出 Turbo 后未恢复正常呈现");
        check(acquired == 4 && released == 6 && callbacks == 4,
            "退出 Turbo 后仍沿用宿主丢帧，或资源释放数不平衡");
    }

    private sealed class StopAtSleep : Exception { }

    /// <summary>
    /// 仅绕过启动线程的构造函数，按生产字段初始化设备和同步资源；运行的仍是完整 HandleComposition。
    /// 等待替身在第一次等待时抛出专用异常，不模拟系统定时器精度。资源所有权归本夹具，Dispose 逐一释放。
    /// </summary>
    private sealed class CompositorFixture : IDisposable
    {
        private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
        private readonly SurfaceFlinger _compositor;
        private readonly AutoResetEvent _timerEvent = new(false);
        private readonly AutoResetEvent _nextFrameEvent = new(false);
        public GuestSwitch Device { get; } = new();
        public long LastSleepDeadline { get; private set; }

        public CompositorFixture()
        {
            _compositor = (SurfaceFlinger)RuntimeHelpers.GetUninitializedObject(typeof(SurfaceFlinger));
            SetField("_device", Device);
            SetField("_event", _timerEvent);
            SetField("_nextFrameEvent", _nextFrameEvent);
            SetField("_lock", Activator.CreateInstance(typeof(Lock))!);
            FieldInfo layers = typeof(SurfaceFlinger).GetField("_layers", PrivateInstance)!;
            layers.SetValue(_compositor, Activator.CreateInstance(layers.FieldType));
            SetField("_spinTicks", Stopwatch.Frequency / 500);
            SetField("_1msTicks", Stopwatch.Frequency / 1000);
            SetSwapInterval(1);
        }

        public T Field<T>(string name) => (T)typeof(SurfaceFlinger).GetField(name, PrivateInstance)!.GetValue(_compositor)!;
        private void SetField(string name, object value) => typeof(SurfaceFlinger).GetField(name, PrivateInstance)!.SetValue(_compositor, value);
        public void SetSwapInterval(int interval) => typeof(SurfaceFlinger).GetMethod("UpdateSwapInterval", PrivateInstance)!.Invoke(_compositor, [interval]);

        public void RunUntilSleep(long elapsedTicks)
        {
            int reads = 0;
            Stopwatch watchdog = Stopwatch.StartNew();
            PerformanceCounter.ReadTicks = () =>
            {
                // 如果回归导致合成循环不再到达等待边界，明确失败而不是无限挂住 CI。
                if (reads > 10_000 || watchdog.Elapsed > TimeSpan.FromSeconds(2))
                {
                    throw new InvalidOperationException("合成循环未在限定步骤内到达等待边界");
                }

                return reads++ == 0 ? 0 : elapsedTicks;
            };
            PreciseSleepHelper.Wait = timePoint =>
            {
                LastSleepDeadline = timePoint;
                throw new StopAtSleep();
            };
            try
            {
                typeof(SurfaceFlinger).GetMethod("HandleComposition", PrivateInstance)!.Invoke(_compositor, null);
                throw new InvalidOperationException("合成循环未到达等待边界");
            }
            catch (TargetInvocationException exception) when (exception.InnerException is StopAtSleep) { }
            finally
            {
                SetField("_isRunning", false);
                PerformanceCounter.ReadTicks = () => 0;
                PreciseSleepHelper.Wait = _ => { };
            }
        }

        public void Dispose()
        {
            _compositor.Dispose();
            _timerEvent.Dispose();
            _nextFrameEvent.Dispose();
        }
    }
}
