using System;

namespace Ryujinx.Graphics.Gpu.Image
{
    /// <summary>将已请求的 slice 紧凑装入有限读回缓冲区，不扩大 guest 的读取范围。</summary>
    internal static class TextureReadbackBatch
    {
        public const int MaxBytes = 16 * 1024 * 1024;
        public const int MaxSlices = 1024;

        /// <summary>验证容量、格式块对齐和整数边界；失败时调用方继续使用逐 slice 路径。</summary>
        public static bool TryAppend(int currentSize, int sliceSize, int alignment, out int offset, out int totalSize)
        {
            offset = totalSize = 0;
            if (currentSize < 0 || currentSize > MaxBytes || sliceSize <= 0 || alignment <= 0 ||
                (alignment & (alignment - 1)) != 0 || alignment > MaxBytes) return false;
            int aligned = (currentSize + alignment - 1) & -alignment;
            if (aligned > MaxBytes || sliceSize > MaxBytes - aligned) return false;
            offset = aligned;
            totalSize = aligned + sliceSize;
            return true;
        }
    }
}
