// 本文件只替代本测试不会访问的 GPU 资源与图形 API；队列、就绪门、丢帧和计时由链接的生产源码执行。
namespace Ryujinx.Graphics.GAL
{
    public enum Format { R8G8B8A8Unorm, B8G8R8A8Unorm, B5G6R5Unorm, R4G4B4A4Unorm }
    public enum Target { Texture2D }
    public readonly record struct ImageCrop(int Left, int Right, int Top, int Bottom,
        bool FlipX, bool FlipY, bool IsStretched, float AspectRatioX, float AspectRatioY);
}

namespace Ryujinx.Memory.Range
{
    public readonly record struct MultiRange(ulong Address, ulong Size);
}

namespace Ryujinx.Graphics.Texture
{
    public static class SizeCalculator
    {
        public readonly record struct SizeResult(int TotalSize);
        public static SizeResult GetBlockLinearTextureSize(int width, int height, int depth, int levels, int layers,
            int blockWidth, int blockHeight, int bytesPerPixel, int gobBlocksInY, int gobBlocksInZ, int tileX) =>
            new(width * height * bytesPerPixel);
    }
}

namespace Ryujinx.Graphics.Gpu.Image
{
    using Ryujinx.Graphics.GAL;
    using Ryujinx.Memory.Range;

    public readonly record struct FormatInfo(Format Format, int BlockWidth, int BlockHeight, int BytesPerPixel, int Components);
    public enum TextureSearchFlags { WithUpscale }
    public readonly struct TextureInfo
    {
        public int Width { get; }
        public int Height { get; }
        public TextureInfo(ulong address, int width, int height, int depth, int levels, int samplesInX, int samplesInY,
            int stride, bool isLinear, int gobBlocksInY, int gobBlocksInZ, int tileX, Target target, FormatInfo format)
        {
            Width = width;
            Height = height;
        }
    }

    public sealed class Texture
    {
        public TextureInfo Info { get; }
        public float ScaleFactor => 1;
        public object HostTexture { get; } = new();
        public Texture(TextureInfo info) => Info = info;
        public void SynchronizeMemory() { }
    }

    public sealed class TextureCache
    {
        public Texture FindOrCreateTexture(object? unused, TextureSearchFlags flags, TextureInfo info, int layer, MultiRange range) => new(info);
        public void Tick() { }
    }
}

namespace Ryujinx.Graphics.Gpu.Memory
{
    public sealed class PhysicalMemory
    {
        public Image.TextureCache TextureCache { get; } = new();
    }
}

namespace Ryujinx.Graphics.Gpu
{
    using Ryujinx.Graphics.GAL;
    using Ryujinx.Graphics.Gpu.Memory;

    public sealed class GpuContext
    {
        public Dictionary<ulong, PhysicalMemory> PhysicalMemoryRegistry { get; } = new();
        public StubRenderer Renderer { get; } = new();
        public Window Window { get; }
        public StubFifo GPFifo { get; } = new();
        public GpuContext() => Window = new(this);
        public void AdvanceSequence() { }
    }

    public sealed class StubFifo { public void Interrupt() { } }
    public sealed class StubRenderer { public StubRenderWindow Window { get; } = new(); }
    public sealed class StubRenderWindow
    {
        public int Presented { get; private set; }
        public void Present(object texture, ImageCrop crop, Action callback)
        {
            Presented++;
            callback();
        }
    }
}
