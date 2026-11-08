using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Shim;
using LibHac.FsSystem;
using LibHac.Tools.FsSystem;
using Ryujinx.Cpu;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.Debugger;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.SystemAppletProxy;
using Ryujinx.HLE.HOS.Services.Apm;
using Ryujinx.HLE.HOS.Services.Caps;
using Ryujinx.HLE.HOS.Services.Mii;
using Ryujinx.HLE.HOS.Services.Nfc.AmiiboDecryption;
using Ryujinx.HLE.HOS.Services.Nfc.Nfp;
using Ryujinx.HLE.HOS.Services.Nfc.Nfp.NfpManager;
using Ryujinx.HLE.HOS.Services.Nfc.Mifare.MifareManager;
using Ryujinx.HLE.HOS.Services.Nv;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrl;
using Ryujinx.HLE.HOS.Services.Pcv.Bpc;
using Ryujinx.HLE.HOS.Services.Sdb.Pl;
using Ryujinx.HLE.HOS.Services.Settings;
using Ryujinx.HLE.HOS.Services.Sm;
using Ryujinx.HLE.HOS.Services.SurfaceFlinger;
using Ryujinx.HLE.HOS.Services.Time.Clock;
using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.HLE.Loaders.Executables;
using Ryujinx.HLE.Loaders.Processes;
using Ryujinx.Horizon;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json;

namespace Ryujinx.HLE.HOS
{
    using TimeServiceManager = Services.Time.TimeManager;

    public class Horizon : IDisposable
    {
        internal const int HidSize = 0x40000;
        internal const int FontSize = 0x1100000;
        internal const int IirsSize = 0x8000;
        internal const int TimeSize = 0x1000;
        internal const int AppletCaptureBufferSize = 0x384000;

        internal KernelContext KernelContext { get; }

        internal Switch Device { get; private set; }

        internal ITickSource TickSource { get; }

        internal SurfaceFlinger SurfaceFlinger { get; private set; }

        public SystemStateMgr State { get; private set; }

        internal PerformanceState PerformanceState { get; private set; }

        internal AppletStateMgr AppletState { get; private set; }

        internal List<NfpDevice> NfpDevices { get; private set; }

        // NFP 设备列表同时被 HLE 服务线程和主机桥接线程访问，所有主机侧状态转换都通过此锁完成。
        internal object NfpSync { get; } = new();

        // 检测 worker 在无标签时等待此信号，避免空转；提交或停止检测时由状态转换方发信号。
        internal AutoResetEvent NfpDetectionSignal { get; } = new(false);

        private ulong _nfpDetectionEpoch;
        private readonly object _nfpLifecycleSync = new();
        private CancellationTokenSource _nfpDetectionCancellation;
        private Task _nfpDetectionTask;
        private bool _nfpClosed;

        internal bool IsNfpClosed => _nfpClosed;

        internal List<NfcDevice> NfcDevices { get; private set; }

        internal SmRegistry SmRegistry { get; private set; }

        internal ServerBase SmServer { get; private set; }
        internal ServerBase BsdServer { get; private set; }
        internal ServerBase FsServer { get; private set; }
        internal ServerBase HidServer { get; private set; }
        internal ServerBase NvDrvServer { get; private set; }
        internal ServerBase TimeServer { get; private set; }
        internal ServerBase ViServer { get; private set; }
        internal ServerBase ViServerM { get; private set; }
        internal ServerBase ViServerS { get; private set; }
        internal ServerBase LdnServer { get; private set; }

        internal KSharedMemory HidSharedMem { get; private set; }
        internal KSharedMemory FontSharedMem { get; private set; }
        internal KSharedMemory IirsSharedMem { get; private set; }

        internal KTransferMemory AppletCaptureBufferTransfer { get; private set; }

        internal SharedFontManager SharedFontManager { get; private set; }
        internal AccountManager AccountManager { get; private set; }
        internal ContentManager ContentManager { get; private set; }
        internal CaptureManager CaptureManager { get; private set; }

        internal KEvent VsyncEvent { get; private set; }

        internal KEvent DisplayResolutionChangeEvent { get; private set; }

        public KeySet KeySet => Device.FileSystem.KeySet;

        private bool _isDisposed;

