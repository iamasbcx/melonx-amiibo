using ARMeilleure.Common;
using ARMeilleure.Memory;
using Ryujinx.Common.Callbacks;
using Ryujinx.Cpu.Jit;
using Ryujinx.Cpu.LightningJit;
using Ryujinx.Cpu.LightningJit.State;
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.Input.Native;
using Ryujinx.Memory;
using System.Buffers;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;

int checks = 0;
void Require(bool condition, string message)
{
    checks++;
    if (!condition) throw new InvalidOperationException(message);
}
void Complete(Task task) => Require(task.Wait(TimeSpan.FromSeconds(8)), "并发回归超过 8 秒，可能发生死锁");
static unsafe RumbleData ReadRumble(nint pointer) => System.Runtime.CompilerServices.Unsafe.ReadUnaligned<RumbleData>((void*)pointer);

// 生产计时队列：后来的更晚任务不惊醒计时器，相同 deadline 保持原注册顺序。
ScheduledObjectQueue<object> deadlines = new();
object first = new(), later = new(), equal = new(), earlier = new();
Require(deadlines.Add(first, 100), "第一个定时任务未唤醒");
Require(!deadlines.Add(later, 300) && !deadlines.Add(equal, 100), "非最早截止任务造成多余唤醒");
Require(ReferenceEquals(deadlines.Head!.Object, first), "相同截止时间顺序改变");
Require(deadlines.Add(earlier, 50), "更早定时任务未唤醒");
Require(!deadlines.Remove(later) && deadlines.Remove(earlier), "取消通知没有按最早截止时间区分");
var cancelled = deadlines.Head;
Require(!deadlines.Remove(first) && ReferenceEquals(deadlines.Head!.Object, equal), "取消同截止任务无须提前唤醒");
Require(!deadlines.TryRemove(cancelled!), "已取消任务仍会执行回调");
Require(deadlines.TryRemove(deadlines.Head!) && deadlines.Head == null, "最后一个到期任务未移除");
Require(deadlines.Add(first, long.MaxValue) && deadlines.Remove(first), "最大截止时间与空队列混淆");
Require(deadlines.Add(first, 0) && deadlines.Head!.TimePoint == 0 && deadlines.TryRemove(deadlines.Head), "首次立即到期任务丢失");
// 与朴素按注册顺序排序的参考序列逐项比较，覆盖随机取消/重注册/重复对象。
Random random = new(124);
List<(object Value, long Deadline)> reference = new();
object[] identities = Enumerable.Range(0, 32).Select(_ => new object()).ToArray();
for (int step = 0; step < 3000; step++)
{
    object identity = identities[random.Next(identities.Length)];
    long? previous = reference.Count == 0 ? null : reference.Min(entry => entry.Deadline);
    bool signal;
    if (random.Next(3) != 0)
    {
        long deadline = random.Next(100);
        reference.Add((identity, deadline));
        signal = deadlines.Add(identity, deadline);
    }
    else
    {
        reference.RemoveAll(entry => ReferenceEquals(entry.Value, identity));
        signal = deadlines.Remove(identity);
    }
    var expected = reference.OrderBy(entry => entry.Deadline).FirstOrDefault();
    long? current = reference.Count == 0 ? null : expected.Deadline;
    Require(signal == (current != previous), "计时队列唤醒决策与参考状态不一致");
    Require(current == deadlines.Head?.TimePoint && (current == null || ReferenceEquals(expected.Value, deadlines.Head!.Object)), "计时队列最早任务错误");
}

// 真实 HostTracked 映射、读取与跨物理区段验证，未替换内存管理器。
using (MemoryBlock backing = new(0x8000))
{
    MemoryManagerHostTracked memory = new(backing, 0x1_0000_0000UL, true, null);
    memory.IncrementReferenceCount();
    try
    {
        memory.Map(0x1000, 0, 0x2000, MemoryMapFlags.None);
        memory.Map(0x3000, 0x5000, 0x1000, MemoryMapFlags.None);
        byte[] payload = Enumerable.Range(0, 128).Select(i => (byte)i).ToArray();
        memory.Write(0x1100, payload);
        ReadOnlySequence<byte> one = memory.GetReadOnlySequence(0x1100, payload.Length);
        Require(one.IsSingleSegment && one.FirstSpan.SequenceEqual(payload), "单段 IPC 内容或序列形态错误");
        memory.Write(0x2fc0, payload);
        ReadOnlySequence<byte> multiple = memory.GetReadOnlySequence(0x2fc0, payload.Length);
        Require(!multiple.IsSingleSegment && multiple.ToArray().SequenceEqual(payload), "跨映射 IPC 内容错误");
        Require(memory.GetReadOnlySequence(0, 0).IsEmpty, "零长度 IPC 不应访问地址");
        bool invalid = false;
        try { _ = memory.GetReadOnlySequence(0xf000, 16); }
        catch (InvalidMemoryRegionException) { invalid = true; }
        Require(invalid, "IPC 快路径跳过未映射地址校验");
    }
    finally { memory.DecrementReferenceCount(); }
}

