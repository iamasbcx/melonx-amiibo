using Ryujinx.Input;
using System;
using System.Numerics;
using System.Threading;

namespace Ryujinx.Library
{
    /// <summary>
    /// UI 写入、宿主循环读取的最多 16 点触摸状态。锁内复制完整快照，调用方拥有目标缓冲区。
    /// 不保留调用方 Span，不分配逐帧数组；重复移动、未知抬起和非有限坐标均不产生唤醒。
    /// </summary>
    internal sealed class NativeTouchState
    {
        private readonly Lock _lock = new();
        private readonly TouchSnapshot[] _touches = new TouchSnapshot[ITouchScreen.MaxTouches];
        private int _count;

        public bool HasTouches { get { lock (_lock) return _count != 0; } }

        public bool Begin(int id, Vector2 position)
        {
            if (!float.IsFinite(position.X) || !float.IsFinite(position.Y)) return false;
            lock (_lock)
            {
                int index = Find(id);
                if (index < 0)
                {
                    if (_count == _touches.Length) return false;
                    index = _count++;
                }
                else if (_touches[index].Position == position) return false;
                _touches[index] = new TouchSnapshot(id, position);
                return true;
            }
        }

        public bool Move(int id, Vector2 position)
        {
            if (!float.IsFinite(position.X) || !float.IsFinite(position.Y)) return false;
            lock (_lock)
            {
                int index = Find(id);
                if (index < 0 || _touches[index].Position == position) return false;
                _touches[index] = new TouchSnapshot(id, position);
                return true;
            }
        }

        public bool End(int id)
        {
            lock (_lock)
            {
                int index = Find(id);
                if (index < 0) return false;
                _touches[index] = _touches[--_count];
                _touches[_count] = default;
                return true;
            }
        }

        public int CopyTo(Span<TouchSnapshot> destination)
        {
            lock (_lock)
            {
                if (destination.Length < _count) throw new ArgumentException("Touch snapshot buffer is too small.", nameof(destination));
                _touches.AsSpan(0, _count).CopyTo(destination);
                return _count;
            }
        }

        public void Clear()
        {
            lock (_lock)
            {
                _touches.AsSpan(0, _count).Clear();
                _count = 0;
            }
        }

        private int Find(int id)
        {
            for (int index = 0; index < _count; index++) if (_touches[index].Id == id) return index;
            return -1;
        }
    }
}
