using Ryujinx.Audio.Backends.Apple.Native;
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;

namespace Ryujinx.Audio.Backends.Apple
{
    /// <summary>
    /// 按首包初始化 AVAudioEngine，并复用已完成的 PCM 缓冲。
    /// 会话锁串行化入队、完成和关闭；AVAudioPlayerNode.Stop 在锁外执行，避免回调互等。
    /// </summary>
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    sealed unsafe class AppleHardwareDeviceSession : HardwareDeviceSessionOutputBase
    {
        private const int MaxCachedBuffers = 8;
        private const int MaxCachedBytes = 2 * 1024 * 1024;
        private static long _nextToken;
        private static readonly ConcurrentDictionary<long, AppleAudioBuffer> _registrations = new();
        // 原生复制的 block 可能晚于会话关闭才释放，回调委托与 descriptor 必须终身有效。
        private static readonly AVFoundation.CompletionCallback _completionCallback = OnBufferCompleted;

        private readonly AppleHardwareDeviceDriver _driver;
        private readonly ManualResetEvent _updateRequiredEvent;
        private readonly int _bytesPerFrame;
        private readonly object _lock = new();
        private readonly Dictionary<ulong, AppleAudioBuffer> _pending = new();
        private readonly List<AppleAudioBuffer> _free = new(MaxCachedBuffers);
        private long _cachedBytes;
        private nint _engine;
        private nint _playerNode;
        private nint _format;
        private ulong _playedSampleCount;
        private bool _started;
        private bool _playing;
        private bool _disposed;
        private float _volume = 1f;

        public AppleHardwareDeviceSession(AppleHardwareDeviceDriver driver, IVirtualMemoryManager memoryManager,
            SampleFormat requestedSampleFormat, uint requestedSampleRate, uint requestedChannelCount)
            : base(memoryManager, requestedSampleFormat, requestedSampleRate, requestedChannelCount)
        {
            // 及早拒绝非法格式；实际输出固定为 Float32，输入可为 PCM16 或 Float32。
            _ = AppleHardwareDeviceDriver.GetAudioFormat(requestedSampleFormat);
            if (requestedChannelCount == 0)
            {
                throw new ArgumentOutOfRangeException(nameof(requestedChannelCount));
            }

            _driver = driver;
            _updateRequiredEvent = driver.GetUpdateRequiredEvent();
            _bytesPerFrame = checked(BackendHelper.GetSampleSize(requestedSampleFormat) * (int)requestedChannelCount);
        }

        private void SetupAudioEngine()
        {
            if (_engine != nint.Zero)
            {
                return;
            }

            try
            {
                _engine = AVFoundation.Init(AVFoundation.Alloc("AVAudioEngine"));
                _playerNode = AVFoundation.Init(AVFoundation.Alloc("AVAudioPlayerNode"));
                _format = AVFoundation.InitAudioFormat(AVFoundation.Alloc("AVAudioFormat"),
                    AppleHardwareDeviceDriver.GetAudioFormat(RequestedSampleFormat), RequestedSampleRate, RequestedChannelCount);
                if (_engine == nint.Zero || _playerNode == nint.Zero || _format == nint.Zero)
                {
                    throw new InvalidOperationException("Failed to initialize AVFoundation audio objects.");
                }

                AVFoundation.AttachNode(_engine, _playerNode);
                AVFoundation.Connect(_engine, _playerNode, AVFoundation.MainMixerNode(_engine), _format);
                AVFoundation.Prepare(_engine);
                if (!AVFoundation.Start(_engine, out nint error))
                {
                    throw new InvalidOperationException($"AVAudioEngine failed to start. Error object: 0x{error:x}.");
                }

                UpdateEffectiveVolume();
            }
            catch
            {
                ReleaseAudioEngine();
                throw;
            }
        }

        private static void OnBufferCompleted(nint block)
        {
            try
            {
                long token = (long)AVFoundation.GetBlockContext(block);
                if (_registrations.TryGetValue(token, out AppleAudioBuffer buffer))
                {
                    buffer.Owner.CompleteBuffer(buffer);
                }
            }
            catch (Exception exception)
            {
                // 托管异常不得穿越 Objective-C 回调边界。
                Logger.Error?.Print(LogClass.Audio, $"AVFoundation completion failed: {exception.GetType().Name}: {exception.Message}");
            }
        }

        private void CompleteBuffer(AppleAudioBuffer buffer)
        {
            lock (_lock)
            {
                if (_disposed || !buffer.Pending)
                {
                    return;
                }

                buffer.Pending = false;
                _pending.Remove(buffer.HostTag);
                Interlocked.Add(ref _playedSampleCount, buffer.FrameCount);
                ReturnBuffer(buffer);
                _updateRequiredEvent.Set();
            }
        }

        private long BufferBytes(AppleAudioBuffer buffer) => (long)buffer.Capacity * RequestedChannelCount * sizeof(float);

        private AppleAudioBuffer RentBuffer(uint frameCount)
        {
            for (int i = 0; i < _free.Count; i++)
            {
                AppleAudioBuffer cached = _free[i];
                if (cached.Capacity >= frameCount)
                {
                    _free.RemoveAt(i);
                    _cachedBytes -= BufferBytes(cached);
                    return cached;
                }
            }

            nint pcmBuffer = AVFoundation.InitPcmBuffer(AVFoundation.Alloc("AVAudioPCMBuffer"), _format, frameCount);
            if (pcmBuffer == nint.Zero)
            {
                throw new InvalidOperationException("Failed to allocate AVAudioPCMBuffer.");
            }

            nint block = nint.Zero;
            try
            {
                long token = Interlocked.Increment(ref _nextToken);
                if (token <= 0 || (long)(nint)token != token)
                {
                    throw new InvalidOperationException("AVFoundation completion token space exhausted.");
                }

                block = AVFoundation.CreateCompletionBlock((nint)token, _completionCallback);
                AppleAudioBuffer buffer = new(this, token, frameCount, pcmBuffer, block);
                if (!_registrations.TryAdd(token, buffer))
                {
                    throw new InvalidOperationException("Duplicate AVFoundation completion token.");
                }

                return buffer;
            }
            catch
            {
                AVFoundation.DestroyCompletionBlock(block);
                AVFoundation.Release(pcmBuffer);
                throw;
            }
        }

        private static void ReleaseBuffer(AppleAudioBuffer buffer)
        {
            _registrations.TryRemove(buffer.Token, out _);
            AVFoundation.DestroyCompletionBlock(buffer.CompletionBlock);
            AVFoundation.Release(buffer.NativeBuffer);
        }

        private void ReturnBuffer(AppleAudioBuffer buffer)
        {
            long bytes = BufferBytes(buffer);
            if (_free.Count < MaxCachedBuffers && _cachedBytes + bytes <= MaxCachedBytes)
            {
                _free.Add(buffer);
                _cachedBytes += bytes;
            }
            else
            {
                ReleaseBuffer(buffer);
            }
        }

        private void FillBuffer(AppleAudioBuffer buffer, ReadOnlySpan<byte> samples, uint frames)
        {
            AVFoundation.SetFrameLength(buffer.NativeBuffer, frames);
            AVFoundation.AudioBufferList* list = AVFoundation.GetMutableAudioBufferList(buffer.NativeBuffer);
            if (list == null || list->NumberBuffers != RequestedChannelCount)
            {
                throw new InvalidOperationException("AVAudioPCMBuffer returned an unexpected buffer count.");
            }

            int frameCount = checked((int)frames);
            int channelCount = checked((int)RequestedChannelCount);
            int channelBytes = checked(frameCount * sizeof(float));
            AVFoundation.AudioBuffer* nativeBuffers = &list->Buffer;
            for (int channel = 0; channel < channelCount; channel++)
            {
                AVFoundation.AudioBuffer* native = &nativeBuffers[channel];
                if (native->Data == nint.Zero || native->DataByteSize < (uint)channelBytes)
                {
                    throw new InvalidOperationException($"AVAudioPCMBuffer channel {channel} is too small.");
                }

                ApplePcmConverter.CopyChannel(samples, RequestedSampleFormat, channelCount, channel,
                    new Span<float>((void*)native->Data, frameCount));
            }
        }

        private void QueueSamples(ReadOnlySpan<byte> samples, ulong hostTag)
        {
            if (samples.IsEmpty || samples.Length % _bytesPerFrame != 0)
            {
                throw new ArgumentException("Audio buffer does not contain a whole number of PCM frames.", nameof(samples));
            }

            lock (_lock)
            {
                if (_disposed)
                {
                    return;
                }

                if (_pending.ContainsKey(hostTag))
                {
                    throw new InvalidOperationException("Audio buffer is already queued.");
                }

                SetupAudioEngine();
                uint frames = (uint)(samples.Length / _bytesPerFrame);
                AppleAudioBuffer buffer = RentBuffer(frames);
                try
                {
                    FillBuffer(buffer, samples, frames);
                }
                catch
                {
                    ReleaseBuffer(buffer);
                    throw;
                }

                buffer.HostTag = hostTag;
                buffer.FrameCount = frames;
                buffer.Pending = true;
                _pending.Add(hostTag, buffer);
                AVFoundation.ScheduleBuffer(_playerNode, buffer.NativeBuffer, buffer.CompletionBlock);
                if (_started && !_playing)
                {
                    AVFoundation.Play(_playerNode);
                    _playing = true;
                }
            }
        }

        public override void QueueBuffer(AudioBuffer buffer) => QueueSamples(buffer.Data, buffer.HostTag);

        public override bool TryQueuePcm16(ReadOnlySpan<short> samples)
        {
            if (RequestedSampleFormat != SampleFormat.PcmInt16)
            {
                return false;
            }

            QueueSamples(MemoryMarshal.AsBytes(samples), AudioBuffer.NextHostTag());
            return true;
        }

        public void UpdateEffectiveVolume()
        {
            lock (_lock)
            {
                if (_playerNode != nint.Zero && !_disposed)
                {
                    AVFoundation.SetVolume(_playerNode, Math.Clamp(_driver.Volume * _volume, 0f, 1f));
                }
            }
        }

        public override void Start()
        {
            lock (_lock)
            {
                if (!_disposed && !_started)
                {
                    _started = true;
                    if (_playerNode != nint.Zero)
                    {
                        AVFoundation.Play(_playerNode);
                        _playing = true;
                    }
                }
            }
        }

        public override void Stop()
        {
            lock (_lock)
            {
                if (!_disposed && _started)
                {
                    _started = false;
                    _playing = false;
                    if (_playerNode != nint.Zero)
                    {
                        AVFoundation.Pause(_playerNode);
                    }
                }
            }
        }

        public override ulong GetPlayedSampleCount() => Interlocked.Read(ref _playedSampleCount);
        public override float GetVolume() => _volume;
        public override void SetVolume(float volume)
        {
            lock (_lock)
            {
                _volume = volume;
                UpdateEffectiveVolume();
            }
        }

        public override bool WasBufferFullyConsumed(AudioBuffer buffer)
        {
            lock (_lock)
            {
                return !_pending.ContainsKey(buffer.HostTag);
            }
        }

        public override void PrepareToClose() { }
        public override void UnregisterBuffer(AudioBuffer buffer) { }

        private void ReleaseAudioEngine()
        {
            AVFoundation.Release(_format);
            AVFoundation.Release(_playerNode);
            AVFoundation.Release(_engine);
            _format = _playerNode = _engine = nint.Zero;
        }

        public override void Dispose()
        {
            if (!_driver.Unregister(this))
            {
                return;
            }

            lock (_lock)
            {
                _disposed = true;
                foreach (AppleAudioBuffer buffer in _pending.Values)
                {
                    _registrations.TryRemove(buffer.Token, out _);
                }
            }

            // Stop 可能等待完成回调。撤销注册并释放锁后才进入原生代码。
            if (_playerNode != nint.Zero)
            {
                AVFoundation.Stop(_playerNode);
            }

            lock (_lock)
            {
                foreach (AppleAudioBuffer buffer in _pending.Values)
                {
                    ReleaseBuffer(buffer);
                }

                foreach (AppleAudioBuffer buffer in _free)
                {
                    ReleaseBuffer(buffer);
                }

                _pending.Clear();
                _free.Clear();
                _cachedBytes = 0;
                ReleaseAudioEngine();
            }

            GC.SuppressFinalize(this);
            Logger.Debug?.Print(LogClass.Audio, "Disposed AVFoundation audio session.");
        }
    }
}
