using Ryujinx.Graphics.Gpu;
using Ryujinx.HLE.HOS.Services.SurfaceFlinger;

// 直接编译生产节拍器：验证 UI 重复更新、模式切换及并发不会破坏最终呈现节拍。
// 此测试不模拟来宾时钟或 GPU 执行，也不代表整机帧率、功耗及实际温度测量。
var checks = 0;

void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    checks++;
}

// 快进计时必须使用生产换算入口验证，避免只测试一份复制到测试里的公式。
// 这里用固定 1 GHz 时钟消除机器 Stopwatch 频率差异；倍率单位与 Switch.TickScalar 一致（100 = 1.0x）。
const long hostFrequency = 1_000_000_000;
long normalFrame = CompositorTiming.CalculateTicksPerFrame(hostFrequency, 60, 100);
long twoTimesFrame = CompositorTiming.CalculateTicksPerFrame(hostFrequency, 60, 200);
long twentyTimesFrame = CompositorTiming.CalculateTicksPerFrame(hostFrequency, 60, 2000);
long normalAfterRelease = CompositorTiming.CalculateTicksPerFrame(hostFrequency, 60, 100);
Check(normalFrame == 16_666_666, "1.0x 的 60Hz 周期错误");
Check(twoTimesFrame == 8_333_333 && normalFrame / twoTimesFrame == 2, "2.0x 未将合成周期缩短为一半");
Check(twentyTimesFrame == 833_333 && normalFrame / twentyTimesFrame == 20, "20.0x 未将合成周期缩短为二十分之一");
Check(normalAfterRelease == normalFrame, "退出快进后未恢复 1.0x 周期");

// 小数倍率走同一个整数百分比协议，不能被 UI 的显示格式或核心边界截成整数倍。
long[] decimalScalars = [110, 140, 650];
long previousDecimalFrame = normalFrame;
foreach (long scalar in decimalScalars)
{
    long frame = CompositorTiming.CalculateTicksPerFrame(hostFrequency, 60, scalar);
    Check(frame < previousDecimalFrame && frame > twentyTimesFrame,
        $"{scalar / 100.0:0.0}x 没有得到单调且有效的合成周期");
    previousDecimalFrame = frame;
}

// 没有 buffer 时 SurfaceFlinger 也使用同一动态计时入口；20.0x 的无 VSync 等待约 0.833ms，
// 必须小于 1ms，避免空队列轮询把快进锁回接近正常速度。
long unboundedNormalWait = CompositorTiming.CalculateUnboundedWaitTicks(hostFrequency, 100);
long unboundedTurboWait = CompositorTiming.CalculateUnboundedWaitTicks(hostFrequency, 2000);
Check(unboundedNormalWait == 16_666_666, "无 VSync 正常等待周期错误");
Check(unboundedTurboWait == 833_333 && unboundedTurboWait < hostFrequency / 1000,
    "无 buffer 的 20.0x 等待仍被 1ms 下限限制");

// 宿主丢帧只在来宾倍率高于真实时间时启用；退出快进后重建 pacer 基准，下一帧不会沿用旧节拍。
Check(!CompositorTiming.IsTurbo(100) && CompositorTiming.IsTurbo(110) && CompositorTiming.IsTurbo(2000),
    "Turbo 状态边界错误");
Check(CompositorTiming.CalculateTicksPerFrame(long.MaxValue, 1, 100) == long.MaxValue,
    "高精度宿主频率计算发生整数溢出");
Check(CompositorTiming.CalculateTicksPerFrame(1, long.MaxValue, long.MaxValue) == 1,
    "超出时钟分辨率时没有保留至少一个 tick 的周期");

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

// 快进开启时宿主可能丢弃同一时间窗内的多余呈现；退出时 Reset 必须立即放行新的首帧，
// 否则旧的快进节拍会让恢复正常速度后的第一帧继续被错误丢弃。
var turboPacer = new UnboundedPresentPacer(6000, 60);
Check(turboPacer.TrySchedulePresent(0), "快进宿主丢帧路径未建立首帧");
Check(!turboPacer.TrySchedulePresent(1), "快进宿主丢帧路径未抑制过密呈现");
turboPacer.Reset();
Check(turboPacer.TrySchedulePresent(1), "退出快进后 pacer 未恢复首帧呈现");

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

TurboIntegrationTests.Run(Check);

Console.WriteLine($"PresentationPacingTests: {checks} checks passed (turbo timing, empty-buffer refresh, presentation lifecycle and concurrency)");
