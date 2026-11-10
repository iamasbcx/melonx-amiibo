using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Vulkan;

// 覆盖纯布局窗口与真实 worker 调度；不替代 Vulkan 驱动、纹理像素和真机功耗验证。
static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static void Finish(Task task, string message)
{
    Require(task.Wait(TimeSpan.FromSeconds(5)), message);
}

foreach ((int cores, int expectedWorkers) in new[] { (0, 1), (1, 1), (4, 1), (6, 1), (8, 2), (64, 2) })
    Require(ShaderCompilationBudget.GetBackgroundWorkers(cores) == expectedWorkers, "Compilation CPU budget");

Require(TextureTransferLayout.UploadAlignment(1, 4) == 4, "R8 alignment");
Require(TextureTransferLayout.UploadAlignment(8, 4) == 8, "D24S8 conversion / BC1 alignment");
Require(TextureTransferLayout.UploadAlignment(16, 256) == 256, "BC3 / resource alignment");
Require(TextureTransferLayout.UploadAlignment(3, 4) == 0, "RGB uses standalone buffer");
Require(TextureTransferLayout.UploadAlignment(4, 0) == 0, "Invalid resource alignment rejected");
int consumed = 0;
foreach (int length in new[] { 4096, 1024, 256, 64 })
{
    Require(TextureTransferLayout.TryGetOffset(8192, 5440, consumed, length, out int offset), "Nonzero mip offset accepted");
    Require(offset == 8192 + consumed, "Mips stay in the reserved staging window");
    consumed += length;
}
Require(!TextureTransferLayout.TryGetOffset(8192, 5440, consumed, 4, out _), "No mip after the data window");
Require(!TextureTransferLayout.TryGetOffset(int.MaxValue, 4, 0, 4, out _), "Upload offset overflow");
Require(!TextureTransferLayout.TryGetOffset(0, 16, 0, 32, out _), "Truncated upload rejected");
Require(!TextureTransferLayout.TryGetOffset(-1, 16, 0, 16, out _), "Negative upload rejected");
Require(TextureTransferLayout.TryGetRegionSize(3, 2, 1, 1, 1, true, out int regionBytes) && regionBytes == 7, "R8 padded rows and final row");
Require(TextureTransferLayout.TryGetRegionSize(5, 5, 4, 4, 8, true, out regionBytes) && regionBytes == 32, "BC1 region includes partial edge blocks");
Require(TextureTransferLayout.TryGetRegionSize(5, 5, 4, 4, 16, true, out regionBytes) && regionBytes == 64, "BC3 region includes partial edge blocks");
Require(TextureTransferLayout.TryGetRegionSize(2, 2, 1, 1, 3, true, out regionBytes) && regionBytes == 12, "RGB standalone region packing");
Require(!TextureTransferLayout.TryGetRegionSize(int.MaxValue, int.MaxValue, 1, 1, 16, true, out _), "Region size overflow");

Require(TextureReadbackBatch.TryAppend(0, 257, 16, out int first, out int total) && first == 0 && total == 257, "First slice");
Require(TextureReadbackBatch.TryAppend(total, 64, 16, out int second, out total) && second == 272 && total == 336, "Slice block alignment");
Require(TextureReadbackBatch.TryAppend(0, TextureReadbackBatch.MaxBytes, 4, out _, out _), "Exact readback budget");
Require(!TextureReadbackBatch.TryAppend(total, TextureReadbackBatch.MaxBytes, 4, out _, out _), "Readback budget fallback");
Require(!TextureReadbackBatch.TryAppend(int.MaxValue, 4, 4, out _, out _), "Readback offset overflow");
Require(!TextureReadbackBatch.TryAppend(0, 4, 3, out _, out _), "Invalid block alignment");

