using System;

namespace Ryujinx.Graphics.Gpu
{
    /// <summary>
    /// 仅调度 Unbounded 模式的宿主呈现，不改变来宾时钟、GPU 命令处理或游戏帧率。
    /// UI 可更新目标，渲染线程申请呈现；短锁保护完整节拍状态，同值更新不重置时间基准。
    /// </summary>
    internal sealed class UnboundedPresentPacer
    {
        private readonly object _lock = new();
        private readonly long _clockFrequency;
        private int _targetFps;
        private long _ticksPerFrame;
        private long _lastPresentTicks;
        private bool _hasPresented;

        /// <summary>clockFrequency 是每秒时钟 tick 数且必须为正；targetFps 是最终呈现目标。</summary>
        public UnboundedPresentPacer(long clockFrequency, int targetFps)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(clockFrequency);
            _clockFrequency = clockFrequency;
            SetTargetFps(targetFps);
        }

        /// <summary>目标归一化为至少 1；只有真实目标改变才允许重新建立首帧基准。</summary>
        public void SetTargetFps(int targetFps)
        {
            targetFps = Math.Max(1, targetFps);
            lock (_lock)
            {
                if (_targetFps == targetFps)
                {
                    return;
                }

                _targetFps = targetFps;
                _ticksPerFrame = Math.Max(1, _clockFrequency / targetFps);
                _hasPresented = false;
            }
        }

        /// <summary>模式切换重新建立首帧基准；相同模式不得反复调用此接口。</summary>
        public void Reset()
        {
            lock (_lock)
            {
                _hasPresented = false;
            }
        }

        /// <summary>仅在有就绪帧时调用，成功即占用当前时间点；不为没有帧的轮询消耗节拍。</summary>
        public bool TrySchedulePresent(long ticks)
        {
            lock (_lock)
            {
                if (_hasPresented && ticks >= _lastPresentTicks && ticks - _lastPresentTicks < _ticksPerFrame)
                {
                    return false;
                }

                _hasPresented = true;
                _lastPresentTicks = ticks;
                return true;
            }
        }
    }
}
