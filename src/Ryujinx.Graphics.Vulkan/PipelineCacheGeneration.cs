using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>缓存修改、成功持久化和合并分别计代；保存失败及 merge 都不能误清除待保存状态。</summary>
    internal sealed class PipelineCacheGeneration
    {
        private long _generation;
        private long _saved;
        private long _merged;

        public PipelineCacheGeneration(bool loadedSnapshot)
        {
            // 已加载的 worker 快照未必包含在主缓存里，首次 merge 仍然必需。
            _merged = loadedSnapshot ? -1 : 0;
        }

        public long Current => Interlocked.Read(ref _generation);
        public bool IsDirty => Current != Interlocked.Read(ref _saved);
        public bool NeedsMerge => Current != Interlocked.Read(ref _merged);
        public void MarkChanged() => Interlocked.Increment(ref _generation);
        public void MarkSaved(long generation) => Interlocked.Exchange(ref _saved, generation);
        public void MarkMerged(long generation) => Interlocked.Exchange(ref _merged, generation);
    }
}
