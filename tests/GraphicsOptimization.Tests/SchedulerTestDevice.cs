// 调度器测试只替换 Vulkan 设备/cache 边界，任务队列、优先级及退出逻辑使用生产实现。
namespace Silk.NET.Vulkan
{
    internal readonly record struct PipelineCache(int Index);
}

namespace Ryujinx.Graphics.Vulkan
{
    internal sealed class PipelineCacheManager
    {
        public int Completed;
        public Silk.NET.Vulkan.PipelineCache GetWorkerCache(int index) => new(index);
        public void NotifyWorkerPipelineCreated(int index) => Interlocked.Increment(ref Completed);
    }
}