// 经真正 CallbackRegistry 的同步 C ABI 验证 44 字节布局、回调内重入及热循环零托管分配。
NativeGamepad gamepad = new("test", "thermal-regression");
RumbleData last = default;
int notifications = 0;
bool nesting = false;
bool outerIntact = true;
SwiftDataCallback callback = (ref CallbackData data, nint _) =>
{
    if (data.Len != 44) throw new InvalidOperationException("震动 ABI 长度错误");
    RumbleData value = ReadRumble(data.Ptr);
    if (nesting && value.DurationMs == 777)
    {
        gamepad.Rumble(0, 0, 0);
        outerIntact &= ReadRumble(data.Ptr).DurationMs == 777;
    }
    last = value;
    notifications++;
};
nint name = Marshal.StringToCoTaskMemUTF8("rumble-thermal-regression");
try
{
    CallbackRegistry.RegisterCallback(name, Marshal.GetFunctionPointerForDelegate(callback), 0);
    gamepad.Rumble(0.25f, 0.75f, 123);
    Require(Marshal.SizeOf<RumbleData>() == 44 && last.LowFrequency == 0.25f && last.HighFrequency == 0.75f && last.DurationMs == 123 && last.LeftFrequencyLow == 160 && last.RightFrequencyHigh == 320, "震动字段或布局改变");
    nesting = true;
    gamepad.Rumble(0.2f, 0.4f, 777);
    nesting = false;
    Require(outerIntact && notifications == 3, "嵌套震动回调覆盖调用者栈数据");
    for (int index = 0; index < 10000; index++) gamepad.Rumble(0.3f, 0.4f, 10);
    long before = GC.GetAllocatedBytesForCurrentThread();
    for (int index = 0; index < 10000; index++) gamepad.Rumble(0.3f, 0.4f, 10);
    long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
    Require(allocated == 0, $"震动回调热路径分配 {allocated} 字节");
}
finally
{
    CallbackRegistry.UnregisterCallback(name);
    Marshal.FreeCoTaskMem(name);
    GC.KeepAlive(callback);
}

// 以下使用真实 AarchCompiler、HostTracked 指令内存、TranslatorCache 和 AddressTable。
// 宿主仅保存/比较 ARM64 机器码，不在 Windows 上调用或模拟 iOS RX 映射。
using (CompilationFixture fixture = new())
{
    using ManualResetEventSlim compiling = new(), release = new();
    fixture.AfterCompile = address => { compiling.Set(); if (!release.Wait(5000)) throw new TimeoutException(); };
    Task<nint> firstCompilation = Task.Run(() => fixture.Pipeline.GetOrCompile(0x1000));
    Require(compiling.Wait(3000), "真实 ARM64 编译器未进入测试点");
    Task<nint>[] followers = Enumerable.Range(0, 8).Select(_ => Task.Run(() => fixture.Pipeline.GetOrCompile(0x1000))).ToArray();
    release.Set();
    Complete(Task.WhenAll(followers.Append(firstCompilation)));
    Require(fixture.Compilations == 1 && followers.All(task => task.Result == firstCompilation.Result), "同地址并发未合并");
    Require(fixture.Table.GetValue(0x1000) == (ulong)firstCompilation.Result && fixture.GetCode(0x1000).Length > 0, "真实函数表未发布机器码");
}

using (CompilationFixture fixture = new())
{
    using Barrier overlap = new(2);
    fixture.BeforeCompile = _ => { if (!overlap.SignalAndWait(5000)) throw new TimeoutException("不同地址被全局编译锁串行化"); };
    Task<nint> one = Task.Run(() => fixture.Pipeline.GetOrCompile(0x1000));
    Task<nint> two = Task.Run(() => fixture.Pipeline.GetOrCompile(0x1100));
    Complete(Task.WhenAll(one, two));
    Require(fixture.Compilations == 2 && one.Result != two.Result, "不同地址编译不能独立进行");
}

using (CompilationFixture fixture = new())
{
    using ManualResetEventSlim oldCompiled = new(), release = new();
    int intercepted = 0;
    fixture.AfterCompile = _ =>
    {
        if (Interlocked.Increment(ref intercepted) == 1)
        {
            oldCompiled.Set();
            if (!release.Wait(5000)) throw new TimeoutException();
        }
    };
    Task<nint> translation = Task.Run(() => fixture.Pipeline.GetOrCompile(0x1000));
    Require(oldCompiled.Wait(3000), "失效测试未取得旧机器码");
    fixture.Memory.Write(0x1000, 0x52800040u); // mov w0, #2，后续 ret 保持不变。
    fixture.Pipeline.Invalidate(0x1000, 4);
    release.Set();
    Complete(translation);
    Require(fixture.Compilations == 2 && fixture.Publications == 1, "代码失效后发布了旧编译结果");
    Require(fixture.GetCode(0x1000).AsSpan().SequenceEqual(fixture.CompileForComparison(0x1000)), "已发布机器码不是最新指令版本");
    fixture.Pipeline.Invalidate(0x1000, 8);
    Require(fixture.Table.GetValue(0x1000) == fixture.Table.Fill, "失效未清除真实函数表");
    fixture.Pipeline.GetOrCompile(0x1000);
    Require(fixture.Compilations == 3, "发布后的函数失效未重新编译");
}

