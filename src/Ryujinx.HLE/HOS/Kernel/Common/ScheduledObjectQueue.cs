#nullable enable
using System.Collections.Generic;

namespace Ryujinx.HLE.HOS.Kernel.Common
{
    /// <summary>
    /// 内核定时器的单锁队列；调用方必须持有内核临界区。只缓存最早项，不改变相同截止时间的注册顺序。
    /// 注册/取消返回是否改变最早截止时间，供调用方决定是否中断宿主等待；注册节点仍独立拥有。
    /// </summary>
    internal sealed class ScheduledObjectQueue<T> where T : class
    {
        internal sealed class Entry(T value, long timePoint)
        {
            public T Object { get; } = value;
            public long TimePoint { get; } = timePoint;
        }

        private readonly List<Entry> _entries = [];
        public Entry? Head { get; private set; }

        public bool Add(T value, long timePoint)
        {
            Entry entry = new(value, timePoint);
            _entries.Add(entry);
            if (Head != null && timePoint >= Head.TimePoint) return false;
            Head = entry;
            return true;
        }

        public bool Remove(T value)
        {
            long? previousDeadline = Head?.TimePoint;
            bool removedHead = false;
            for (int index = _entries.Count - 1; index >= 0; index--)
            {
                if (ReferenceEquals(_entries[index].Object, value))
                {
                    removedHead |= ReferenceEquals(_entries[index], Head);
                    _entries.RemoveAt(index);
                }
            }
            if (removedHead) RefreshHead();
            return Head?.TimePoint != previousDeadline;
        }

        public bool TryRemove(Entry entry)
        {
            if (!_entries.Remove(entry)) return false;
            if (ReferenceEquals(Head, entry)) RefreshHead();
            return true;
        }

        private void RefreshHead()
        {
            Head = null;
            foreach (Entry entry in _entries)
            {
                if (Head == null || entry.TimePoint < Head.TimePoint) Head = entry;
            }
        }
    }
}