        public bool EnablePtc { get; set; }

        public IntegrityCheckLevel FsIntegrityCheckLevel { get; set; }

        public int GlobalAccessLogMode { get; set; }

        internal SharedMemoryStorage HidStorage { get; private set; }

        internal NvHostSyncpt HostSyncpoint { get; private set; }

        internal LibHacHorizonManager LibHacHorizonManager { get; private set; }

        internal ServiceTable ServiceTable { get; private set; }

        public bool IsPaused { get; private set; }

        public Horizon(Switch device)
        {
            TickSource = new TickSource(KernelConstants.CounterFrequency);

            KernelContext = new KernelContext(
                TickSource,
                device,
                device.Memory,
                device.Configuration.MemoryConfiguration.KernelMemorySize,
                device.Configuration.MemoryConfiguration.KernelMemoryArrange);

            Device = device;

            State = new SystemStateMgr();

            PerformanceState = new PerformanceState();

            NfpDevices = [];
            NfcDevices = [];

            // Note: This is not really correct, but with HLE of services, the only memory
            // region used that is used is Application, so we can use the other ones for anything.
            KMemoryRegionManager region = KernelContext.MemoryManager.MemoryRegions[(int)MemoryRegion.NvServices];

            ulong hidPa = region.Address;
            ulong fontPa = region.Address + HidSize;
            ulong iirsPa = region.Address + HidSize + FontSize;
            ulong timePa = region.Address + HidSize + FontSize + IirsSize;
            ulong appletCaptureBufferPa = region.Address + HidSize + FontSize + IirsSize + TimeSize;

            KPageList hidPageList = new();
            KPageList fontPageList = new();
            KPageList iirsPageList = new();
            KPageList timePageList = new();
            KPageList appletCaptureBufferPageList = new();

            hidPageList.AddRange(hidPa, HidSize / KPageTableBase.PageSize);
            fontPageList.AddRange(fontPa, FontSize / KPageTableBase.PageSize);
            iirsPageList.AddRange(iirsPa, IirsSize / KPageTableBase.PageSize);
            timePageList.AddRange(timePa, TimeSize / KPageTableBase.PageSize);
            appletCaptureBufferPageList.AddRange(appletCaptureBufferPa, AppletCaptureBufferSize / KPageTableBase.PageSize);

            SharedMemoryStorage hidStorage = new(KernelContext, hidPageList);
            SharedMemoryStorage fontStorage = new(KernelContext, fontPageList);
            SharedMemoryStorage iirsStorage = new(KernelContext, iirsPageList);
            SharedMemoryStorage timeStorage = new(KernelContext, timePageList);
            SharedMemoryStorage appletCaptureBufferStorage = new(KernelContext, appletCaptureBufferPageList);

            HidStorage = hidStorage;

            HidSharedMem = new KSharedMemory(KernelContext, hidStorage, 0, 0, KMemoryPermission.Read);
            FontSharedMem = new KSharedMemory(KernelContext, fontStorage, 0, 0, KMemoryPermission.Read);
            IirsSharedMem = new KSharedMemory(KernelContext, iirsStorage, 0, 0, KMemoryPermission.Read);

            KSharedMemory timeSharedMemory = new(KernelContext, timeStorage, 0, 0, KMemoryPermission.Read);

            TimeServiceManager.Instance.Initialize(device, this, timeSharedMemory, timeStorage, TimeSize);

            AppletCaptureBufferTransfer = new KTransferMemory(KernelContext, appletCaptureBufferStorage);

            AppletState = new AppletStateMgr(this);

            AppletState.SetFocus(true);

            VsyncEvent = new KEvent(KernelContext);

            DisplayResolutionChangeEvent = new KEvent(KernelContext);

            SharedFontManager = new SharedFontManager(device, fontStorage);
            AccountManager = device.Configuration.AccountManager;
            ContentManager = device.Configuration.ContentManager;
            CaptureManager = new CaptureManager(device);

            LibHacHorizonManager = device.Configuration.LibHacHorizonManager;

            // We hardcode a clock source id to avoid it changing between each start.
            // TODO: use set:sys (and get external clock source id from settings)
            // TODO: use "time!standard_steady_clock_rtc_update_interval_minutes" and implement a worker thread to be accurate.
            UInt128 clockSourceId = new(0x36a0328702ce8bc1, 0x1608eaba02333284);
            IRtcManager.GetExternalRtcValue(out ulong rtcValue);

            // We assume the rtc is system time.
            TimeSpanType systemTime = TimeSpanType.FromSeconds((long)rtcValue);

            // Configure and setup internal offset
            TimeSpanType internalOffset = TimeSpanType.FromSeconds(device.Configuration.SystemTimeOffset);

            TimeSpanType systemTimeOffset = new(systemTime.NanoSeconds + internalOffset.NanoSeconds);

            if (systemTime.IsDaylightSavingTime() && !systemTimeOffset.IsDaylightSavingTime())
            {
                internalOffset = internalOffset.AddSeconds(3600L);
            }
            else if (!systemTime.IsDaylightSavingTime() && systemTimeOffset.IsDaylightSavingTime())
            {
                internalOffset = internalOffset.AddSeconds(-3600L);
            }

            systemTime = new TimeSpanType(systemTime.NanoSeconds + internalOffset.NanoSeconds);

            // First init the standard steady clock
            TimeServiceManager.Instance.SetupStandardSteadyClock(TickSource, clockSourceId, TimeSpanType.Zero, TimeSpanType.Zero, TimeSpanType.Zero, false);
            TimeServiceManager.Instance.SetupStandardLocalSystemClock(TickSource, new SystemClockContext(), systemTime.ToSeconds());
            TimeServiceManager.Instance.StandardLocalSystemClock.GetClockContext(TickSource, out SystemClockContext localSytemClockContext);

            if (NxSettings.Settings.TryGetValue("time!standard_network_clock_sufficient_accuracy_minutes", out object standardNetworkClockSufficientAccuracyMinutes))
            {
                TimeSpanType standardNetworkClockSufficientAccuracy = new((int)standardNetworkClockSufficientAccuracyMinutes * 60000000000);

                // The network system clock needs a valid system clock, as such we setup this system clock using the local system clock.
                TimeServiceManager.Instance.SetupStandardNetworkSystemClock(localSytemClockContext, standardNetworkClockSufficientAccuracy);
            }

            TimeServiceManager.Instance.SetupStandardUserSystemClock(TickSource, true, localSytemClockContext.SteadyTimePoint);

            // FIXME: TimeZone should be init here but it's actually done in ContentManager

            TimeServiceManager.Instance.SetupEphemeralNetworkSystemClock();

            DatabaseImpl.Instance.InitializeDatabase(TickSource, LibHacHorizonManager.SdbClient);

            HostSyncpoint = new NvHostSyncpt(device);

            SurfaceFlinger = new SurfaceFlinger(device);
        }

