using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Input;
using System;
using System.Drawing;
using System.Numerics;

namespace Ryujinx.Library
{
    class NativeMouse : ITouchScreen
    {
        private readonly NativeTouchDriver _driver;

        public GamepadFeaturesFlag Features => throw new NotImplementedException();

        public string Id => "0";

        public string Name => "NativeMouse";

        public bool IsConnected => true;

        public bool[] Buttons => _driver.PressedButtons;

        Size ITouchScreen.ClientSize => _driver.GetClientSize();

        public NativeMouse(NativeTouchDriver driver)
        {
            _driver = driver;
        }
        

        public int CopyTouches(Span<TouchSnapshot> destination)
        {
            return _driver.CopyTouches(destination);
        }

        public Vector2 GetScroll()
        {
            return _driver.Scroll;
        }

        public GamepadStateSnapshot GetMappedStateSnapshot()
        {
            throw new NotImplementedException();
        }

        public Vector3 GetMotionData(MotionInputId inputId)
        {
            throw new NotImplementedException();
        }

        public GamepadStateSnapshot GetStateSnapshot()
        {
            throw new NotImplementedException();
        }

        public (float, float) GetStick(StickInputId inputId)
        {
            throw new NotImplementedException();
        }

        public bool IsButtonPressed(MouseButton button)
        {
            return _driver.IsAnyPressed(button);
        }

        public bool IsPressed(GamepadButtonInputId inputId)
        {
            throw new NotImplementedException();
        }

        public void Rumble(float lowFrequency, float highFrequency, uint durationMs)
        {
            throw new NotImplementedException();
        }

        public void SetConfiguration(InputConfig configuration)
        {
            throw new NotImplementedException();
        }

        public void SetTriggerThreshold(float triggerThreshold)
        {
            throw new NotImplementedException();
        }

        public void SetLed(uint packedRgb)
        {
            throw new NotImplementedException();
        }

        public void Dispose()
        {
            // 此对象是驱动拥有的共享只读入口，状态资源只由 NativeTouchDriver.Dispose 释放。
        }
    }
}
