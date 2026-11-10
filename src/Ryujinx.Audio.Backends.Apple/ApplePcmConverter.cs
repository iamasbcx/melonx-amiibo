using Ryujinx.Audio.Common;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.Apple
{
    /// <summary>直接写入非交错 Float32 声道，保持原 PCM16 饱和量化后的 /32767 转换精度。</summary>
    internal static class ApplePcmConverter
    {
        public static void CopyChannel(ReadOnlySpan<byte> source, SampleFormat format, int channels, int channel, Span<float> destination)
        {
            int sampleSize = format switch
            {
                SampleFormat.PcmInt16 => sizeof(short),
                SampleFormat.PcmFloat => sizeof(float),
                _ => throw new ArgumentException("Unsupported PCM sample format.", nameof(format)),
            };

            if (channels <= 0 || (uint)channel >= (uint)channels ||
                source.Length != checked(destination.Length * channels * sampleSize))
            {
                throw new ArgumentException("PCM channel or frame dimensions are invalid.");
            }

            if (format == SampleFormat.PcmInt16)
            {
                ReadOnlySpan<short> samples = MemoryMarshal.Cast<byte, short>(source);
                for (int frame = 0; frame < destination.Length; frame++)
                {
                    destination[frame] = (float)samples[frame * channels + channel] / short.MaxValue;
                }
            }
            else
            {
                ReadOnlySpan<float> samples = MemoryMarshal.Cast<byte, float>(source);
                for (int frame = 0; frame < destination.Length; frame++)
                {
                    destination[frame] = samples[frame * channels + channel];
                }
            }
        }
    }
}
