using Ryujinx.Library.Amiibo;
using System;
using System.Runtime.InteropServices;
using System.Text;

// 直接链接生产契约，验证跨 Swift/C# 的布局及目录边界，避免复制一份实现来“自测”。
internal static class Program
{
    private static int _count;

    private static void Check(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException(name);
        _count++;
    }

    private static unsafe void Main()
    {
        Check(sizeof(AmiiboStateNative) == 24, "state size");
        Check(sizeof(AmiiboScanNative) == 32, "request size");
        Check(Marshal.OffsetOf<AmiiboScanNative>(nameof(AmiiboScanNative.AmiiboId)).ToInt32() == 16, "ID offset");
        Check(Marshal.OffsetOf<AmiiboStateNative>(nameof(AmiiboStateNative.LastResult)).ToInt32() == 20, "result offset");
        Check(AmiiboContract.ReadId("0100000003530902"u8) == "0100000003530902", "valid ID");
        Check(AmiiboContract.ReadId("010000000353090"u8) == null, "short ID");
        Check(AmiiboContract.ReadId("01000000035309020"u8) == null, "long ID");
        Check(AmiiboContract.ReadId("01000000035x0902"u8) == null, "non-hex ID");
        Check(AmiiboContract.ReadId("01000000034d0902"u8) == null, "noncanonical ID");
        Check(AmiiboContract.ReadId("010000000353090\0"u8) == null, "embedded NUL");

        Console.WriteLine($"Amiibo contract checks passed: {_count}");
    }
}
