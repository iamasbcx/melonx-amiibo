using Ryujinx.Common.Configuration;
using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Callbacks;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.Gpu;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy.Types;
using Ryujinx.HLE.UI;
using Ryujinx.Input;
using Ryujinx.Input.HLE;
using Ryujinx.Input.Native;
using Ryujinx.SDL3.Common;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Threading;
using AntiAliasing = Ryujinx.Common.Configuration.AntiAliasing;
using ScalingFilter = Ryujinx.Common.Configuration.ScalingFilter;
using Switch = Ryujinx.HLE.Switch;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Channels;
using System.Threading.Tasks;
using System.Buffers.Binary;
// using Ryujinx.Ava.UI.Models;


namespace Ryujinx.Library
{
    abstract partial class WindowBase: IHostUIHandler, IDisposable
    {
        protected const int DefaultWidth = 1280;
        protected const int DefaultHeight = 720;
        private static readonly ConcurrentQueue<Action> _mainThreadActions = new();
        private static event Action MainThreadActionQueued;
        private static readonly NativeViewportState _viewport = new(DefaultWidth, DefaultHeight);

        public static void QueueMainThreadAction(Action action)
        {
            _mainThreadActions.Enqueue(action);
            MainThreadActionQueued?.Invoke();
        }

        public NpadManager NpadManager;
        public TouchScreenManager TouchScreenManager;
        public Switch Device;
        public IRenderer Renderer;

        public IntPtr WindowHandle;

        public IHostUITheme HostUITheme { get; }
        public static int Width => _viewport.Size.Width;
        public static int Height => _viewport.Size.Height;
        public int DisplayId { get; set; }
        public bool IsFullscreen { get; set; }
        public bool IsExclusiveFullscreen { get; set; }
        public int ExclusiveFullscreenWidth { get; set; }
        public int ExclusiveFullscreenHeight { get; set; }
        public AntiAliasing AntiAliasing { get; set; }
        public ScalingFilter ScalingFilter { get; set; }
        public int ScalingFilterLevel { get; set; }
        public float MetalFxUpscaleFactor { get; set; } = 2.0f;

        public NativeTouchDriver MouseDriver;
        private readonly InputManager _inputManager;
        private readonly IKeyboard _keyboardInterface;
        private readonly GraphicsDebugLevel _glLogLevel;
        private readonly CancellationTokenSource _gpuCancellationTokenSource;
        public ManualResetEvent _exitEvent;
        public ManualResetEvent _gpuDoneEvent;
        private readonly HostLoopScheduler _scheduler = new();
        private readonly StatisticsPublishGate _statisticsGate = new(Stopwatch.Frequency);
        private readonly ITouchScreen _touchScreen;
        public volatile bool _isActive;
        private volatile bool _isStopped;
        private int _exitStarted;
        private readonly object _exitCompletionLock = new();
        private bool _exitCompleted;
        private int _windowDisposed;
        private Thread _renderLoopThread;
        private ExceptionDispatchInfo _renderFailure;
        private bool _renderLoopEntered;

        public bool _ranFirstFrame;

        private string _gpuDriverName;

        public AspectRatio _aspectRatio;
        private readonly bool _enableMouse;


        public WindowBase(
            InputManager inputManager,
            GraphicsDebugLevel glLogLevel,
            AspectRatio aspectRatio,
            bool enableMouse,
            HideCursorMode hideCursorMode)
        {
            MouseDriver = new NativeTouchDriver(hideCursorMode);
            _inputManager = inputManager;
            _inputManager.SetMouseDriver(MouseDriver);
            NpadManager = _inputManager.CreateNpadManager();
            TouchScreenManager = _inputManager.CreateTouchScreenManager();
            _keyboardInterface = (IKeyboard)_inputManager.KeyboardDriver.GetGamepad("0");
            _glLogLevel = glLogLevel;
            _gpuCancellationTokenSource = new CancellationTokenSource();
            _exitEvent = new ManualResetEvent(false);
            _gpuDoneEvent = new ManualResetEvent(false);
            _touchScreen = (ITouchScreen)MouseDriver.GetGamepad("0");
            _aspectRatio = aspectRatio;
            _enableMouse = enableMouse;
            HostUITheme = new NativeHostUiTheme();
            NativeGamepadDriver.OnInputUpdated += SignalInputUpdated;
            NativeTouchDriver.OnInputUpdated += SignalInputUpdated;
            SDL3Driver.Instance.OnKeyboardInputUpdated += SignalInputUpdated;
            MainThreadActionQueued += SignalInputUpdated;

        }