        public void InitializeServices()
        {
            SmRegistry = new SmRegistry();
            SmServer = new ServerBase(KernelContext, "Sm", () => new IUserInterface(KernelContext, SmRegistry));

            // Wait until SM server thread is done with initialization,
            // only then doing connections to SM is safe.
            SmServer.InitDone.WaitOne();

            BsdServer = new ServerBase(KernelContext, "Bsd");
            FsServer = new ServerBase(KernelContext, "Fs");
            HidServer = new ServerBase(KernelContext, "Hid");
            NvDrvServer = new ServerBase(KernelContext, "Nv");
            TimeServer = new ServerBase(KernelContext, "Time");
            ViServer = new ServerBase(KernelContext, "Vi:u");
            ViServerM = new ServerBase(KernelContext, "Vi:m");
            ViServerS = new ServerBase(KernelContext, "Vi:s");
            LdnServer = new ServerBase(KernelContext, "Ldn");

            StartNewServices();
        }

        private void StartNewServices()
        {
            HorizonFsClient fsClient = new(this);

            ServiceTable = new ServiceTable();
            IEnumerable<ServiceEntry> services = ServiceTable.GetServices(new HorizonOptions
                (Device.Configuration.IgnoreMissingServices,
                LibHacHorizonManager.BcatClient,
                fsClient,
                AccountManager,
                Device.AudioDeviceDriver,
                TickSource));

            foreach (ServiceEntry service in services)
            {
                const ProcessCreationFlags Flags =
                    ProcessCreationFlags.EnableAslr |
                    ProcessCreationFlags.AddressSpace64Bit |
                    ProcessCreationFlags.Is64Bit |
                    ProcessCreationFlags.PoolPartitionSystem;

                ProcessCreationInfo creationInfo = new(service.Name, 1, 0, 0x8000000, 1, Flags, 0, 0);

                uint[] defaultCapabilities =
                [
                    (((uint)KScheduler.CpuCoresCount - 1) << 24) + (((uint)KScheduler.CpuCoresCount - 1) << 16) + 0x63F7u,
                    0x1FFFFFCF,
                    0x207FFFEF,
                    0x47E0060F,
                    0x0048BFFF,
                    0x01007FFF
                ];

                // TODO:
                // - Pass enough information (capabilities, process creation info, etc) on ServiceEntry for proper initialization.
                // - Have the ThreadStart function take the syscall, address space and thread context parameters instead of passing them here.
                KernelStatic.StartInitialProcess(KernelContext, creationInfo, defaultCapabilities, 44, () =>
                {
                    service.Start(KernelContext.Syscall, KernelStatic.GetCurrentProcess().CpuMemory, KernelStatic.GetCurrentThread().ThreadContext);
                });
            }
        }

