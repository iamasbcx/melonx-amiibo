using System.Drawing;
using System.Threading;

namespace Ryujinx.Library
{
    /// <summary>
    /// 应用级游戏视图尺寸，保留 UI 在窗口创建前和两局之间提交的有效值。
    /// UI 写入与输入线程读取使用同一锁，宽高不能来自两次不同的旋转更新。
    /// </summary>
    internal sealed class NativeViewportState
    {
        private readonly Lock _lock = new();
        private Size _size;
        private bool _hasNativeSize;

        public NativeViewportState(int width, int height) => _size = new Size(width, height);
        public Size Size { get { lock (_lock) return _size; } }

        public bool SetNativeSize(int width, int height)
        {
            if (width <= 0 || height <= 0) return false;
            lock (_lock)
            {
                _hasNativeSize = true;
                Size size = new(width, height);
                if (_size == size) return false;
                _size = size;
                return true;
            }
        }

        public void InitializeFallback(int width, int height)
        {
            lock (_lock)
            {
                if (!_hasNativeSize && width > 0 && height > 0) _size = new Size(width, height);
            }
        }
    }
}