        public void SignalInputUpdated()
        {
            _scheduler.Signal();
        }

        public void SetPaused(bool paused) => _scheduler.SetPaused(paused);

        public void SetStatisticsEnabled(bool enabled) => _statisticsGate.SetEnabled(enabled);

        private void UnsubscribeInputEvents()
        {
            NativeGamepadDriver.OnInputUpdated -= SignalInputUpdated;
            NativeTouchDriver.OnInputUpdated -= SignalInputUpdated;
            SDL3Driver.Instance.OnKeyboardInputUpdated -= SignalInputUpdated;
            MainThreadActionQueued -= SignalInputUpdated;
        }

        public void Initialize(Switch device, List<InputConfig> inputConfigs, bool enableKeyboard, bool enableMouse)
        {
            Device = device;

            IRenderer renderer = Device.Gpu.Renderer;

            if (renderer is ThreadedRenderer tr)
            {
                renderer = tr.BaseRenderer;
            }

            Renderer = renderer;

            NpadManager.Initialize(device, inputConfigs, enableKeyboard, enableMouse);
            TouchScreenManager.Initialize(device);
        }

        [UnmanagedCallersOnly(EntryPoint = "set_view_size")]
        static unsafe void set_view_size(int width, int height)
        {
            if (_viewport.SetNativeSize(width, height)) MainThreadActionQueued?.Invoke();
        }

        private void InitializeWindow()
        {
            _viewport.InitializeFallback(
                ExclusiveFullscreenWidth > 0 ? ExclusiveFullscreenWidth : DefaultWidth,
                ExclusiveFullscreenHeight > 0 ? ExclusiveFullscreenHeight : DefaultHeight);
            UpdateTouchClientSize();
        }

        private void UpdateTouchClientSize()
        {
            System.Drawing.Size size = _viewport.Size;
            MouseDriver.SetClientSize(size.Width, size.Height);
        }

        protected abstract void InitializeWindowRenderer();

        protected abstract void InitializeRenderer();

        protected abstract void FinalizeWindowRenderer();

        protected abstract void SwapBuffers();

        private string GetGpuDriverName()
        {
            return Renderer.GetHardwareInfo().GpuDriver;
        }

        private void SetAntiAliasing()
        {
            Renderer?.Window.SetAntiAliasing(AntiAliasing);
        }

        private void SetScalingFilter()
        {
            Renderer?.Window.SetScalingFilter(ScalingFilter);
            Renderer?.Window.SetScalingFilterLevel(ScalingFilterLevel);
            Renderer?.Window.SetMetalFxUpscaleFactor(MetalFxUpscaleFactor);
        }

        public void Render()
        {
            InitializeWindowRenderer();

            Device.Gpu.Renderer.Initialize(_glLogLevel);

            InitializeRenderer();

            SetAntiAliasing();

            SetScalingFilter();

            _gpuDriverName = GetGpuDriverName();

            _ranFirstFrame = false;

            _renderLoopEntered = true;
            Device.Gpu.Renderer.RunLoop(() =>
            {
                try
                {
                    Device.Gpu.SetGpuThread();
                    Device.Gpu.InitializeShaderCache(_gpuCancellationTokenSource.Token);

                    while (_isActive && _scheduler.WaitForRender())
                    {
                        if (_isStopped || !_isActive) break;

                        if (Device.WaitFifo())
                        {
                            Device.Statistics.RecordFifoStart();
                            Device.ProcessFrame();
                            Device.Statistics.RecordFifoEnd();
                        }

                        if (Device.PresentLoop(SwapBuffers) && _statisticsGate.TryPublishFirstFrame(Stopwatch.GetTimestamp()))
                        {
                            _ranFirstFrame = true;
                            SendStatistics(false);
                        }

                        if (_statisticsGate.TryPublishStatistics(Stopwatch.GetTimestamp())) SendStatistics();
                    }
                }
                catch (Exception exception)
                {
                    _renderFailure = ExceptionDispatchInfo.Capture(exception);
                    RequestStop();
                }
                finally
                {
                    try
                    {
                        if (Device.Gpu.Renderer is ThreadedRenderer threaded) threaded.FlushThreadedCommands();
                    }
                    finally
                    {
                        // 必须由 GPU 回调释放此门；等整个 ThreadedRenderer.RunLoop 返回会与 Dispose 相互等待。
                        _gpuDoneEvent.Set();
                    }
                }
            });

            FinalizeWindowRenderer();
        }

