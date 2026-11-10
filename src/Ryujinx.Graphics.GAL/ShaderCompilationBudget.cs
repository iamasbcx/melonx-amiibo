using System;

namespace Ryujinx.Graphics.GAL
{
    /// <summary>宿主翻译、模块及管线预热共用的并发预算；绘制等待策略由调用方独立决定。</summary>
    public static class ShaderCompilationBudget
    {
        public static int BackgroundWorkers => GetBackgroundWorkers(Environment.ProcessorCount);

        /// <summary>保留 CPU 给模拟线程；每个阶段使用 1～2 个普通 worker，另留按需通道。</summary>
        public static int GetBackgroundWorkers(int processorCount) => Math.Clamp(processorCount / 4, 1, 2);
    }
}