        public bool LoadKip(string kipPath)
        {
            using SharedRef<IStorage> kipFile = new(new LocalStorage(kipPath, FileAccess.Read));

            return ProcessLoaderHelper.LoadKip(KernelContext, new KipExecutable(in kipFile));
        }

        public void ChangeDockedModeState(bool newState)
        {
            if (newState != State.DockedMode)
            {
                State.DockedMode = newState;
                PerformanceState.PerformanceMode = State.DockedMode ? PerformanceMode.Boost : PerformanceMode.Default;

                AppletState.Messages.Enqueue(AppletMessage.OperationModeChanged);
                AppletState.Messages.Enqueue(AppletMessage.PerformanceModeChanged);
                AppletState.MessageEvent.ReadableEvent.Signal();

                SignalDisplayResolutionChange();

                Device.Configuration.RefreshInputConfig?.Invoke();
            }
        }

        public void ReturnFocus()
        {
            AppletState.SetFocus(true);
        }

        public void SimulateWakeUpMessage()
        {
            AppletState.Messages.Enqueue(AppletMessage.Resume);
            AppletState.MessageEvent.ReadableEvent.Signal();
        }

        public void ScanAmiibo(int nfpDeviceId, string amiiboId, bool useRandomUuid)
        {
            lock (NfpSync)
            {
                if (_nfpClosed || nfpDeviceId < 0 || nfpDeviceId >= NfpDevices.Count || NfpDevices[nfpDeviceId].State != NfpDeviceState.SearchingForTag)
                {
                    return;
                }

                VirtualAmiibo.ResetSession();
                NfpDevice device = NfpDevices[nfpDeviceId];
                device.AmiiboId = amiiboId;
                device.UseRandomUuid = useRandomUuid;
                device.State = NfpDeviceState.TagFound;
                NfpDetectionSignal.Set();
            }
        }

        public void ScanAmiiboFromBin(string path)
        {
            lock (NfpSync)
            {
                if (_nfpClosed || !SearchingForAmiibo(out int nfpDeviceId))
                {
                    return;
                }

                VirtualAmiibo.ResetSession();
                VirtualAmiibo.InputBin = path;
                byte[] encryptedData = File.ReadAllBytes(path);
                VirtualAmiiboFile newFile = AmiiboBinReader.ReadBinFile(encryptedData);
                NfpDevice device = NfpDevices[nfpDeviceId];
                device.AmiiboId = newFile.AmiiboId;
                device.UseRandomUuid = false;
                device.State = NfpDeviceState.TagFound;
                NfpDetectionSignal.Set();
            }
        }

        public void ScanSkylander(int nfcDeviceId, byte[] data)
        {
            if (NfcDevices[nfcDeviceId].State == NfcDeviceState.SearchingForTag)
            {
                NfcDevices[nfcDeviceId].State = NfcDeviceState.TagFound;
                NfcDevices[nfcDeviceId].Data = data;
            }
        }