        public void Exit()
        {
            // UI 停止与模拟器循环可能同时退出，资源只能由首次调用者释放。
            if (Interlocked.Exchange(ref _exitStarted, 1) != 0)
            {
                WaitForExitCompletion();
                return;
            }
            try
            {
                bool waitForMainLoop = _isActive;
                // 窗口退出也可能来自来宾或渲染循环，必须先关闭宿主的虚拟标签会话。
                Library.EndAmiiboSession(Device);
                RequestStop();
                if (waitForMainLoop) _exitEvent.WaitOne();
                UnsubscribeInputEvents();
            }
            finally
            {
                lock (_exitCompletionLock)
                {
                    _exitCompleted = true;
                    Monitor.PulseAll(_exitCompletionLock);
                }
            }
        }

        private void WaitForExitCompletion()
        {
            lock (_exitCompletionLock)
            {
                while (!_exitCompleted) Monitor.Wait(_exitCompletionLock);
            }
        }

        private void RequestStop()
        {
            _gpuCancellationTokenSource.Cancel();
            _isStopped = true;
            _isActive = false;
            _scheduler.Stop();
        }

        public static void ProcessMainThreadQueue()
        {
            while (_mainThreadActions.TryDequeue(out Action action))
            {
                action();
            }
        }

        public void MainLoop()
        {
            try
            {
                while (_isActive)
                {
                    // 暂停期间仍须处理 SDL/宿主控制任务，否则等待这些任务的线程无法恢复或退出。
                    ProcessMainThreadQueue();
                    if (_scheduler.CanUpdateInput) UpdateFrame();
                    if (!_scheduler.WaitForWork()) break;
                }
            }
            finally
            {
                _exitEvent.Set();
            }
        }

        private bool UpdateFrame()
        {
            if (!_isActive)
            {
                return true;
            }

            if (_isStopped)
            {
                return false;
            }

            NpadManager.Update();

            UpdateTouchClientSize();
            TouchScreenManager.UpdateMultiTouch(_touchScreen, true);

            Device.Hid.DebugPad.Update();

            MouseDriver.UpdatePosition();

            return true;
        }

        public void Execute()
        {
            if (Volatile.Read(ref _exitStarted) != 0)
            {
                WaitForExitCompletion();
                return;
            }
            _isActive = true;

            InitializeWindow();

            _renderLoopThread = new(() =>
            {
                try { Render(); }
                catch (Exception exception) when (!_renderLoopEntered)
                {
                    // 初始化阶段可能尚未进入 GPU 回调，仍须释放宿主退出等待并传播失败。
                    _renderFailure = ExceptionDispatchInfo.Capture(exception);
                    RequestStop();
                    _gpuDoneEvent.Set();
                }
            })
            {
                Name = "GUI.RenderLoop",
            };
            _renderLoopThread.Start();
            try { MainLoop(); }
            finally
            {
                // UpdateFrame 或控制队列抛异常也不能越过 GPU 完成门直接释放核心。
                RequestStop();
                _gpuDoneEvent.WaitOne();
            }
            Exit();
            _renderFailure?.Throw();
        }

        public bool DisplayInputDialog(SoftwareKeyboardUIArgs args, out string userText)
        {
            userText = null;

            if (OperatingSystem.IsIOS())
            {
                string result = null;
                using ManualResetEventSlim inputReceived = new(false);

                AlertHelper.ShowAlertWithTextInput(args.HeaderText, args.SubtitleText, args.GuideText, inputText =>
                {
                    result = inputText;
                    inputReceived.Set();
                });

                inputReceived.Wait();
                userText = result;
            }

            return true;
        }

        public void SendStatistics(bool before = true)
        {
            static double Sanitize(double v) =>
                double.IsFinite(v) ? Math.Round(v, 2) : 0.0;

            Span<byte> bytes = stackalloc byte[33];
            bytes.Clear();

            double fps = before ? Sanitize(Device.Statistics.GetGameFrameRate()) : 0d;
            double frameTime = before ? Sanitize(Device.Statistics.GetGameFrameTime()) : 0d;
            double fifo = before ? Sanitize(Device.Statistics.GetFifoPercent())   : 0d;

            BinaryPrimitives.WriteDoubleLittleEndian(bytes[0..],  fps);
            BinaryPrimitives.WriteDoubleLittleEndian(bytes[8..],  frameTime);
            bytes[16] = (byte)(_ranFirstFrame ? 1 : 0);
            BinaryPrimitives.WriteDoubleLittleEndian(bytes[17..], fifo);

            unsafe {
                fixed (byte* ptr = bytes)
                {
                    CallbackRegistry.Invoke("push_statistics", ptr, bytes.Length);
                }
            }
        }

