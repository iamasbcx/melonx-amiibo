using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.Apple.Native
{
    // 只替换 Apple 原生边界；被测会话、驱动、格式转换和 DSP 使用生产实现。
    internal static unsafe class AVFoundation
    {
        internal enum AVAudioCommonFormat { PcmFormatFloat32 }
        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioBuffer { public uint NumberChannels; public uint DataByteSize; public nint Data; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioBufferList { public uint NumberBuffers; public AudioBuffer Buffer; }
        internal delegate void CompletionCallback(nint block);
        private sealed class NativeObject
        {
            public string Kind;
            public uint Channels;
            public uint Capacity;
            public nint List;
            public nint Context;
            public CompletionCallback Callback;
        }
        internal record Scheduled(nint Buffer, nint Context, CompletionCallback Callback);
        private static readonly Dictionary<nint, NativeObject> _objects = new();
        internal static readonly List<Scheduled> Pending = new();
        private static int _next;
        internal static int PcmAllocations;
        internal static int EngineAllocations;
        internal static int PlayCalls;
        internal static bool FailStart;
        internal static int LiveObjects => _objects.Count;

        internal static nint Alloc(string kind)
        {
            nint id = ++_next;
            _objects.Add(id, new NativeObject { Kind = kind });
            if (kind == "AVAudioPCMBuffer") PcmAllocations++;
            if (kind == "AVAudioEngine") EngineAllocations++;
            return id;
        }
        internal static nint Init(nint receiver) => receiver;
        internal static nint InitAudioFormat(nint receiver, AVAudioCommonFormat format, double rate, uint channels)
        {
            _objects[receiver].Channels = channels;
            return receiver;
        }
        internal static nint InitPcmBuffer(nint receiver, nint format, uint capacity)
        {
            NativeObject value = _objects[receiver];
            value.Channels = _objects[format].Channels;
            value.Capacity = capacity;
            value.List = (nint)NativeMemory.AllocZeroed((nuint)(sizeof(AudioBufferList) + (value.Channels - 1) * sizeof(AudioBuffer)));
            AudioBufferList* list = (AudioBufferList*)value.List;
            list->NumberBuffers = value.Channels;
            AudioBuffer* buffers = &list->Buffer;
            for (int i = 0; i < value.Channels; i++)
            {
                buffers[i] = new AudioBuffer { NumberChannels = 1, DataByteSize = capacity * sizeof(float),
                    Data = (nint)NativeMemory.AllocZeroed(capacity, sizeof(float)) };
            }
            return receiver;
        }
        internal static void SetFrameLength(nint buffer, uint frames)
        {
            NativeObject value = _objects[buffer];
            if (frames > value.Capacity) throw new InvalidOperationException("Capacity exceeded");
            AudioBuffer* buffers = &((AudioBufferList*)value.List)->Buffer;
            for (int i = 0; i < value.Channels; i++) buffers[i].DataByteSize = frames * sizeof(float);
        }
        internal static AudioBufferList* GetMutableAudioBufferList(nint buffer) => (AudioBufferList*)_objects[buffer].List;
        internal static float[] ReadChannel(nint buffer, int channel)
        {
            AudioBuffer* data = &GetMutableAudioBufferList(buffer)->Buffer + channel;
            return new ReadOnlySpan<float>((void*)data->Data, (int)data->DataByteSize / sizeof(float)).ToArray();
        }
        internal static void AttachNode(nint engine, nint player) { }
        internal static void Connect(nint engine, nint player, nint mixer, nint format) { }
        internal static nint MainMixerNode(nint engine) => engine;
        internal static void Prepare(nint engine) { }
        internal static bool Start(nint engine, out nint error) { error = 0; return !FailStart; }
        internal static void Play(nint player) => PlayCalls++;
        internal static void Pause(nint player) { }
        // 保留复制的回调，以模拟 Stop 返回之后才到达的完成通知。
        internal static void Stop(nint player) { }
        internal static void SetVolume(nint player, float volume) { }
        internal static nint CreateCompletionBlock(nint context, CompletionCallback callback)
        {
            nint block = Alloc("Block");
            _objects[block].Context = context;
            _objects[block].Callback = callback;
            return block;
        }
        internal static nint GetBlockContext(nint block) => _objects[block].Context;
        internal static void DestroyCompletionBlock(nint block) => Release(block);
        internal static void ScheduleBuffer(nint player, nint buffer, nint block)
        {
            NativeObject value = _objects[block];
            Pending.Add(new Scheduled(buffer, value.Context, value.Callback));
        }
        internal static void Complete(int index = 0)
        {
            Scheduled callback = Pending[index];
            Pending.RemoveAt(index);
            nint copy = CreateCompletionBlock(callback.Context, callback.Callback);
            try { callback.Callback(copy); }
            finally { DestroyCompletionBlock(copy); }
        }
        internal static void Release(nint obj)
        {
            if (obj == 0) return;
            if (!_objects.Remove(obj, out NativeObject value)) throw new InvalidOperationException("Double release");
            if (value.List != 0)
            {
                AudioBuffer* buffers = &((AudioBufferList*)value.List)->Buffer;
                for (int i = 0; i < value.Channels; i++) NativeMemory.Free((void*)buffers[i].Data);
                NativeMemory.Free((void*)value.List);
            }
        }
    }
}
