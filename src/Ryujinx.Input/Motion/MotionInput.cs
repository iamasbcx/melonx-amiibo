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

        private readonly MotionSensorFilter _filter;
        private readonly MotionAxisTransform _axisTransform;
        private ulong _motionEpoch;
        private bool _wasMotionSuspended;
        private Vector3 _lastGameGravity;

        public MotionInput()
        {
            TimeStamp = 0;
            Accelerometer = new Vector3();
            Gyroscrope = new Vector3();
            Rotation = new Vector3();

            // TODO: RE the correct filter.
            _filter = new MotionSensorFilter(0f);
            _axisTransform = new MotionAxisTransform();
        }

        /// <summary>
        /// 更新运动状态。独立 gravity 只为融合器提供重力方向，避免平移加速度伪装成倾斜；
        /// 默认保留调用方加速度；自定义旋转时保留平移分量并合成相符的虚拟重力。
        /// 没有独立重力的实体设备仍使用自身加速度参与融合。
        /// rotationFactors 在核心屏幕轴上控制游戏输出；物理融合始终使用未经反向/禁用的角速度。
        /// motionEpoch 或暂停状态改变时跳过一次积分；本对象及所有输出由同一采样线程持有。
        /// </summary>
        public void Update(Vector3 accel, Vector3 gyro, ulong timestamp, int sensitivity, float deadzone, Vector3? gravity = null, Vector3? rotationFactors = null,
            ulong motionEpoch = 0, bool isMotionSuspended = false)
        {
            if (rotationFactors is Vector3 factors && !GamepadMotionSample.AreRotationFactorsValid(factors))
            {
                throw new ArgumentOutOfRangeException(nameof(rotationFactors), "Rotation factors must be -1, 0 or 1.");
            }

            // 挂起和恢复首帧只重建时间基准，绝不把设置页停留时间或旧角速度积分到游戏。
            // 暂停可能覆盖整个轮询间隔，因此还必须检查代数，不能只依赖消费者读到暂停标记。
            bool rebaseTime = _motionEpoch != motionEpoch || _wasMotionSuspended;
            _motionEpoch = motionEpoch;
            _wasMotionSuspended = isMotionSuspended;
            if (isMotionSuspended || rebaseTime)
            {
                Accelerometer = -_lastGameGravity;
                Gyroscrope = Vector3.Zero;
                TimeStamp = timestamp;
                return;
            }

            if (TimeStamp != 0)
            {
                Accelerometer = -accel;

                if (gyro.Length() < deadzone)
                {
                    gyro = Vector3.Zero;
                }

                gyro *= (sensitivity / 100f);

                Vector3 controlledGyro = gyro * (rotationFactors ?? Vector3.One);
                Gyroscrope = controlledGyro;

                float deltaTime = MathF.Abs((long)(timestamp - TimeStamp) / 1000000f);

                Vector3 deltaGyro = controlledGyro * deltaTime;

                Rotation += deltaGyro;

                _filter.SamplePeriod = deltaTime;
                Quaternion previousPhysical = _filter.Quaternion;
                _filter.Update(gravity ?? accel, DegreeToRad(gyro));
                _axisTransform.Update(previousPhysical, _filter.Quaternion, gravity ?? accel, rotationFactors);
                if (_axisTransform.IsControlled && gravity is Vector3 physicalGravity)
                {
                    // 只替换重力部分，平移开关/方向已经由手机输入适配层处理。
                    Accelerometer = -(accel - physicalGravity + _axisTransform.GravityForGame(physicalGravity));
                }
                // 暂停输出只保留上一有效帧的游戏重力；无独立重力的实体设备不猜测平移分量。
                _lastGameGravity = gravity is Vector3 currentGravity
                    ? _axisTransform.GravityForGame(currentGravity)
                    : Vector3.Zero;
            }

            TimeStamp = timestamp;
        }

        public Matrix4x4 GetOrientation()
        {
            return Matrix4x4.CreateFromQuaternion(_axisTransform.Orientation);
        }

        private static Vector3 DegreeToRad(Vector3 degree)
        {
            return degree * (MathF.PI / 180);
        }
    }
}