        public bool DisplayMessageDialog(string title, string message)
        {
            if (OperatingSystem.IsIOS())
            {
                Console.WriteLine($"Alert: {title}, message: {message}");

                AlertHelper.ShowAlert(title, message, false);
            }

            return true;
        }
    
        public bool DisplayMessageDialog(ControllerAppletUIArgs args)
        {
            string playerCount = args.PlayerCountMin == args.PlayerCountMax
                ? $"exactly {args.PlayerCountMin}"
                : $"{args.PlayerCountMin}-{args.PlayerCountMax}";

            string message = $"Application requests {playerCount} player(s) with:\n\n"
                           + $"TYPES: {args.SupportedStyles}\n\n"
                           + $"PLAYERS: {string.Join(", ", args.SupportedPlayers)}\n\n"
                           + (args.IsDocked ? "Docked mode set. Handheld is also invalid.\n\n" : "")
                           + "Please reconfigure Input now and then press OK.";

            return DisplayMessageDialog("Controller Applet", message);
        }

        public bool DisplayCabinetDialog(out string userText)
        {
            userText = null;

            if (OperatingSystem.IsIOS())
            {
                string result = null;
                using ManualResetEventSlim inputReceived = new(false);

                AlertHelper.ShowAlertWithTextInput("Amiibo", "Enter a name for the Amiibo", string.Empty, inputText =>
                {
                    result = inputText;
                    inputReceived.Set();
                });

                inputReceived.Wait();
                userText = result;
            }

            return true;
        }

        public void DisplayCabinetMessageDialog()
        {
            DisplayMessageDialog("Amiibo", "Please scan your Amiibo now.");
        }

        public bool DisplayErrorAppletDialog(string title, string message, string[] buttonsText, (uint Module, uint Description)? errorCode = null)
        {
            string errorSuffix = errorCode.HasValue
                ? $"\n\nError Code: {errorCode.Value.Module:X4}-{errorCode.Value.Description:X4}"
                : string.Empty;

            Logger.Error?.Print(LogClass.Application, $"{title}: {message}{errorSuffix}");

            DisplayMessageDialog(title, message + errorSuffix);

            return true;
        }

        public IDynamicTextInputHandler CreateDynamicTextInputHandler()
        {
            return new NativeDynamicTextInputHandler();
        }

        public void ExecuteProgram(Switch device, ProgramSpecifyKind kind, ulong value)
        {
            device.Configuration.UserChannelPersistence.ExecuteProgram(kind, value);

            Exit();
        }

        public Ryujinx.HLE.HOS.Services.Account.Acc.UserProfile ShowPlayerSelectDialog()
        {
            return AccountSaveDataManager.GetLastUsedUser();
        }

        public void TakeScreenshot()
        {
            Logger.Warning?.Print(LogClass.Application, "TakeScreenshot is not supported in headless mode.");
        }

        public void Dispose()
        {
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing && Interlocked.Exchange(ref _windowDisposed, 1) == 0)
            {
                _isActive = false;
                _scheduler.Stop();
                UnsubscribeInputEvents();
                // Library 在调用前已完成 Device.Dispose/DisposeGpu；后端退出后才能销毁宿主等待门。
                if (_renderLoopThread != null && _renderLoopThread != Thread.CurrentThread) _renderLoopThread.Join();
                TouchScreenManager?.Dispose();
                NpadManager.Dispose();
                _keyboardInterface.Dispose();
                MouseDriver.Dispose();
                _scheduler.Dispose();
                _gpuCancellationTokenSource.Dispose();
                _exitEvent.Dispose();
                _gpuDoneEvent.Dispose();
            }
        }

        internal sealed class StatisticsRequest
        {
            public double FPS { get; set; } = 0d;
            public double FrameTime { get; set; } = 0d;
            public bool Started { get; set; } = false;
            public double FIFO { get; set; } = 0d;
        }
    }
}
