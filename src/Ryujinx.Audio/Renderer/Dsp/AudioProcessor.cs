using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Utils;
using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Cpu;
using System;
using System.Threading;

namespace Ryujinx.Audio.Renderer.Dsp
{
    public class AudioProcessor : IDisposable
    {
        private const int MaxBufferedFrames = 5;
        private const int TargetBufferedFrames = 3;

        private enum MailboxMessage : uint
        {
            Start,
            Stop,
            RenderStart,
            RenderEnd,
        }

        private struct RendererSession
        {
            public CommandList CommandList;
            public int RenderingLimit;
            public ulong AppletResourceId;
        }

        private Mailbox<MailboxMessage> _mailbox;
        private RendererSession[] _sessionCommandList;
        private Thread _workerThread;

        public IHardwareDevice[] OutputDevices { get; private set; }

        private long _lastTime;
        private long _playbackEnds;
        private long _lastTickScalar;
        private readonly ITickSource _tickSource;
        private readonly ManualResetEvent _event;

        private ManualResetEvent _pauseEvent;
        private WaitHandle[] _pauseOrStop;

        /// <summary>借用模拟器时钟；管理线程读取倍率，DSP 输出使用同一时钟决定是否静音。</summary>
        /// <param name="tickSource">由模拟器持有的共享时钟，本对象不释放它。</param>
        public AudioProcessor(ITickSource tickSource)
        {
            _tickSource = tickSource ?? throw new ArgumentNullException(nameof(tickSource));
            _event = new ManualResetEvent(false);
        }

        private static uint GetHardwareChannelCount(IHardwareDeviceDriver deviceDriver)
        {
            // Get the real device driver (In case the compat layer is on top of it).
            deviceDriver = deviceDriver.GetRealDeviceDriver();

            if (deviceDriver.SupportsChannelCount(6))
            {
                return 6;
            }

            // NOTE: We default to stereo as this will get downmixed to mono by the compat layer if it's not compatible.
            return 2;
        }

        public void Start(IHardwareDeviceDriver deviceDriver)
        {
            OutputDevices = new IHardwareDevice[Constants.AudioRendererSessionCountMax];

            uint channelCount = GetHardwareChannelCount(deviceDriver);

            for (int i = 0; i < OutputDevices.Length; i++)
            {
                // TODO: Don't hardcode sample rate.
                OutputDevices[i] = new HardwareDeviceImpl(deviceDriver, channelCount, Constants.TargetSampleRate, _tickSource);
            }

            _mailbox = new Mailbox<MailboxMessage>();
            _sessionCommandList = new RendererSession[Constants.AudioRendererSessionCountMax];
            _event.Reset();
            _lastTime = PerformanceCounter.ElapsedNanoseconds;
            _playbackEnds = 0;
            _lastTickScalar = _tickSource.TickScalar;
            _pauseEvent = deviceDriver.GetPauseEvent();
            _pauseOrStop = _pauseEvent == null ? null : new WaitHandle[] { _pauseEvent, _event };

            StartThread();

            _mailbox.SendMessage(MailboxMessage.Start);

            if (_mailbox.ReceiveResponse() != MailboxMessage.Start)
            {
                throw new InvalidOperationException("Audio Processor Start response was invalid!");
            }
        }

        public void Stop()
        {
            RequestStop();
            _mailbox.SendMessage(MailboxMessage.Stop);

            if (_mailbox.ReceiveResponse() != MailboxMessage.Stop)
            {
                throw new InvalidOperationException("Audio Processor Stop response was invalid!");
            }

            _workerThread.Join();
            _mailbox.Dispose();
            _mailbox = null;

            foreach (IHardwareDevice device in OutputDevices)
            {
                device.Dispose();
            }
        }

        /// <summary>管理线程等待退出前先中断期限等待和暂停门；仍由邮箱完成停止握手。</summary>
        public void RequestStop() => _event.Set();

        public void Send(int sessionId, CommandList commands, int renderingLimit, ulong appletResourceId)
        {
            _sessionCommandList[sessionId] = new RendererSession
            {
                CommandList = commands,
                RenderingLimit = renderingLimit,
                AppletResourceId = appletResourceId,
            };
        }

        public bool HasRemainingCommands(int sessionId)
        {
            return _sessionCommandList[sessionId].CommandList != null;
        }

        public void Signal()
        {
            _mailbox.SendMessage(MailboxMessage.RenderStart);
        }

