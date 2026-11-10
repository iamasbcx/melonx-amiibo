using System;
using System.Numerics;

namespace Ryujinx.Input.Motion
{
    /// <summary>
    /// 手机的相对游戏姿态。初次采样定义零点；仅积分受控角速度，不引入物理重力纠偏。
    /// 由 MotionInput 的单一采样线程持有。转屏、暂停和开关变化保留当前姿态与重力参考。
    /// </summary>
    internal sealed class MotionAxisTransform
    {
        private Quaternion _orientation = Quaternion.Identity;
        private Vector3 _referenceGravity;

        public Quaternion Orientation => _orientation;

        /// <summary>新手机输入会话捕获初始重力；任意初始握姿均为相对零点，不进行自动回正。</summary>
        public void Initialize(Vector3 gravity)
        {
            _orientation = Quaternion.Identity;
            _referenceGravity = gravity;
        }

        /// <summary>积分当前屏幕局部轴的角速度（deg/s）；调用方已施加开关、反向、死区和灵敏度。</summary>
        public void Update(Vector3 controlledGyroscope, float deltaTime)
        {
            Vector3 rotation = controlledGyroscope * (deltaTime * MathF.PI / 180f);
            float angle = rotation.Length();
            if (angle == 0f)
            {
                return;
            }

            Quaternion delta = Quaternion.CreateFromAxisAngle(rotation / angle, angle);
            _orientation = Quaternion.Normalize(_orientation * delta);
        }

        /// <summary>游戏重力只随游戏姿态变化；物理重力仅供上层分离平移，不用于纠偏游戏视角。</summary>
        public Vector3 GravityForGame() => Vector3.Transform(_referenceGravity, Quaternion.Conjugate(_orientation));
    }
}