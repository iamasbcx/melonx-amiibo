using Ryujinx.Common.Logging;
using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Services.Nfc.Nfp;
using Ryujinx.Library.Amiibo;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Library
{
    partial class Library
    {
        // 锁顺序为宿主生命周期门 -> HLE 的 NFP 门。停止必须先撤销入口，再释放核心。
        private static readonly object AmiiboSessionGate = new();
        private static readonly object AmiiboCloseGate = new();
        private static Switch _amiiboContext;
        private static uint _amiiboSessionId;
        private static int _amiiboLastResult;

        private static void BeginAmiiboSession(Switch context)
        {
            lock (AmiiboSessionGate)
            {
                _amiiboSessionId = checked(_amiiboSessionId + 1);
                _amiiboContext = context;
                _amiiboLastResult = (int)AmiiboResult.Ok;
            }
        }

        /// <summary>撤销当前会话并等待检测任务退出；允许停止路径重复调用，不保留来宾对象引用。</summary>
        internal static void EndAmiiboSession(Switch context)
        {
            lock (AmiiboCloseGate)
            {
                lock (AmiiboSessionGate)
                {
                    if (context == null || !ReferenceEquals(_amiiboContext, context))
                    {
                        return;
                    }

                    _amiiboContext = null;
                    _amiiboLastResult = (int)AmiiboResult.NotRunning;
                }

                // 检测任务可能使用 NFP 门，取消与等待不能持有该门。
                context.System.CloseVirtualAmiiboSession();
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "mlx_amiibo_get_abi", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static unsafe int GetAmiiboAbi(uint* version, uint* capabilities)
        {
            if (version == null || capabilities == null)
            {
                return (int)AmiiboResult.InvalidArgument;
            }

            *version = AmiiboContract.Version;
            *capabilities = 3; // 位 0：虚拟身份提交；位 1：用户自定义身份。默认不附带任何角色目录。
            return (int)AmiiboResult.Ok;
        }

        [UnmanagedCallersOnly(EntryPoint = "mlx_amiibo_get_state", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static unsafe int GetAmiiboState(AmiiboStateNative* state, uint stateSize)
        {
            if (state == null)
            {
                return (int)AmiiboResult.InvalidArgument;
            }
            if (stateSize != AmiiboContract.StateSize)
            {
                return (int)(stateSize < AmiiboContract.StateSize ? AmiiboResult.BufferTooSmall : AmiiboResult.AbiMismatch);
            }

            *state = new AmiiboStateNative
            {
                AbiVersion = AmiiboContract.Version,
                StructSize = AmiiboContract.StateSize,
            };

            try
            {
                lock (AmiiboSessionGate)
                {
                    state->SessionId = _amiiboSessionId;
                    state->LastResult = _amiiboLastResult;
                    if (_amiiboContext == null)
                    {
                        return (int)AmiiboResult.Ok;
                    }

                    VirtualAmiiboStatus status = _amiiboContext.System.GetVirtualAmiiboStatus();
                    state->DetectionEpoch = checked((uint)status.DetectionEpoch);
                    state->Flags = AmiiboContract.Running;
                    if (_amiiboContext.System.IsPaused)
                    {
                        state->Flags |= AmiiboContract.Paused;
                    }
                    if (status.IsSearching)
                    {
                        state->Flags |= AmiiboContract.Searching;
                    }
                    return (int)AmiiboResult.Ok;
                }
            }
            catch (Exception)
            {
                return (int)AmiiboResult.InternalError;
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "mlx_amiibo_scan", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static unsafe int ScanVirtualAmiibo(AmiiboScanNative* request, uint requestSize)
        {
            if (request == null)
            {
                return (int)AmiiboResult.InvalidArgument;
            }
            if (requestSize != AmiiboContract.RequestSize)
            {
                return (int)(requestSize < AmiiboContract.RequestSize ? AmiiboResult.BufferTooSmall : AmiiboResult.AbiMismatch);
            }

            // 所有输入在返回前复制；调用者只需在本次 C 调用期间保持缓冲区有效。
            AmiiboScanNative input = *request;
            if (input.AbiVersion != AmiiboContract.Version || input.StructSize != AmiiboContract.RequestSize)
            {
                return (int)AmiiboResult.AbiMismatch;
            }

            try
            {
                string id = AmiiboContract.ReadId(new ReadOnlySpan<byte>(input.AmiiboId, 16));
                if (id == null)
                {
                    return (int)AmiiboResult.InvalidArgument;
                }
                lock (AmiiboSessionGate)
                {
                    AmiiboResult result;
                    if (_amiiboContext == null)
                    {
                        result = AmiiboResult.NotRunning;
                    }
                    else if (input.SessionId != _amiiboSessionId)
                    {
                        result = AmiiboResult.StaleSession;
                    }
                    else if (_amiiboContext.System.IsPaused)
                    {
                        result = AmiiboResult.Paused;
                    }
                    else
                    {
                        result = _amiiboContext.System.TryScanVirtualAmiibo(input.DetectionEpoch, id) switch
                        {
                            VirtualAmiiboScanResult.Accepted => AmiiboResult.Ok,
                            VirtualAmiiboScanResult.NotSearching => AmiiboResult.NotSearching,
                            VirtualAmiiboScanResult.StaleDetection => AmiiboResult.StaleDetection,
                            VirtualAmiiboScanResult.InvalidId => AmiiboResult.InvalidArgument,
                            VirtualAmiiboScanResult.Unavailable => AmiiboResult.NotRunning,
                            VirtualAmiiboScanResult.EventsNotReady => AmiiboResult.Busy,
                            _ => AmiiboResult.InternalError,
                        };
                    }

                    _amiiboLastResult = (int)result;
                    return (int)result;
                }
            }
            catch (Exception)
            {
                // 不跨 C ABI 抛出托管异常，也不把路径、标签数据或密钥写入日志。
                Logger.Error?.Print(LogClass.ServiceNfp, "Virtual amiibo request failed.");
                return (int)AmiiboResult.InternalError;
            }
        }
    }
}
