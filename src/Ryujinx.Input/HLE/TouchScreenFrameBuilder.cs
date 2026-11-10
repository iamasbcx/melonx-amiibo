using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using System;
using System.Drawing;
using System.Numerics;

namespace Ryujinx.Input.HLE
{
    /// <summary>
    /// 单个宿主输入线程拥有的多点触摸状态机。当前触点与结束触点共同组成一帧，按稳定 Id 匹配。
    /// 目标缓冲区必须容纳两倍 MaxTouches；返回有效项数，activeCount 表示前部仍按下的触点数。
    /// </summary>
    public sealed class TouchScreenFrameBuilder
    {
        private readonly TouchSnapshot[] _previous = new TouchSnapshot[ITouchScreen.MaxTouches];
        private int _previousCount;

        public int BuildFrame(ReadOnlySpan<TouchSnapshot> current, Size clientSize, Span<TouchPoint> destination, out int activeCount)
        {
            if (current.Length > ITouchScreen.MaxTouches) throw new ArgumentOutOfRangeException(nameof(current));
            if (destination.Length < 2 * ITouchScreen.MaxTouches) throw new ArgumentException("Touch frame buffer is too small.", nameof(destination));
            activeCount = current.Length;
            int count = 0;
            foreach (TouchSnapshot touch in current)
            {
                Vector2 position = ITouchScreen.GetTouchPosition(touch.Position, clientSize);
                bool continuing = Contains(_previous.AsSpan(0, _previousCount), touch.Id);
                destination[count++] = CreatePoint(touch.Id, position, continuing ? TouchAttribute.None : TouchAttribute.Start);
            }
            for (int index = 0; index < _previousCount; index++)
            {
                TouchSnapshot previous = _previous[index];
                if (!Contains(current, previous.Id)) destination[count++] = CreatePoint(previous.Id, previous.Position, TouchAttribute.End);
            }
            for (int index = 0; index < current.Length; index++)
            {
                _previous[index] = new TouchSnapshot(current[index].Id, ITouchScreen.GetTouchPosition(current[index].Position, clientSize));
            }
            _previousCount = current.Length;
            return count;
        }

        private static bool Contains(ReadOnlySpan<TouchSnapshot> points, int id)
        {
            foreach (TouchSnapshot point in points) if (point.Id == id) return true;
            return false;
        }

        private static TouchPoint CreatePoint(int id, Vector2 position, TouchAttribute attribute) => new()
        {
            FingerId = unchecked((uint)id),
            Attribute = attribute,
            X = (uint)position.X,
            Y = (uint)position.Y,
            DiameterX = 10,
            DiameterY = 10,
            Angle = 90,
        };
    }
}
