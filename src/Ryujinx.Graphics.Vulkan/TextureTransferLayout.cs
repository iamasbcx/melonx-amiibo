using System;

namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>纹理传输的字节窗口；长度与缓冲区起点独立，防止非零 staging 偏移截断 mip。</summary>
    internal static class TextureTransferLayout
    {
        public static int UploadAlignment(int texelBlockBytes, int resourceAlignment)
        {
            // staging 环只接受 2 的幂对齐；少见的三分量格式继续使用起点为零的独立缓冲区。
            if (texelBlockBytes <= 0 || (texelBlockBytes & (texelBlockBytes - 1)) != 0 ||
                resourceAlignment <= 0 || (resourceAlignment & (resourceAlignment - 1)) != 0) return 0;
            return Math.Max(4, Math.Max(texelBlockBytes, resourceAlignment));
        }

        public static bool TryGetOffset(int bufferOffset, int dataLength, int consumed, int sliceLength, out int offset)
        {
            offset = 0;
            if (bufferOffset < 0 || dataLength < 0 || consumed < 0 || sliceLength <= 0 ||
                consumed > dataLength || sliceLength > dataLength - consumed ||
                bufferOffset > int.MaxValue - dataLength) return false;
            offset = bufferOffset + consumed;
            return true;
        }

        /// <summary>计算矩形传输实际触及的末字节；块压缩按完整块计算，上传小像素行按现有 4 字节规则补齐。</summary>
        public static bool TryGetRegionSize(int width, int height, int blockWidth, int blockHeight, int blockBytes,
            bool upload, out int size)
        {
            size = 0;
            if (width <= 0 || height <= 0 || blockWidth <= 0 || blockHeight <= 0 || blockBytes <= 0) return false;
            long columns = ((long)width + blockWidth - 1) / blockWidth;
            long rows = ((long)height + blockHeight - 1) / blockHeight;
            long rowBytes = columns * blockBytes;
            long rowStride = upload && blockBytes < 4 && 4 % blockBytes == 0 ? (rowBytes + 3) & ~3L : rowBytes;
            // 逐项检查，避免巨大非法维度在最终乘法时溢出 long。
            if (rowBytes > int.MaxValue || rowStride > int.MaxValue || rows > int.MaxValue) return false;
            long required = rowStride * (rows - 1) + rowBytes;
            if (required > int.MaxValue) return false;
            size = (int)required;
            return true;
        }
    }
}
