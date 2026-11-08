namespace Ryujinx.HLE.HOS.Services.Nfc.Nfp
{
    /// <summary>
    /// 表示主机侧虚拟 amiibo 提交所处的检测状态。
    /// </summary>
    public enum VirtualAmiiboDetectionStatus
    {
        Unavailable = 0,
        Idle = 1,
        Searching = 2,
        TagFound = 3,
        Mounted = 4,
    }

    /// <summary>
    /// 返回当前检测轮次；轮次变化后，旧界面的提交必须失效。
    /// </summary>
    public readonly struct VirtualAmiiboStatus
    {
        public VirtualAmiiboStatus(ulong detectionEpoch, VirtualAmiiboDetectionStatus status)
        {
            DetectionEpoch = detectionEpoch;
            Status = status;
        }

        public ulong DetectionEpoch { get; }

        public VirtualAmiiboDetectionStatus Status { get; }

        public bool IsSearching => Status == VirtualAmiiboDetectionStatus.Searching;
    }

    /// <summary>
    /// 虚拟 amiibo 提交结果，供 NativeAOT/Swift 桥接层映射为用户可见错误。
    /// </summary>
    public enum VirtualAmiiboScanResult
    {
        Accepted = 0,
        NotSearching = 1,
        StaleDetection = 2,
        InvalidId = 3,
        StorageError = 4,
        Unavailable = 5,
        EventsNotReady = 6,
    }
}
