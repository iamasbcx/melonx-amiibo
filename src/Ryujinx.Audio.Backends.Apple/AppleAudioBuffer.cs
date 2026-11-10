namespace Ryujinx.Audio.Backends.Apple
{
    /// <summary>
    /// 会话拥有的可复用播放槽。字段仅在会话锁内访问；完成回调后才允许再次填充。
    /// Token 在进程内不复用，关闭后迟到的原生回调无法访问已释放资源。
    /// </summary>
    sealed class AppleAudioBuffer
    {
        public readonly AppleHardwareDeviceSession Owner;
        public readonly long Token;
        public readonly uint Capacity;
        public readonly nint NativeBuffer;
        public readonly nint CompletionBlock;
        public ulong HostTag;
        public uint FrameCount;
        public bool Pending;

        public AppleAudioBuffer(AppleHardwareDeviceSession owner, long token, uint capacity, nint nativeBuffer, nint completionBlock)
        {
            Owner = owner;
            Token = token;
            Capacity = capacity;
            NativeBuffer = nativeBuffer;
            CompletionBlock = completionBlock;
        }
    }
}
