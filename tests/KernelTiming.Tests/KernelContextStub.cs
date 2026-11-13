using Ryujinx.Cpu;

namespace Ryujinx.HLE.HOS.Kernel
{
    // 仅替代真实内核的进程/内存创建；计时器读取生产ITickSource，并使用同一临界区锁契约。
    internal sealed class KernelContext(ITickSource tickSource)
    {
        public ITickSource TickSource { get; } = tickSource;
        public CriticalSectionStub CriticalSection { get; } = new();
    }

    internal sealed class CriticalSectionStub
    {
        public object Lock { get; } = new();
    }
}