        public bool SearchingForAmiibo(out int nfpDeviceId)
        {
            lock (NfpSync)
            {
                nfpDeviceId = default;
                for (int i = 0; i < NfpDevices.Count; i++)
                {
                    if (NfpDevices[i].State == NfpDeviceState.SearchingForTag)
                    {
                        nfpDeviceId = i;
                        return true;
                    }
                }

                return false;
            }
        }

        public bool SearchingForSkylander(out int nfcDeviceId)
        {
            nfcDeviceId = default;

            for (int i = 0; i < NfcDevices.Count; i++)
            {
                if (NfcDevices[i].State == NfcDeviceState.SearchingForTag)
                {
                    nfcDeviceId = i;

                    return true;
                }
            }

            return false;
        }

        public bool HasSkylander(out int nfcDeviceId)
        {
            nfcDeviceId = default;

            for (int i = 0; i < NfcDevices.Count; i++)
            {
                if (NfcDevices[i].State == NfcDeviceState.TagFound)
                {
                    nfcDeviceId = i;

                    return true;
                }
            }

            return false;
        }

        public void RemoveSkylander()
        {
            for (int i = 0; i < NfcDevices.Count; i++)
            {
                if (NfcDevices[i].State == NfcDeviceState.TagFound)
                {
                    NfcDevices[i].State = NfcDeviceState.Initialized;
                    NfcDevices[i].SignalDeactivate();
                    Thread.Sleep(100); // NOTE: Simulate skylander scanning delay.
                }
            }
        }

        public void SignalDisplayResolutionChange()
        {
            DisplayResolutionChangeEvent.ReadableEvent.Signal();
        }

        public void SignalVsync()
        {
            VsyncEvent.ReadableEvent.Signal();
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (!_isDisposed && disposing)
            {
                _isDisposed = true;

                CloseVirtualAmiiboSession();

                // "Soft" stops AudioRenderer and AudioManager to avoid some sound between resume and stop.
                if (IsPaused)
                {
                    TogglePauseEmulation(false);
                }

                KProcess terminationProcess = new(KernelContext);
                KThread terminationThread = new(KernelContext);

                terminationThread.Initialize(0, 0, 0, 3, 0, terminationProcess, ThreadType.Kernel, () =>
                {
                    // Force all threads to exit.
                    lock (KernelContext.Processes)
                    {
                        // Terminate application.
                        foreach (KProcess process in KernelContext.Processes.Values.Where(x => x.IsApplication))
                        {
                            process.Terminate();
                            process.DecrementReferenceCount();
                        }

                        // The application existed, now surface flinger can exit too.
                        SurfaceFlinger.Dispose();

                        // Terminate HLE services (must be done after the application is already terminated,
                        // otherwise the application will receive errors due to service termination).
                        foreach (KProcess process in KernelContext.Processes.Values.Where(x => !x.IsApplication))
                        {
                            process.Terminate();
                            process.DecrementReferenceCount();
                        }

                        KernelContext.Processes.Clear();
                    }

                    // Exit ourself now!
                    KernelStatic.GetCurrentThread().Exit();
                });

                terminationThread.Start();

                // Wait until the thread is actually started.
                while (terminationThread.HostThread.ThreadState == ThreadState.Unstarted)
                {
                    Thread.Sleep(10);
                }

                // Wait until the termination thread is done terminating all the other threads.
                terminationThread.HostThread.Join();

                // Destroy nvservices channels as KThread could be waiting on some user events.
                // This is safe as KThread that are likely to call ioctls are going to be terminated by the post handler hook on the SVC facade.
                INvDrvServices.Destroy();

                if (LibHacHorizonManager.ApplicationClient != null)
                {
                    LibHacHorizonManager.PmClient.Fs.UnregisterProgram(LibHacHorizonManager.ApplicationClient.Os.GetCurrentProcessId().Value).ThrowIfFailure();
                }

                KernelContext.Dispose();
            }
        }

