using Ryujinx.Input.Motion;
using System;
using System.Numerics;

namespace Ryujinx.Input
{
    public class MotionInput
    {
        public ulong TimeStamp { get; set; }
        public Vector3 Accelerometer { get; set; }
        public Vector3 Gyroscrope { get; set; }
        public Vector3 Rotation { get; set; }

        private readonly MotionSensorFilter _filter = new(0f);
        private readonly MotionAxisTransform _phoneOrientation = new();
        private ulong _motionEpoch;
        private bool _wasMotionSuspended;
        private bool _isPhoneSource;
        private int? _screenOrientation;
        private Vector3 _lastGameGravity;

        /// <summary>
        /// 更新同一输入设备的运动。手机须同时提供独立 gravity、rotationFactors 和 screenOrientation；
        /// 实体设备三项均为 null，保留原有 Mahony 融合。所有状态由同一采样线程持有。
        /// 手机姿态只积分经过开关/反向的角速度，重力反馈不进入控制增量，因此禁用轴不会泄漏到其他轴。
        /// 暂停、转屏和来源变化的首帧仅重建时间基准，不积分未观测时段；转屏/暂停保留相对游戏姿态。
        /// </summary>
        public void Update(Vector3 accel, Vector3 gyro, ulong timestamp, int sensitivity, float deadzone,
            Vector3? gravity = null, Vector3? rotationFactors = null, int? screenOrientation = null,
            ulong motionEpoch = 0, bool isMotionSuspended = false)
        {
            bool phoneSource = gravity.HasValue || rotationFactors.HasValue || screenOrientation.HasValue;
            if (phoneSource && (gravity is not Vector3 phoneGravity || rotationFactors is not Vector3 factors ||
                screenOrientation is not int orientation || !GamepadMotionSample.IsPhoneSampleValid(accel, gyro, phoneGravity, factors, orientation)))
            {
                throw new ArgumentException("Phone motion requires finite vectors, nonzero gravity, factors -1/0/1 and screen orientation 0..3.");
            }

            bool sourceChanged = phoneSource != _isPhoneSource;
            bool orientationChanged = phoneSource && _screenOrientation != screenOrientation;
            if (sourceChanged)
            {
                _isPhoneSource = phoneSource;
                Rotation = Vector3.Zero;
                if (phoneSource)
                {
                    _phoneOrientation.Initialize(gravity!.Value);
                    _lastGameGravity = _phoneOrientation.GravityForGame();
                }
                else
                {
                    _filter.Reset();
                    _lastGameGravity = Vector3.Zero;
                }
            }
            _screenOrientation = screenOrientation;

            bool rebaseTime = TimeStamp == 0 || sourceChanged || orientationChanged ||
                _motionEpoch != motionEpoch || _wasMotionSuspended;
            _motionEpoch = motionEpoch;
            _wasMotionSuspended = isMotionSuspended;
            if (isMotionSuspended || rebaseTime)
            {
                Accelerometer = -_lastGameGravity;
                Gyroscrope = Vector3.Zero;
                TimeStamp = timestamp;
                return;
            }

            float deltaTime = MathF.Abs((long)(timestamp - TimeStamp) / 1000000f);
            if (phoneSource)
            {
                // 先屏蔽方向再判断死区，禁用轴的大角速度不能使其他轴的小噪声越过门槛。
                Vector3 controlledGyro = gyro * rotationFactors!.Value;
                if (controlledGyro.Length() < deadzone)
                {
                    controlledGyro = Vector3.Zero;
                }
                controlledGyro *= sensitivity / 100f;
                Gyroscrope = controlledGyro;
                Rotation += controlledGyro * deltaTime;
                _phoneOrientation.Update(controlledGyro, deltaTime);
                _lastGameGravity = _phoneOrientation.GravityForGame();
                Accelerometer = -(accel - gravity!.Value + _lastGameGravity);
            }
            else
            {
                // 实体手柄继续使用原来的加速度、角速度与物理融合规则。
                Accelerometer = -accel;
                if (gyro.Length() < deadzone)
                {
                    gyro = Vector3.Zero;
                }
                gyro *= sensitivity / 100f;
                Gyroscrope = gyro;
                Rotation += gyro * deltaTime;
                _filter.SamplePeriod = deltaTime;
                _filter.Update(accel, DegreeToRad(gyro));
            }

            TimeStamp = timestamp;
        }

        public Matrix4x4 GetOrientation() => Matrix4x4.CreateFromQuaternion(
            _isPhoneSource ? _phoneOrientation.Orientation : _filter.Quaternion);

        private static Vector3 DegreeToRad(Vector3 degree) => degree * (MathF.PI / 180);
    }
}