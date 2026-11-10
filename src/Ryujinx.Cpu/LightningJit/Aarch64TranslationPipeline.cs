using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Cpu.LightningJit
{
    /// <summary>
    /// 双映射 AArch64 的未命中协调器。每地址只允许一个编译者，不同地址在锁外并行编译。
    /// 失效与发布共用锁；任意代码失效均递增代数，使尚未发布的旧编译结果丢弃后重试。
    /// 不处理 ARM/Thumb 或 NoWx 的线程局部可执行映射。所有委托在构造时绑定，普通缓存命中不分配。
    /// </summary>
    internal sealed class Aarch64TranslationPipeline : IDisposable
    {
        internal delegate bool Lookup(ulong address, out nint pointer);
        internal delegate CompiledFunction Compile(ulong address);
        internal delegate nint Publish(ulong address, CompiledFunction function);

        private readonly object _lock = new();
        private readonly Dictionary<ulong, int> _inFlight = new();
        private readonly HashSet<int> _owners = new();
        private readonly Lookup _lookup;
        private readonly Compile _compile;
        private readonly Publish _publish;
        private readonly Action<ulong, ulong> _invalidate;
        private long _epoch;
        private volatile bool _disposed;

        public Aarch64TranslationPipeline(Lookup lookup, Compile compile, Publish publish, Action<ulong, ulong> invalidate)
        {
            _lookup = lookup;
            _compile = compile;
            _publish = publish;
            _invalidate = invalidate;
        }

        public nint GetOrCompile(ulong address)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_lookup(address, out nint cached)) return cached;
            int owner = Environment.CurrentManagedThreadId;
            while (true)
            {
                long epoch;
                lock (_lock)
                {
                    ObjectDisposedException.ThrowIf(_disposed, this);
                    // 编译器正常只读取来宾指令；重入翻译意味着未知回调路径，明确报错避免同地址或 ABBA 自锁。
                    if (_owners.Contains(owner)) throw new InvalidOperationException($"Reentrant AArch64 translation at 0x{address:X}.");
                    while (_inFlight.ContainsKey(address))
                    {
                        Monitor.Wait(_lock);
                        ObjectDisposedException.ThrowIf(_disposed, this);
                    }
                    if (_lookup(address, out cached)) return cached;
                    _inFlight.Add(address, owner);
                    _owners.Add(owner);
                    epoch = _epoch;
                }
                try
                {
                    CompiledFunction function = _compile(address);
                    lock (_lock)
                    {
                        ObjectDisposedException.ThrowIf(_disposed, this);
                        if (epoch != _epoch) continue;
                        // Publish 必须同步复制代码并发布函数表，不得保存借用 Span 或重入本协调器。
                        return _publish(address, function);
                    }
                }
                finally
                {
                    lock (_lock)
                    {
                        _inFlight.Remove(address);
                        _owners.Remove(owner);
                        Monitor.PulseAll(_lock);
                    }
                }
            }
        }

        public void Invalidate(ulong address, ulong size)
        {
            lock (_lock)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                _epoch++;
                _invalidate(address, size);
            }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                _disposed = true;
                Monitor.PulseAll(_lock);
            }
        }
    }
}