        /// <summary>
        /// 返回当前 amiibo 检测轮次和设备状态。轮次用于拒绝已经过期的 UI 提交。
        /// </summary>
        public VirtualAmiiboStatus GetVirtualAmiiboStatus()
        {
            lock (NfpSync)
            {
                if (_isDisposed || _nfpClosed)
                {
                    return new VirtualAmiiboStatus(_nfpDetectionEpoch, VirtualAmiiboDetectionStatus.Unavailable);
                }

                NfpDevice device = NfpDevices.FirstOrDefault();
                VirtualAmiiboDetectionStatus status = device?.State switch
                {
                    NfpDeviceState.SearchingForTag => VirtualAmiiboDetectionStatus.Searching,
                    NfpDeviceState.TagFound => VirtualAmiiboDetectionStatus.TagFound,
                    NfpDeviceState.TagMounted => VirtualAmiiboDetectionStatus.Mounted,
                    _ => VirtualAmiiboDetectionStatus.Idle,
                };

                return new VirtualAmiiboStatus(_nfpDetectionEpoch, status);
            }
        }

        /// <summary>
        /// 在指定检测轮次中原子提交虚拟 amiibo。成功后才发布 TagFound，避免 worker 读取到半初始化设备。
        /// </summary>
        public VirtualAmiiboScanResult TryScanVirtualAmiibo(ulong expectedEpoch, string amiiboId)
        {
            if (string.IsNullOrWhiteSpace(amiiboId) || amiiboId.Length != 16 || amiiboId.Any(c => !Uri.IsHexDigit(c)))
            {
                return VirtualAmiiboScanResult.InvalidId;
            }

            lock (NfpSync)
            {
                if (_isDisposed || _nfpClosed)
                {
                    return VirtualAmiiboScanResult.Unavailable;
                }

                if (expectedEpoch != _nfpDetectionEpoch)
                {
                    return VirtualAmiiboScanResult.StaleDetection;
                }

                NfpDevice device = NfpDevices.FirstOrDefault();
                if (device == null || device.State != NfpDeviceState.SearchingForTag)
                {
                    return VirtualAmiiboScanResult.NotSearching;
                }

                if (device.ActivateEvent == null || device.DeactivateEvent == null)
                {
                    return VirtualAmiiboScanResult.EventsNotReady;
                }

                try
                {
                    VirtualAmiibo.PrepareVirtualSession(amiiboId.ToUpperInvariant());
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
                {
                    Logger.Warning?.Print(LogClass.ServiceNfp, $"Virtual amiibo storage validation failed: {exception.GetType().Name}.");
                    return VirtualAmiiboScanResult.StorageError;
                }

                device.AmiiboId = amiiboId.ToUpperInvariant();
                device.UseRandomUuid = false;
                device.State = NfpDeviceState.TagFound;
                NfpDetectionSignal.Set();
                return VirtualAmiiboScanResult.Accepted;
            }
        }

        /// <summary>
        /// 启动一个检测轮次。等待旧 worker 时不持有设备锁，避免停止与事件发布互相等待。
        /// </summary>
        internal bool StartNfpDetection(uint deviceHandle)
        {
            lock (_nfpLifecycleSync)
            {
                if (_nfpClosed)
                {
                    return false;
                }

                StopNfpDetectionWorker();
                lock (NfpSync)
                {
                    if (_nfpClosed || _isDisposed)
                    {
                        return false;
                    }

                    NfpDevice device = NfpDevices.FirstOrDefault(item => (uint)item.Handle == deviceHandle);
                    if (device == null)
                    {
                        return false;
                    }

                    VirtualAmiibo.ResetSession();
                    device.AmiiboId = null;
                    device.UseRandomUuid = false;
                    device.State = NfpDeviceState.SearchingForTag;
                    ulong epoch = ++_nfpDetectionEpoch;
                    CancellationTokenSource cancellation = new();
                    CancellationToken token = cancellation.Token;
                    _nfpDetectionCancellation = cancellation;
                    _nfpDetectionTask = Task.Run(() => RunNfpDetection(device, epoch, token));
                    return true;
                }
            }
        }

        internal void StopNfpDetection(uint deviceHandle)
        {
            lock (_nfpLifecycleSync)
            {
                if (_nfpClosed)
                {
                    return;
                }

                StopNfpDetectionWorker();
                lock (NfpSync)
                {
                    foreach (NfpDevice device in NfpDevices)
                    {
                        if ((uint)device.Handle == deviceHandle)
                        {
                            device.State = NfpDeviceState.Initialized;
                        }
                    }

                    VirtualAmiibo.ResetSession();
                }
            }
        }

        internal void ResetNfpDevices()
        {
            lock (_nfpLifecycleSync)
            {
                if (_nfpClosed)
                {
                    return;
                }

                StopNfpDetectionWorker();
                lock (NfpSync)
                {
                    NfpDevices.Clear();
                    VirtualAmiibo.ResetSession();
                }
            }
        }

        /// <summary>
        /// 关闭主机提交入口并回收检测 worker；调用方可随后销毁模拟器，不需要再次打开旧会话。
        /// </summary>
        public void CloseVirtualAmiiboSession()
        {
            lock (_nfpLifecycleSync)
            {
                lock (NfpSync)
                {
                    if (_nfpClosed)
                    {
                        return;
                    }

                    _nfpClosed = true;
                }

                StopNfpDetectionWorker();
                lock (NfpSync)
                {
                    VirtualAmiibo.ResetSession();
                    NfpDevices.Clear();
                }

                NfpDetectionSignal.Dispose();
            }
        }

        // 调用方持有生命周期锁。先交接 worker 所有权，再在设备锁外取消和等待。
        private void StopNfpDetectionWorker()
        {
            CancellationTokenSource cancellation;
            Task worker;
            lock (NfpSync)
            {
                _nfpDetectionEpoch++;
                cancellation = _nfpDetectionCancellation;
                worker = _nfpDetectionTask;
                _nfpDetectionCancellation = null;
                _nfpDetectionTask = null;
                cancellation?.Cancel();
                NfpDetectionSignal.Set();
            }

            worker?.GetAwaiter().GetResult();
            cancellation?.Dispose();
        }

        // 一个轮次只激活一次；KEvent.Signal 会获取内核锁，必须在释放 NfpSync 后调用。
        private void RunNfpDetection(NfpDevice device, ulong epoch, CancellationToken token)
        {
            WaitHandle[] waits = [NfpDetectionSignal, token.WaitHandle];
            while (!token.IsCancellationRequested)
            {
                if (WaitHandle.WaitAny(waits) == 1)
                {
                    return;
                }

                KEvent activateEvent;
                KEvent deactivateEvent;
                lock (NfpSync)
                {
                    if (_nfpClosed || token.IsCancellationRequested || epoch != _nfpDetectionEpoch)
                    {
                        return;
                    }

                    if (device.State != NfpDeviceState.TagFound || device.ActivateEvent == null || device.DeactivateEvent == null)
                    {
                        continue;
                    }

                    activateEvent = device.ActivateEvent;
                    deactivateEvent = device.DeactivateEvent;
                }

                if (token.IsCancellationRequested)
                {
                    return;
                }

                activateEvent.ReadableEvent.Signal();
                if (token.WaitHandle.WaitOne(125))
                {
                    return;
                }

                bool signalDeactivate;
                lock (NfpSync)
                {
                    signalDeactivate = !token.IsCancellationRequested && !_nfpClosed && epoch == _nfpDetectionEpoch;
                }

                if (signalDeactivate)
                {
                    deactivateEvent.ReadableEvent.Signal();
                }

                return;
            }
        }

        public void TogglePauseEmulation(bool pause)
        {
            lock (KernelContext.Processes)
            {
                foreach (KProcess process in KernelContext.Processes.Values)
                {
                    if (process.IsApplication)
                    {
                        // Only game process should be paused.
                        process.SetActivity(pause);
                    }
                }

                if (pause && !IsPaused)
                {
                    Device.AudioDeviceDriver.GetPauseEvent().Reset();
                    TickSource.Suspend();
                }
                else if (!pause && IsPaused)
                {
                    Device.AudioDeviceDriver.GetPauseEvent().Set();
                    TickSource.Resume();
                }
            }

            IsPaused = pause;
        }

        internal IDebuggableProcess DebugGetApplicationProcessDebugInterface()
        {
            lock (KernelContext.Processes)
            {
                return KernelContext.Processes.Values.FirstOrDefault(x => x.IsApplication)?.DebugInterface;
            }
        }

        internal KProcess DebugGetApplicationProcess()
        {
            lock (KernelContext.Processes)
            {
                return KernelContext.Processes.Values.FirstOrDefault(x => x.IsApplication);
            }
        }
    }
}
