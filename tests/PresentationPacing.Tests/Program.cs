using Ryujinx.Graphics.Gpu;

// 直接编译生产节拍器：验证 UI 重复更新、模式切换及并发不会破坏最终呈现节拍。
// 此测试不模拟来宾时钟或 GPU 执行，也不代表整机帧率、功耗及实际温度测量。
var checks = 0;

void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    checks++;
}

var pacer = new UnboundedPresentPacer(6000, 60);
Check(pacer.TrySchedulePresent(0), "时钟为零的首帧必须可呈现");
Check(!pacer.TrySchedulePresent(0), "同一时刻只能呈现一次");
for (long tick = 1; tick < 100; tick++)
{
    pacer.SetTargetFps(60);
    Check(!pacer.TrySchedulePresent(tick), "重复报告相同刷新率不得放行额外帧");
}
Check(pacer.TrySchedulePresent(100), "达到完整间隔必须放行");
Check(!pacer.TrySchedulePresent(199), "下一间隔不能提前放行");
Check(pacer.TrySchedulePresent(200), "后续完整间隔必须放行");

pacer.SetTargetFps(120);
Check(pacer.TrySchedulePresent(201), "真实刷新率变化允许重新建立基准");
pacer.SetTargetFps(120);
Check(!pacer.TrySchedulePresent(250), "新刷新率也必须拒绝不足间隔的帧");
Check(pacer.TrySchedulePresent(251), "新刷新率按新间隔放行");
pacer.Reset();
Check(pacer.TrySchedulePresent(252), "模式切换重建首帧基准");
Check(!pacer.TrySchedulePresent(253), "重建基准后必须继续节拍控制");
Check(pacer.TrySchedulePresent(1), "计时器回退应重建基准");
Check(!pacer.TrySchedulePresent(2), "计时器回退后不能连续放行");

var normalized = new UnboundedPresentPacer(1000, 0);
Check(normalized.TrySchedulePresent(0), "零目标按每秒一帧归一化");
normalized.SetTargetFps(-30);
Check(!normalized.TrySchedulePresent(999), "归一化后同目标不得重置节拍");
Check(normalized.TrySchedulePresent(1000), "归一化目标到期后必须放行");
var maximum = new UnboundedPresentPacer(1, int.MaxValue);
Check(maximum.TrySchedulePresent(0) && !maximum.TrySchedulePresent(0) && maximum.TrySchedulePresent(1),
    "目标超过时钟精度时最小间隔仍为一 tick");

bool rejectedFrequency = false;
try { _ = new UnboundedPresentPacer(0, 60); }
catch (ArgumentOutOfRangeException) { rejectedFrequency = true; }
Check(rejectedFrequency, "无效时钟频率必须明确拒绝");

// 共享的生产实例接收并发申请；同一时刻只有一个调用能占用呈现机会。
var concurrent = new UnboundedPresentPacer(6000, 60);
var accepted = 0;
Parallel.For(0, 256, _ =>
{
    concurrent.SetTargetFps(60);
    if (concurrent.TrySchedulePresent(1000)) Interlocked.Increment(ref accepted);
});
Check(accepted == 1, "并发同值刷新与呈现只能放行一帧");
Check(concurrent.TrySchedulePresent(1100), "并发申请后下一个完整间隔仍可呈现");

Console.WriteLine($"PresentationPacingTests: {checks} checks passed (same-FPS updates, reset, bounds and concurrency)");
