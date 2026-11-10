using Ryujinx.Audio.Common;
using System;

namespace Ryujinx.Audio.Integration
{
    public interface IHardwareDeviceSession : IDisposable
    {
        bool RegisterBuffer(AudioBuffer buffer);

        void UnregisterBuffer(AudioBuffer buffer);

        void QueueBuffer(AudioBuffer buffer);

        /// <summary>
        /// 尝试同步复制交错 PCM16 样本。返回 true 后调用方可立即复用内存；
        /// 返回 false 表示后端不支持此路径，调用方应使用 QueueBuffer。
        /// </summary>
        bool TryQueuePcm16(ReadOnlySpan<short> samples) => false;

        bool WasBufferFullyConsumed(AudioBuffer buffer);

        void SetVolume(float volume);

        float GetVolume();

        ulong GetPlayedSampleCount();

        void Start();

        void Stop();

        void PrepareToClose();
    }
}
