using Ryujinx.Audio.Common;
using Ryujinx.Cpu;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Integration
{
    public class HardwareDeviceImpl : IHardwareDevice
    {
        private readonly IHardwareDeviceSession _session;
        private readonly uint _channelCount;
        private readonly uint _sampleRate;
        private readonly ITickSource _tickSource;
        private uint _currentBufferTag;

        private readonly byte[] _buffer;

        /// <summary>持有并释放硬件会话；借用 guest 时钟，在快进时仅丢弃最终 PCM。</summary>
        /// <param name="deviceDriver">创建输出会话的驱动，其生命周期由调用方管理。</param>
        /// <param name="channelCount">输出声道数，提交的 PCM 必须匹配此值。</param>
        /// <param name="sampleRate">正常速度下的硬件采样率。</param>
        /// <param name="tickSource">模拟器共享时钟；倍率大于 1X 时禁止追加物理播放队列。</param>
        public HardwareDeviceImpl(IHardwareDeviceDriver deviceDriver, uint channelCount, uint sampleRate, ITickSource tickSource)
        {
            _tickSource = tickSource ?? throw new ArgumentNullException(nameof(tickSource));
            _session = deviceDriver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, sampleRate, channelCount);
            _channelCount = channelCount;
            _sampleRate = sampleRate;
            _currentBufferTag = 0;

            _buffer = new byte[Constants.TargetSampleCount * channelCount * sizeof(ushort)];

            _session.Start();
        }

        public void AppendBuffer(ReadOnlySpan<short> data, uint channelCount)
        {
            if (channelCount != _channelCount || data.Length != _buffer.Length / sizeof(short))
            {
                throw new ArgumentException("Renderer PCM packet must match the device channel count and frame size.", nameof(data));
            }

            // DSP 命令仍完整执行，guest 波形消费状态正常推进；仅阻止 20X 样本堆积到真实播放队列。
            // 已排队的短尾音由后端自然消费，恢复 1X 后直接接续新样本，不回放快进期间的音频。
            if (_tickSource.TickScalar > ITickSource.RealityTickScalar)
            {
                return;
            }

            if (_session.TryQueuePcm16(data))
            {
                return;
            }

            data.CopyTo(MemoryMarshal.Cast<byte, short>(new Span<byte>(_buffer)));

            _session.QueueBuffer(new AudioBuffer
            {
                DataPointer = _currentBufferTag++,
                Data = _buffer,
                DataSize = (ulong)_buffer.Length,
            });

            _currentBufferTag %= 4;
        }

        public void SetVolume(float volume)
        {
            _session.SetVolume(volume);
        }

        public float GetVolume()
        {
            return _session.GetVolume();
        }

        public uint GetChannelCount()
        {
            return _channelCount;
        }

        public uint GetSampleRate()
        {
            return _sampleRate;
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _session.Dispose();
            }
        }
    }
}
