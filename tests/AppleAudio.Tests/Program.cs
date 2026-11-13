using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Audio.Backends.Apple.Native;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Server.Sink;
using Ryujinx.Common;
using Ryujinx.Cpu;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Buffer = Ryujinx.Audio.Common.AudioBuffer;

static class Program
{
    private static int _checks;
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        _checks++;
    }
    private static void Throws(Action action, string message)
    {
        try { action(); } catch (ArgumentException) { _checks++; return; }
        throw new Exception(message);
    }
    private static Buffer Pcm(params short[] samples) => new() { Data = MemoryMarshal.AsBytes(samples.AsSpan()).ToArray() };

    public static void Main()
    {
        short[] range = new short[65536];
        float[] converted = new float[range.Length];
        for (int i = 0; i < range.Length; i++) range[i] = (short)(i + short.MinValue);
        ApplePcmConverter.CopyChannel(MemoryMarshal.AsBytes(range.AsSpan()), SampleFormat.PcmInt16, 1, 0, converted);
        for (int i = 0; i < range.Length; i++)
            Check(BitConverter.SingleToInt32Bits(converted[i]) == BitConverter.SingleToInt32Bits((float)range[i] / short.MaxValue), "PCM16 precision changed");
        Throws(() => ApplePcmConverter.CopyChannel(new byte[3], SampleFormat.PcmInt16, 1, 0, new float[1]), "Partial PCM frame accepted");

        using (AppleHardwareDeviceDriver driver = new())
        {
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            session.Start();
            Check(AVFoundation.EngineAllocations == 0, "Empty session started an engine");
            Buffer first = Pcm(short.MinValue, short.MaxValue, 0, 1234);
            Buffer second = Pcm(99, -99);
            session.QueueBuffer(first);
            Check(AVFoundation.EngineAllocations == 1, "First packet did not start one engine");
            Check(AVFoundation.ReadChannel(AVFoundation.Pending[0].Buffer, 0)[0] == (float)short.MinValue / short.MaxValue, "Left channel mismatch");
            Check(AVFoundation.ReadChannel(AVFoundation.Pending[0].Buffer, 1)[1] == (float)1234 / short.MaxValue, "Right channel mismatch");
            session.QueueBuffer(second);
            Check(!session.WasBufferFullyConsumed(second), "Later queued packet reported consumed");
            AVFoundation.Complete(1);
            Check(session.WasBufferFullyConsumed(second) && !session.WasBufferFullyConsumed(first), "Out-of-order completion failed");
            AVFoundation.Complete();
            Check(session.GetPlayedSampleCount() == 3, "Frame accounting failed");
            int allocations = AVFoundation.PcmAllocations;
            int playCalls = AVFoundation.PlayCalls;
            for (int i = 0; i < 100; i++)
            {
                Check(session.TryQueuePcm16(new short[] { 11, 22 }), "Fast PCM16 path missing");
                AVFoundation.Complete();
            }
            Check(AVFoundation.PcmAllocations == allocations, "Steady playback allocated native PCM buffers");
            Check(AVFoundation.PlayCalls == playCalls, "Steady playback repeatedly called Play");
            session.Stop();
            session.TryQueuePcm16(new short[] { 1, 2 });
            Check(AVFoundation.PlayCalls == playCalls, "Paused queue restarted playback");
            session.Start();
            Check(AVFoundation.PlayCalls == playCalls + 1, "Resume failed");
            session.Dispose();
            AVFoundation.Complete();
            Check(AVFoundation.LiveObjects == 0, "Dispose leaked native objects");
        }

        using (AppleHardwareDeviceDriver driver = new())
        {
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmFloat, 48000, 2);
            Check(!session.TryQueuePcm16(new short[] { 1, 2 }), "Unsupported fast format accepted");
            float[] values = { -1.25f, float.NaN, 0.125f, -0f };
            session.QueueBuffer(new Buffer { Data = MemoryMarshal.AsBytes(values.AsSpan()).ToArray() });
            Check(AVFoundation.ReadChannel(AVFoundation.Pending[0].Buffer, 0)[0] == -1.25f, "Float values changed");
            Check(float.IsNaN(AVFoundation.ReadChannel(AVFoundation.Pending[0].Buffer, 1)[0]), "Float NaN changed");
            AVFoundation.Complete();
            Throws(() => session.QueueBuffer(new Buffer { Data = new byte[7] }), "Partial frame accepted");
        }
        Check(AVFoundation.LiveObjects == 0, "Float session leaked");

        using (AppleHardwareDeviceDriver driver = new())
        {
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 1);
            for (int i = 0; i < 12; i++) session.TryQueuePcm16(new short[] { 1 });
            for (int i = 0; i < 12; i++) AVFoundation.Complete();
            Check(AVFoundation.LiveObjects == 3 + 8 * 2, "PCM cache count is not bounded");
            session.TryQueuePcm16(new short[600000]);
            AVFoundation.Complete();
            Check(AVFoundation.LiveObjects == 3 + 8 * 2, "Oversized PCM buffer retained");
        }
        Check(AVFoundation.LiveObjects == 0, "Bounded cache leaked");

        // 从真实 DSP sink 到硬件快路径：覆盖单声道、立体声及 5.1 的不足输入与完整帧契约。
        foreach (uint channels in new uint[] { 1, 2, 6 })
        {
            using AppleHardwareDeviceDriver driver = new();
            using HardwareDeviceImpl device = new(driver, channels, 48000, new TickSource(19_200_000));
            for (uint inputs = 0; inputs <= channels; inputs++)
            {
                float[] mix = new float[240 * channels];
                DeviceSink sink = new();
                sink.Parameter.InputCount = inputs;
                for (int c = 0; c < channels; c++)
                {
                    sink.Parameter.Input[c] = (byte)c;
                    Array.Fill(mix, 1000f + c, c * 240, 240);
                }
                using CommandList commands = new(null, mix, 240, 48000, channels, 0);
                commands.AddCommand((ICommand)new DeviceSinkCommand().Initialize(0, sink, 0, mix, 0));
                commands.Process(device);
                for (int c = 0; c < channels; c++)
                {
                    float[] pcm = AVFoundation.ReadChannel(AVFoundation.Pending[0].Buffer, c);
                    Check(pcm.Length == 240, "DSP sent partial frames");
                    foreach (float sample in pcm)
                        Check(sample == (c < inputs ? (1000f + c) / short.MaxValue : 0f), "DSP channel padding mismatch");
                }
                AVFoundation.Complete();
            }
            Throws(() => device.AppendBuffer(new short[1], channels), "Partial hardware packet accepted");
        }
        Check(AVFoundation.LiveObjects == 0, "DSP sink lifecycle leaked");

        using (AppleHardwareDeviceDriver driver = new())
        {
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            AVFoundation.FailStart = true;
            try { session.TryQueuePcm16(new short[] { 1, 2 }); throw new Exception("Engine start failure accepted"); }
            catch (InvalidOperationException) { Check(AVFoundation.LiveObjects == 0, "Failed engine initialization leaked"); }
            AVFoundation.FailStart = false;
            session.TryQueuePcm16(new short[] { 1, 2 });
            AVFoundation.Complete();
        }

        Check(AudioDeadlineWait.MillisecondsUntil(1, 5_000_000) == 5, "Deadline rounded down");
        Check(AudioDeadlineWait.MillisecondsUntil(5, 5) == 0, "Expired deadline waited");
        Check(AudioDeadlineWait.MillisecondsUntil(long.MinValue, long.MaxValue) == int.MaxValue, "Deadline overflow");
        Check(AudioDeadlineWait.NanosecondsPerUpdate(100) == 5_000_000, "1X audio cadence changed");
        Check(AudioDeadlineWait.NanosecondsPerUpdate(110) == 4_545_454, "1.1X audio cadence lost precision");
        Check(AudioDeadlineWait.NanosecondsPerUpdate(200) == 2_500_000, "2X audio cadence mismatch");
        Check(AudioDeadlineWait.NanosecondsPerUpdate(650) == 769_230, "6.5X audio cadence lost precision");
        Check(AudioDeadlineWait.NanosecondsPerUpdate(2000) == 250_000, "20X audio cadence rounded to milliseconds");
        Throws(() => AudioDeadlineWait.NanosecondsPerUpdate(0), "Zero audio clock scalar accepted");
        using (ManualResetEvent stop = new(true))
        using (ManualResetEvent pause = new(true))
        {
            Task stopped = Task.Run(() => AudioDeadlineWait.WaitUntil(stop, pause, PerformanceCounter.ElapsedNanoseconds + 10_000_000_000));
            Check(stopped.Wait(TimeSpan.FromSeconds(1)), "Precise audio wait ignored stop");
            stop.Reset();
            pause.Reset();
            Task paused = Task.Run(() => AudioDeadlineWait.WaitUntil(stop, pause, PerformanceCounter.ElapsedNanoseconds + 10_000_000_000));
            Check(paused.Wait(TimeSpan.FromSeconds(1)), "Precise audio wait ignored pause");
        }
        CheckTurboAudio();
        using (AppleHardwareDeviceDriver driver = new())
        using (AudioProcessor processor = new(new TickSource(19_200_000) { TickScalar = 2000 }))
        {
            for (int restart = 0; restart < 3; restart++)
            {
                processor.Start(driver);
                processor.Wait();
                driver.GetPauseEvent().Reset();
                processor.Signal();
                Task stopped = Task.Run(() => { processor.RequestStop(); processor.Wait(); processor.Stop(); });
                Check(stopped.Wait(TimeSpan.FromSeconds(3)), "Paused DSP stop deadlocked");
                driver.GetPauseEvent().Set();
            }
        }
        Check(AVFoundation.LiveObjects == 0, "Audio lifecycle leaked objects");
        Console.WriteLine($"AppleAudio.Tests: {_checks} checks passed (managed native shim; Apple device validation still required)");
    }

    private static void CheckTurboAudio()
    {
        TickSource clock = new(19_200_000);
        using AppleHardwareDeviceDriver driver = new();
        using AudioProcessor processor = new(clock);
        processor.Start(driver);
        processor.Wait();

        try
        {
            // 所有 renderer session 共用倍率；快进不追加 PCM，已有尾音只能减少不能增长。
            uint channels = processor.OutputDevices[0].GetChannelCount();
            short[] pcm = new short[240 * channels];
            foreach (IHardwareDevice output in processor.OutputDevices) output.AppendBuffer(pcm, channels);
            int initialPending = AVFoundation.Pending.Count;
            Check(initialPending == processor.OutputDevices.Length, "Normal renderer output did not queue each session");
            int initialAllocations = AVFoundation.PcmAllocations;
            foreach (long scalar in new long[] { 110, 200, 650, 2000 })
            {
                clock.TickScalar = scalar;
                for (int i = 0; i < 1024; i++)
                    foreach (IHardwareDevice output in processor.OutputDevices) output.AppendBuffer(pcm, channels);
                Check(AVFoundation.Pending.Count == initialPending, "Turbo grew the native audio queue");
                Check(AVFoundation.PcmAllocations == initialAllocations, "Turbo allocated native PCM buffers");
            }
            while (AVFoundation.Pending.Count != 0) AVFoundation.Complete();

            // 使用真实 DSP 命令和生产 sink，验证静音没有跳过命令执行或拖住命令完成。
            float[] mix = new float[240 * channels];
            Array.Fill(mix, 1000f);
            DeviceSink sink = new();
            sink.Parameter.InputCount = channels;
            for (int channel = 0; channel < channels; channel++) sink.Parameter.Input[channel] = (byte)channel;
            CommandList commands = new(null, mix, 240, 48000, channels, 0);
            commands.AddCommand((ICommand)new VolumeCommand().Initialize(0.5f, 0, 0));
            commands.AddCommand((ICommand)new DeviceSinkCommand().Initialize(0, sink, 0, mix, 0));
            processor.Send(0, commands, 0, 0);
            processor.Signal();
            processor.Wait();
            Check(mix[0] == 500f, "Turbo skipped DSP processing");
            Check(!processor.HasRemainingCommands(0), "Turbo retained completed DSP commands");
            Check(AVFoundation.Pending.Count == 0, "Turbo DSP sink queued physical audio");

            clock.TickScalar = 100;
            foreach (IHardwareDevice output in processor.OutputDevices) output.AppendBuffer(pcm, channels);
            Check(AVFoundation.Pending.Count == initialPending, "1X did not resume all renderer outputs");
            while (AVFoundation.Pending.Count != 0) AVFoundation.Complete();

            // 实际走工作线程/邮箱/等待路径；宽松比例门槛只用于发现固定 5 ms 或 1 ms 限流回归。
            double normalMs = MeasureCadence(processor, clock, 100, 120);
            double doubleMs = MeasureCadence(processor, clock, 200, 120);
            double turboMs = MeasureCadence(processor, clock, 2000, 120);
            double restoredMs = MeasureCadence(processor, clock, 100, 120);
            Check(doubleMs < normalMs * 0.85, "2X renderer still used the normal cadence");
            Check(turboMs < normalMs / 6, "20X renderer retained a millisecond cadence floor");
            Check(restoredMs > normalMs * 0.65, "1X renderer did not restore normal cadence");
            Console.WriteLine($"Audio cadence, 120 updates: 1X={normalMs:F2} ms, 2X={doubleMs:F2} ms, 20X={turboMs:F2} ms, restored 1X={restoredMs:F2} ms");
        }
        finally
        {
            processor.Stop();
            while (AVFoundation.Pending.Count != 0) AVFoundation.Complete();
        }
        Check(AVFoundation.LiveObjects == 0, "Turbo audio lifecycle leaked native objects");
    }

    private static double MeasureCadence(AudioProcessor processor, TickSource clock, long tickScalar, int count)
    {
        clock.TickScalar = tickScalar;
        processor.Signal();
        processor.Wait();
        Stopwatch timer = Stopwatch.StartNew();
        for (int i = 0; i < count; i++)
        {
            processor.Signal();
            processor.Wait();
        }
        return timer.Elapsed.TotalMilliseconds;
    }
}
