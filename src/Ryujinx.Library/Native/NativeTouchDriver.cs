using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Input;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Numerics;
using System.Runtime.InteropServices;

namespace Ryujinx.Library
{
    class NativeTouchDriver : IGamepadDriver
    {
        private const int CursorHideIdleTime = 5;

        private bool _isDisposed;
        private readonly HideCursorMode _hideCursorMode;
        private bool _isHidden;
        private long _lastCursorMoveTime;

        public bool[] PressedButtons { get; }
        public Vector2 Scroll { get; private set; }
        public Size ClientSize;

        private static readonly NativeTouchState _touchState = new();
        private static readonly string[] _gamepadIds = ["0"];
        private readonly NativeMouse _mouse;
        public static event Action OnInputUpdated;

        public NativeTouchDriver(HideCursorMode hideCursorMode)
        {
            PressedButtons = new bool[(int)MouseButton.Count];
            _hideCursorMode = hideCursorMode;
            _mouse = new NativeMouse(this);
            // 每局窗口独占触摸驱动，不能沿用上局未收到抬起的手指。
            _touchState.Clear();
        }

        [UnmanagedCallersOnly(EntryPoint = "touch_began")]
        public static void TouchBeganAtPoint(float x, float y, int index)
        {
            if (_touchState.Begin(index, new Vector2(x, y))) OnInputUpdated?.Invoke();
        }


        [UnmanagedCallersOnly(EntryPoint = "touch_moved")]
        public static void TouchMovedAtPoint(float x, float y, int index)
        {
            if (_touchState.Move(index, new Vector2(x, y))) OnInputUpdated?.Invoke();
        }

        [UnmanagedCallersOnly(EntryPoint = "touch_ended")]
        public static void TouchEndedForIndex(int index)
        {
            if (_touchState.End(index)) OnInputUpdated?.Invoke();
        }

        public void UpdatePosition()
        {
            CheckIdle();
        }

        public int CopyTouches(Span<TouchSnapshot> destination) => _isDisposed ? 0 : _touchState.CopyTo(destination);

        private void CheckIdle()
        {
            if (_hideCursorMode != HideCursorMode.OnIdle)
            {
                return;
            }

            long cursorMoveDelta = Stopwatch.GetTimestamp() - _lastCursorMoveTime;

            if (cursorMoveDelta >= CursorHideIdleTime * Stopwatch.Frequency)
            {
                if (!_isHidden)
                {
                    Logger.Debug?.Print(LogClass.Application, "Hiding cursor due to inactivity.");
                    _isHidden = true;
                }
            }
            else
            {
                if (_isHidden)
                {
                    Logger.Debug?.Print(LogClass.Application, "Showing cursor after activity.");
                    _isHidden = false;
                }
            }
        }

        public IEnumerable<IGamepad> GetGamepads() => [GetGamepad("0")];

        public void SetClientSize(int width, int height)
        {
            ClientSize = new Size(width, height);
        }

        public bool IsAnyPressed(MouseButton button)
        {
            return !_isDisposed && _touchState.HasTouches;
        }

        public Size GetClientSize()
        {
            return ClientSize;
        }

        public string DriverName => "NativeTouchDriver";

        public event Action<string> OnGamepadConnected
        {
            add { }
            remove { }
        }

        public event Action<string> OnGamepadDisconnected
        {
            add { }
            remove { }
        }

        public ReadOnlySpan<string> GamepadsIds => _gamepadIds;

        public IGamepad GetGamepad(string id)
        {
            return _mouse;
        }

        public void Dispose()
        {
            if (_isDisposed)
            {
                return;
            }
            _isDisposed = true;
            _touchState.Clear();
        }
    }
}
