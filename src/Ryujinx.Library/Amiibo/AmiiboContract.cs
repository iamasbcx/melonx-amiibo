using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Ryujinx.Library.Amiibo
{
    /// <summary>仅供当前 iOS 前端使用的固定宽度契约；不跨边界传递托管对象或字符串指针。</summary>
    internal static class AmiiboContract
    {
        public const uint Version = 1;
        public const uint StateSize = 24;
        public const uint RequestSize = 32;
        public const uint Running = 1;
        public const uint Paused = 2;
        public const uint Searching = 4;

        public static string ReadId(ReadOnlySpan<byte> bytes)
        {
            if (bytes.Length != 16)
            {
                return null;
            }

            foreach (byte value in bytes)
            {
                if (!((value >= '0' && value <= '9') || (value >= 'A' && value <= 'F')))
                {
                    return null;
                }
            }

            return Encoding.ASCII.GetString(bytes);
        }
    }

    internal enum AmiiboResult : int
    {
        Ok = 0,
        AbiMismatch = 1,
        InvalidArgument = 2,
        BufferTooSmall = 3,
        NotRunning = 4,
        Paused = 5,
        NotSearching = 6,
        StaleSession = 7,
        StaleDetection = 8,
        Busy = 9,
        InternalError = 10,
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct AmiiboStateNative
    {
        public uint AbiVersion;
        public uint StructSize;
        public uint SessionId;
        public uint DetectionEpoch;
        public uint Flags;
        public int LastResult;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal unsafe struct AmiiboScanNative
    {
        public uint AbiVersion;
        public uint StructSize;
        public uint SessionId;
        public uint DetectionEpoch;
        public fixed byte AmiiboId[16];
    }
}