PipelineCacheGeneration fresh = new(false);
Require(!fresh.IsDirty && !fresh.NeedsMerge, "Unused cache does not write or merge");
PipelineCacheGeneration loaded = new(true);
Require(!loaded.IsDirty && loaded.NeedsMerge, "Loaded worker still merges without rewriting its snapshot");
loaded.MarkMerged(loaded.Current);
Require(!loaded.NeedsMerge, "Unchanged cache does not merge twice");
loaded.MarkChanged();
long checkpoint = loaded.Current;
loaded.MarkSaved(checkpoint);
Require(!loaded.IsDirty && loaded.NeedsMerge, "Checkpoint does not imply merged");
loaded.MarkChanged();
loaded.MarkSaved(checkpoint);
Require(loaded.IsDirty, "Old checkpoint cannot clean newer writes");
loaded.MarkMerged(loaded.Current);
Require(loaded.IsDirty && !loaded.NeedsMerge, "Merge does not imply persisted");
loaded.MarkSaved(loaded.Current);
loaded.MarkChanged();
Require(loaded.IsDirty && loaded.NeedsMerge, "Recreation invalidates saved and merged generations");

int workers = ShaderCompilationBudget.BackgroundWorkers;
PipelineCacheManager caches = new();
using (BackgroundCompilationScheduler scheduler = new(caches))
using (ManualResetEventSlim release = new())
using (CountdownEvent started = new(workers))
{
    Task[] blockers = Enumerable.Range(0, workers).Select(_ => scheduler.ScheduleShaderCompile(() =>
    {
        started.Signal();
        Require(release.Wait(TimeSpan.FromSeconds(5)), "Shader blocker timed out");
    })).ToArray();
    Require(started.Wait(TimeSpan.FromSeconds(5)), "All normal shader workers started");
    int queuedRan = 0;
    Task queued = scheduler.ScheduleShaderCompile(() => Interlocked.Increment(ref queuedRan));
    Task demanded = scheduler.ScheduleShaderCompile(() => { });
    try
    {
        scheduler.PromoteShaderCompile(demanded);
        Finish(demanded, "Demand shader bypasses busy normal workers");
        Require(Volatile.Read(ref queuedRan) == 0, "Regular shaders cannot exceed their budget");
    }
    finally { release.Set(); }
    Finish(Task.WhenAll(blockers.Append(queued)), "Shader queue drains");
    Task failure = scheduler.ScheduleShaderCompile(() => throw new InvalidOperationException("Expected test failure"));
    Require(SpinWait.SpinUntil(() => failure.IsCompleted, 5000) && failure.IsFaulted, "Worker exception completes task");
    _ = failure.Exception;
    Finish(scheduler.ScheduleShaderCompile(() => { }), "Worker survives task exception");

    Task[] pipelines = Enumerable.Range(0, 24).Select(_ => scheduler.SchedulePipelineCompile(cache =>
        Require(cache.Index >= 0 && cache.Index < BackgroundCompilationScheduler.PipelineCacheCount, "Worker cache index"))).ToArray();
    Finish(Task.WhenAll(pipelines), "Pipeline queue drains");
    Require(caches.Completed == 24, "Pipeline completion notifications");
}

// 退出时挂起任务必须终结；运行中的任务结束后 Dispose 才释放 worker，不能让等待方永久卡住。
BackgroundCompilationScheduler stopping = new(new());
using (ManualResetEventSlim release = new())
using (CountdownEvent started = new(workers))
{
    Task[] running = Enumerable.Range(0, workers).Select(_ => stopping.ScheduleShaderCompile(() =>
    {
        started.Signal();
        Require(release.Wait(TimeSpan.FromSeconds(5)), "Shutdown blocker timed out");
    })).ToArray();
    Require(started.Wait(TimeSpan.FromSeconds(5)), "Shutdown workers running");
    Task[] pending = Enumerable.Range(0, 12).Select(_ => stopping.ScheduleShaderCompile(() => { })).ToArray();
    Task disposal = Task.Run(stopping.Dispose);
    try
    {
        Require(SpinWait.SpinUntil(() => pending.All(task => task.IsCompleted), 5000), "Shutdown completes pending tasks");
        Require(pending.All(task => task.IsFaulted), "Pending jobs fail explicitly during shutdown");
        foreach (Task task in pending) _ = task.Exception;
    }
    finally { release.Set(); }
    Finish(Task.WhenAll(running), "Running jobs finish during shutdown");
    Finish(disposal, "Shutdown joins workers");
    Task rejected = stopping.ScheduleShaderCompile(() => { });
    Require(rejected.IsFaulted, "Post-shutdown scheduling fails explicitly");
    _ = rejected.Exception;
    stopping.Dispose();
}
Console.WriteLine("GraphicsOptimization: transfer bounds, batch packing, cache generations, compile budgets, demand scheduling and shutdown passed.");
