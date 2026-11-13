// 测试中的外设边界：来宾设备提供可控倍率，宿主时钟与等待由测试逐步推进。
// SurfaceFlinger 的更新顺序、缓存、SwapInterval 状态及 Window 的队列逻辑均使用生产实现。
namespace Ryujinx.Common
{
    public static class PerformanceCounter
    {
        public static Func<long> ReadTicks { get; set; } = () => 0;
        public static long ElapsedTicks => ReadTicks();
        public static long TicksPerMillisecond => System.Diagnostics.Stopwatch.Frequency / 1000;
    }
}

namespace Ryujinx.Common.Logging
{
    public enum LogClass { SurfaceFlinger }
    public static class Logger
    {
        public static StubLog? Info => null;
        public static StubLog? Error => null;
    }
    public sealed class StubLog { public void Print(LogClass logClass, string message) { } }
}

namespace Ryujinx.Common.PreciseSleep
{
    public static class PreciseSleepHelper
    {
        public static Action<long> Wait { get; set; } = _ => { };
        public static void SleepUntilTimePoint(EventWaitHandle handle, long timePoint) => Wait(timePoint);
        public static void SpinWaitUntilTimePoint(long timePoint) => Wait(timePoint);
    }
}

namespace Ryujinx.HLE
{
    using Ryujinx.Common.Configuration;
    using Ryujinx.Graphics.Gpu;
    public sealed class Switch
    {
        public long TickScalar { get; set; } = 100;
        public long TargetVSyncInterval { get; set; } = 60;
        public VSyncMode VSyncMode { get; set; }
        public GpuContext Gpu { get; } = new();
        public StubHorizon System { get; } = new();
        public StubConfiguration Configuration { get; } = new();
        public StubStatistics Statistics { get; } = new();
    }
    public sealed class StubHorizon
    {
        public int VsyncCount { get; private set; }
        public void SignalVsync() => VsyncCount++;
    }
    public sealed class StubConfiguration { public AspectRatio AspectRatio { get; set; } }
    public sealed class StubStatistics { public void RecordGameFrameTime() { } }
}

namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvMap
{
    public sealed class NvMapHandle { public ulong Address; }
    public static class NvMapDeviceFile
    {
        public static NvMapHandle GetMapFromHandle(ulong owner, int handle) => new();
    }
}

namespace Ryujinx.HLE.HOS.Services.Vi { public enum ResultCode { Success, InvalidArguments, InvalidValue, PermissionDenied } }

namespace Ryujinx.HLE.HOS.Services.SurfaceFlinger
{
    using Ryujinx.Graphics.Gpu;
    public interface IBinder { }
    public interface IGraphicBufferProducer : IBinder { }
    public interface IConsumerListener { }
    public enum LayerState { ManagedClosed, ManagedOpened, Stray }
    public enum Status { Success, NoBufferAvailaible, InvalidOperation }
    [Flags] public enum NativeWindowTransform { FlipX = 1, FlipY = 2 }
    public enum ColorFormat { A8B8G8R8, X8B8G8R8, R5G6B5, A8R8G8B8, A4B4G4R4 }
    public readonly record struct Rect(int Left, int Right, int Top, int Bottom);
    public sealed class BufferQueueProducer : IGraphicBufferProducer { }
    public sealed class BufferQueueConsumer { }
    public sealed class BufferQueueCore
    {
        public event Action? BufferQueued { add { } remove { } }
        public void PrepareForExit() { }
    }
    public static class BufferQueue
    {
        public static BufferQueueCore CreateBufferQueue(Switch device, ulong pid, out BufferQueueProducer producer, out BufferQueueConsumer consumer)
        {
            producer = new();
            consumer = new();
            return new();
        }
    }
    public sealed class BufferItemConsumer
    {
        public BufferItemConsumer(Switch device, BufferQueueConsumer consumer, int a, int b, bool c, IConsumerListener listener) { }
        public Status AcquireBuffer(out BufferItem item, int timeout) { item = new(); return Status.NoBufferAvailaible; }
        public void ReleaseBuffer(BufferItem item, ref AndroidFence fence) { }
    }
    public static class HOSBinderDriverServer
    {
        public static int RegisterBinderObject(IBinder binder) => 1;
        public static void UnregisterBinderObject(int id) { }
    }
    public sealed class BufferItem
    {
        public int SwapInterval;
        public StubGraphicBufferReference GraphicBuffer { get; } = new();
        public Rect Crop;
        public NativeWindowTransform Transform;
        public AndroidFence Fence;
    }
    public sealed class StubGraphicBufferReference { public StubGraphicBuffer Object { get; } = new(); }
    public sealed class StubGraphicBuffer
    {
        public int Width = 1, Height = 1;
        public StubBuffer Buffer { get; } = new();
    }
    public sealed class StubBuffer
    {
        public int NvMapId;
        public StubSurface[] Surfaces { get; } = [new()];
    }
    public sealed class StubSurface
    {
        public int NvMapHandle, BlockHeightLog2;
        public ulong Offset;
        public ColorFormat ColorFormat;
    }
    public struct AndroidFence
    {
        public int FenceCount;
        public static AndroidFence NoFence => default;
        public void RegisterCallback(GpuContext context, Action<object?> callback) => callback(null);
        public void WaitForever(GpuContext context) { }
    }
}
