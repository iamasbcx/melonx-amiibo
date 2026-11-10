using System;
using System.Numerics;

namespace Ryujinx.Input.Motion
{
    /// <summary>
    /// 把物理姿态的局部增量转换为游戏姿态，避免将反向角速度送回重力融合器。
    /// 由 MotionInput 的单一采样线程持有；参数切换只影响后续增量，不重置当前游戏姿态。
    /// </summary>
    internal sealed class MotionAxisTransform
    {
        private bool _isControlled;
        private Quaternion _orientation = Quaternion.Identity;
        private Vector3 _referenceGravity = Vector3.UnitZ;
        private Vector3? _previousGravity;

        public Quaternion Orientation => _orientation;
        public bool IsControlled => _isControlled;

        public void Update(Quaternion previousPhysical, Quaternion currentPhysical, Vector3 gravity, Vector3? factors)
        {
            Vector3 activationGravity = _previousGravity ?? gravity;
            _previousGravity = gravity;
            if (factors is not Vector3 scale)
            {
                // 切到独立的实体手柄路径时不保留手机的控制偏置。
                _isControlled = false;
                _orientation = currentPhysical;
                return;
            }

            if (!_isControlled && scale == Vector3.One)
            {
                // 未启用自定义控制时逐位保留原滤波结果，不引入多余的四元数舍入。
                _orientation = currentPhysical;
                return;
            }

            if (!_isControlled)
            {
                _isControlled = true;
                _orientation = previousPhysical;
                float length = activationGravity.Length();
                _referenceGravity = length > 0f && float.IsFinite(length)
                    ? Vector3.Transform(activationGravity / length, previousPhysical)
                    : Vector3.UnitZ;
            }

            // q_new = q_old * delta；在局部旋转向量上逐轴控制，避开欧拉角万向节锁。
            Quaternion delta = Quaternion.Normalize(Quaternion.Conjugate(previousPhysical) * currentPhysical);
            if (delta.W < 0f)
            {
                delta = -delta;
            }
            Vector3 imaginary = new(delta.X, delta.Y, delta.Z);
            float sineHalfAngle = imaginary.Length();
            if (sineHalfAngle <= 1e-8f)
            {
                return;
            }
            Vector3 rotation = imaginary * (2f * MathF.Atan2(sineHalfAngle, delta.W) / sineHalfAngle) * scale;
            float angle = rotation.Length();
            if (angle <= 1e-8f)
            {
                return;
            }
            Quaternion controlledDelta = Quaternion.CreateFromAxisAngle(rotation / angle, angle);
            _orientation = Quaternion.Normalize(_orientation * controlledDelta);
        }

        public Vector3 GravityForGame(Vector3 physicalGravity)
        {
            if (!_isControlled)
            {
                return physicalGravity;
            }

            // 固定激活前一帧的世界重力参考，使禁用轴不会被物理融合的残余收敛重新带动。
            // 游戏自行融合加速度时，看到的重力也与受控姿态一致；平移分量由调用方另行保留。
            return Vector3.Transform(_referenceGravity, Quaternion.Conjugate(_orientation)) * physicalGravity.Length();
        }
    }
}