        public void Wait()
        {
            if (_mailbox.ReceiveResponse() != MailboxMessage.RenderEnd)
            {
                throw new InvalidOperationException("Audio Processor Wait response was invalid!");
            }

            long tickScalar = _tickSource.TickScalar;
            long increment = AudioDeadlineWait.NanosecondsPerUpdate(tickScalar);
            long timeNow = PerformanceCounter.ElapsedNanoseconds;

            if (tickScalar != _lastTickScalar)
            {
                // 倍率切换以当前时刻重新起算，避免沿用旧播放积压或补发过期音频事件。
                _lastTickScalar = tickScalar;
                _lastTime = timeNow;
                _playbackEnds = timeNow;
            }

            if (tickScalar > ITickSource.RealityTickScalar)
            {
                // 快进只推进 DSP/guest 音频状态；最终 PCM 由 HardwareDeviceImpl 丢弃。
                // 不用真实播放时长估算积压，也不把亚毫秒期限向上取整成 1 ms。
                long deadline = _lastTime + increment;
                if (timeNow - deadline > increment * MaxBufferedFrames)
                {
                    deadline = timeNow;
                }

                AudioDeadlineWait.WaitUntil(_event, _pauseEvent, deadline);
                _lastTime = deadline;
                return;
            }

            if (timeNow > _playbackEnds)
            {
                // Playback has restarted.
                _playbackEnds = timeNow;
            }

            _playbackEnds += increment;

            // The number of frames we are behind where the timer says we should be.
            long framesBehind = (timeNow - _lastTime) / increment;

            // The number of frames yet to play on the backend.
            long bufferedFrames = (_playbackEnds - timeNow) / increment + framesBehind;

            // If we've entered a situation where a lot of buffers will be queued on the backend,
            // Skip some audio frames so that playback can catch up.
            if (bufferedFrames > MaxBufferedFrames)
            {
                // Skip a few frames so that we're not too far behind. (the target number of frames)
                _lastTime += increment * (bufferedFrames - TargetBufferedFrames);
            }

            while (timeNow < _lastTime + increment)
            {
                if (_event.WaitOne(AudioDeadlineWait.MillisecondsUntil(timeNow, _lastTime + increment)))
                {
                    break;
                }

                timeNow = PerformanceCounter.ElapsedNanoseconds;
            }

            _lastTime += increment;
        }

        private void StartThread()
        {
            _workerThread = new Thread(Work)
            {
                Name = "AudioProcessor.Worker",
            };

            _workerThread.Start();
        }

        private void Work()
        {
            if (_mailbox.ReceiveMessage() != MailboxMessage.Start)
            {
                throw new InvalidOperationException("Audio Processor Start message was invalid!");
            }

            _mailbox.SendResponse(MailboxMessage.Start);
            _mailbox.SendResponse(MailboxMessage.RenderEnd);

            Logger.Info?.Print(LogClass.AudioRenderer, "Starting audio processor");

            while (true)
            {
                if (_pauseOrStop != null)
                {
                    WaitHandle.WaitAny(_pauseOrStop);
                }

                MailboxMessage message = _mailbox.ReceiveMessage();

                if (message == MailboxMessage.Stop)
                {
                    break;
                }

                if (message == MailboxMessage.RenderStart)
                {
                    long startTicks = PerformanceCounter.ElapsedNanoseconds;

                    for (int i = 0; i < _sessionCommandList.Length; i++)
                    {
                        if (_sessionCommandList[i].CommandList != null)
                        {
                            if (!_event.WaitOne(0))
                            {
                                _sessionCommandList[i].CommandList.Process(OutputDevices[i]);
                            }
                            _sessionCommandList[i].CommandList.Dispose();
                            _sessionCommandList[i] = default;
                        }
                    }

                    long endTicks = PerformanceCounter.ElapsedNanoseconds;

                    long elapsedTime = endTicks - startTicks;

                    if (Constants.AudioProcessorMaxUpdateTime < elapsedTime)
                    {
                        Logger.Debug?.Print(LogClass.AudioRenderer, $"DSP too slow (exceeded by {elapsedTime - Constants.AudioProcessorMaxUpdateTime}ns)");
                    }

                    _mailbox.SendResponse(MailboxMessage.RenderEnd);
                }
            }

            Logger.Info?.Print(LogClass.AudioRenderer, "Stopping audio processor");
            _mailbox.SendResponse(MailboxMessage.Stop);
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
                _event.Dispose();
                _mailbox?.Dispose();
            }
        }
    }
}