using (CompilationFixture fixture = new())
{
    fixture.BeforeCompile = _ => throw new InvalidOperationException("injected compile failure");
    bool failed = false;
    try { fixture.Pipeline.GetOrCompile(0x1000); } catch (InvalidOperationException) { failed = true; }
    fixture.BeforeCompile = null;
    Require(failed && fixture.Pipeline.GetOrCompile(0x1000) != 0, "编译失败污染在途缓存");
    fixture.BeforeCompile = _ => fixture.Pipeline.GetOrCompile(0x1200);
    Task<bool> reentrant = Task.Run(() =>
    {
        try { fixture.Pipeline.GetOrCompile(0x1100); return false; }
        catch (InvalidOperationException exception) { return exception.Message.Contains("Reentrant AArch64"); }
    });
    Complete(reentrant);
    Require(reentrant.Result, "编译重入未诊断或发生死锁");
    fixture.BeforeCompile = null;
    Require(fixture.Pipeline.GetOrCompile(0x1100) != 0, "重入失败后不能恢复编译");
}
Console.WriteLine($"CoreOptimization.Tests: {checks} checks passed; real A64 compile/cache/invalidation, IPC and rumble validated.");

sealed class CompilationFixture : IDisposable
{
    private readonly MemoryBlock _backing = new(0x4000);
    private readonly List<MemoryBlock> _codeBlocks = [];
    private readonly TranslatorCache<TranslatedFunction> _functions = new();
    public readonly MemoryManagerHostTracked Memory;
    public readonly AddressTable<ulong> Table = AddressTable<ulong>.CreateForArm(true, MemoryManagerType.SoftwarePageTable);
    public readonly Aarch64TranslationPipeline Pipeline;
    public Action<ulong>? BeforeCompile;
    public Action<ulong>? AfterCompile;
    public int Compilations;
    public int Publications;

    public CompilationFixture()
    {
        Memory = new MemoryManagerHostTracked(_backing, 0x1_0000_0000UL, true, null);
        Memory.IncrementReferenceCount();
        Memory.Map(0x1000, 0, 0x3000, MemoryMapFlags.None);
        for (ulong address = 0x1000; address <= 0x1200; address += 0x100)
        {
            Memory.Write(address, 0x52800020u); // mov w0, #1
            Memory.Write(address + 4, 0xd65f03c0u); // ret
        }
        Pipeline = new Aarch64TranslationPipeline(Lookup, Compile, Publish, Invalidate);
    }

    private bool Lookup(ulong address, out nint pointer)
    {
        bool found = _functions.TryGetValue(address, out TranslatedFunction function);
        pointer = found ? function.FuncPointer : 0;
        return found;
    }

    private CompiledFunction Compile(ulong address)
    {
        BeforeCompile?.Invoke(address);
        Interlocked.Increment(ref Compilations);
        CompiledFunction function = AarchCompiler.Compile(CpuPresets.CortexA57, Memory, address, Table, 0, ExecutionMode.Aarch64, Architecture.Arm64);
        AfterCompile?.Invoke(address);
        return function;
    }

    public byte[] CompileForComparison(ulong address) => AarchCompiler.Compile(CpuPresets.CortexA57, Memory, address, Table, 0, ExecutionMode.Aarch64, Architecture.Arm64).Code.ToArray();

    private nint Publish(ulong address, CompiledFunction function)
    {
        MemoryBlock block = new((ulong)Math.Max(function.Code.Length, 4096));
        function.Code.CopyTo(block.GetSpan(0, function.Code.Length));
        _codeBlocks.Add(block);
        _functions.GetOrAdd(address, (ulong)function.GuestCodeLength, new TranslatedFunction(block.Pointer, (ulong)function.GuestCodeLength));
        Table.GetValue(address) = (ulong)block.Pointer;
        Publications++;
        return block.Pointer;
    }

    private void Invalidate(ulong address, ulong size)
    {
        ulong[] overlaps = [];
        int count = _functions.GetOverlaps(address, size, ref overlaps);
        for (int index = 0; index < count; index++)
        {
            _functions.Remove(overlaps[index]);
            Table.GetValue(overlaps[index]) = Table.Fill;
        }
    }

    public byte[] GetCode(ulong address)
    {
        CompiledFunction reference = AarchCompiler.Compile(CpuPresets.CortexA57, Memory, address, Table, 0, ExecutionMode.Aarch64, Architecture.Arm64);
        ulong pointer = Table.GetValue(address);
        unsafe { return new ReadOnlySpan<byte>((void*)pointer, reference.Code.Length).ToArray(); }
    }

    public void Dispose()
    {
        Pipeline.Dispose();
        foreach (MemoryBlock block in _codeBlocks) block.Dispose();
        Table.Dispose();
        Memory.DecrementReferenceCount();
        _backing.Dispose();
    }
}
