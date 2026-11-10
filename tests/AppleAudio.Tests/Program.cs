using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Audio.Backends.Apple.Native;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Server.Sink;
using System;
using System.Runtime.InteropServices;
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
            using HardwareDeviceImpl device = new(driver, channels, 48000);
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
        using (AppleHardwareDeviceDriver driver = new())
        using (AudioProcessor processor = new())
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
}
