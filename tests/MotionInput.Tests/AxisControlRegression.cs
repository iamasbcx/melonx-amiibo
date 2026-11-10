using System.Numerics;
using Ryujinx.Input;
using Ryujinx.Input.Motion;

// 通过生产 MotionInput 验证相对运动契约；期望来自已知物理轨迹和解析旋转，不复制实现积分过程。
internal static class AxisControlRegression
{
    private const ulong Step = 10_000;
    private static readonly Vector3[] InitialGravities =
    {
        Vector3.UnitZ, Vector3.UnitY, -Vector3.UnitZ, Vector3.Normalize(new Vector3(0.3f, 0.8f, 0.52f)),
        Vector3.Transform(Vector3.UnitZ, Quaternion.Conjugate(Quaternion.CreateFromAxisAngle(Vector3.Normalize(new Vector3(1, 1, 0)), MathF.PI / 4))),
        Vector3.Transform(Vector3.UnitZ, Quaternion.Conjugate(Quaternion.CreateFromAxisAngle(Vector3.Normalize(new Vector3(1, 1, 0)), 75 * MathF.PI / 180))),
    };

    public static void Run(List<string> failures)
    {
        CheckPhysicalParity(failures);
        foreach (Vector3 gravity in InitialGravities)
        {
            foreach (Vector3 axis in new[] { Vector3.UnitX, Vector3.UnitY, Vector3.UnitZ })
            {
                foreach (float factor in new[] { -1f, 0f, 1f }) CheckAxis(gravity, axis, factor, failures);
            }
        }
        CheckCombinedAndReturn(failures);
        CheckControlsSwitch(failures);
        CheckOrientationBoundary(failures);
        CheckSuspensionBoundary(failures);
        CheckDeadzoneAfterMask(failures);
        CheckSourceSwitch(failures);
        CheckInvalidSamples(failures);
        Console.WriteLine("手机运动：多握姿三轴正反/禁用、组合/回零、冷启动、转屏、暂停姿态变化、死区及来源切换已检查");
    }

    private static void CheckPhysicalParity(List<string> failures)
    {
        var actual = new MotionInput();
        var reference = new MotionSensorFilter(0f);
        Vector3 rotation = Vector3.Zero;
        for (ulong index = 1; index <= 360; index++)
        {
            float radians = MathF.Min(index, 120) * MathF.PI / 720f;
            Vector3 accel = new(0, MathF.Sin(radians), MathF.Cos(radians));
            Vector3 gyro = index < 120 ? new Vector3(15, -3, 2) : Vector3.Zero;
            actual.Update(accel, gyro, index * Step, 100, 0);
            if (index == 1) continue;
            reference.SamplePeriod = 0.01f;
            reference.Update(accel, gyro * (MathF.PI / 180));
            rotation += gyro * 0.01f;
            Require(actual.GetOrientation() == Matrix4x4.CreateFromQuaternion(reference.Quaternion) &&
                    actual.Accelerometer == -accel && actual.Gyroscrope == gyro && actual.Rotation == rotation,
                "实体手柄的原有物理滤波或输出被改变", failures);
        }
    }

    private static void CheckAxis(Vector3 initialGravity, Vector3 axis, float factor, List<string> failures)
    {
        var motion = new MotionInput();
        ulong time = 0;
        Vector3 factors = Vector3.One + axis * (factor - 1);
        for (int i = 0; i < 300; i++)
        {
            Phone(motion, initialGravity, Vector3.Zero, time += Step, factors);
            Require(motion.GetOrientation() == Matrix4x4.Identity, "冷启动倾斜姿态产生自动纠偏运动", failures);
        }
        Vector3 translation = new(0.25f, -0.15f, 0.1f);
        Vector3 gravity = initialGravity;
        for (int i = 1; i <= 200; i++)
        {
            Quaternion physical = Quaternion.CreateFromAxisAngle(axis, i * 0.3f * MathF.PI / 180);
            gravity = Vector3.Transform(initialGravity, Quaternion.Conjugate(physical));
            Phone(motion, gravity, axis * 30, time += Step, factors, translation: translation);
        }
        Quaternion expected = Quaternion.CreateFromAxisAngle(axis, factor * 60 * MathF.PI / 180);
        Require(Angle(motion.GetOrientation(), Matrix4x4.CreateFromQuaternion(expected)) < 0.002f,
            $"单轴控制不符：gravity={initialGravity}, axis={axis}, factor={factor}", failures);
        Vector3 expectedGravity = Vector3.Transform(initialGravity, Quaternion.Conjugate(expected));
        Require(Vector3.Distance(motion.Accelerometer, -(translation + expectedGravity)) < 0.0001f,
            "虚拟重力或受控平移没有保持正确分量", failures);
        Require(Vector3.Distance(motion.Rotation, axis * factor * 60) < 0.001f,
            "游戏角度积分没有应用轴控制", failures);

        Matrix4x4 beforeStop = motion.GetOrientation();
        Vector3 rotationBeforeStop = motion.Rotation;
        for (int i = 0; i < 1000; i++) Phone(motion, gravity, Vector3.Zero, time += Step, factors);
        Require(motion.GetOrientation() == beforeStop && motion.Rotation == rotationBeforeStop && motion.Gyroscrope == Vector3.Zero,
            "停止后重力仍驱动游戏姿态，或禁用轴泄漏到其他轴", failures);
    }

    private static void CheckCombinedAndReturn(List<string> failures)
    {
        var motion = new MotionInput();
        ulong time = Step;
        Vector3 gravity = InitialGravities[3];
        Phone(motion, gravity, Vector3.Zero, time, Vector3.One);
        Vector3 factors = new(-1, 0, 1);
        for (int i = 0; i < 100; i++) Phone(motion, gravity, new Vector3(20, 30, -10), time += Step, factors);
        Vector3 command = new(-20, 0, -10);
        Quaternion expected = Quaternion.CreateFromAxisAngle(Vector3.Normalize(command), command.Length() * MathF.PI / 180);
        Require(Angle(motion.GetOrientation(), Matrix4x4.CreateFromQuaternion(expected)) < 0.002f,
            "多轴同时输入的禁用/反向结果错误", failures);

        var sequence = new MotionInput();
        time = Step;
        Phone(sequence, gravity, Vector3.Zero, time, Vector3.One);
        foreach (Vector3 gyro in new[] { new Vector3(90, 0, 0), new Vector3(0, 90, 0) })
        {
            for (int i = 0; i < 100; i++) Phone(sequence, gravity, gyro, time += Step, Vector3.One);
        }
        Quaternion composed = Quaternion.CreateFromAxisAngle(Vector3.UnitX, MathF.PI / 2) *
                              Quaternion.CreateFromAxisAngle(Vector3.UnitY, MathF.PI / 2);
        Require(Angle(sequence.GetOrientation(), Matrix4x4.CreateFromQuaternion(composed)) < 0.002f,
            "局部旋转组合顺序错误", failures);
        foreach (Vector3 gyro in new[] { new Vector3(0, -90, 0), new Vector3(-90, 0, 0) })
        {
            for (int i = 0; i < 100; i++) Phone(sequence, gravity, gyro, time += Step, Vector3.One);
        }
        Require(Angle(sequence.GetOrientation(), Matrix4x4.Identity) < 0.002f, "反向原路旋转未返回零点", failures);
    }

    private static void CheckControlsSwitch(List<string> failures)
    {
        var motion = new MotionInput();
        ulong time = Step;
        Phone(motion, Vector3.UnitZ, Vector3.Zero, time, Vector3.One);
        for (int i = 0; i < 50; i++) Phone(motion, Vector3.UnitZ, new Vector3(30, 0, 0), time += Step, Vector3.One);
        Matrix4x4 before = motion.GetOrientation();
        foreach (Vector3 factors in new[] { new Vector3(-1, 0, 1), Vector3.Zero, Vector3.One })
        {
            Phone(motion, Vector3.UnitY, Vector3.Zero, time += Step, factors);
            Require(motion.GetOrientation() == before, "切换开关时丢失相对姿态或发生重力纠偏", failures);
        }
    }

    private static void CheckOrientationBoundary(List<string> failures)
    {
        for (int from = 0; from < 4; from++)
        {
            for (int to = 0; to < 4; to++)
            {
                if (from == to) continue;
                var motion = new MotionInput();
                ulong time = Step;
                Vector3 gravity = InitialGravities[3];
                Phone(motion, gravity, Vector3.Zero, time, Vector3.One, from);
                for (int i = 0; i < 50; i++) Phone(motion, gravity, new Vector3(0, 0, 30), time += Step, Vector3.One, from);
                Matrix4x4 before = motion.GetOrientation();
                Vector3 accelerationBefore = motion.Accelerometer;
                Vector3 rotationBefore = motion.Rotation;
                Vector3 changedGravity = new(-gravity.Y, gravity.X, gravity.Z);
                Phone(motion, changedGravity, new Vector3(120, 90, -30), time += 1_000_000, Vector3.One, to);
                Require(motion.GetOrientation() == before && motion.Accelerometer == accelerationBefore &&
                        motion.Rotation == rotationBefore && motion.Gyroscrope == Vector3.Zero,
                    "界面方向边界积分旧时间或跳变游戏重力/姿态", failures);
                for (int i = 0; i < 1000; i++) Phone(motion, changedGravity, Vector3.Zero, time += Step, Vector3.One, to);
                Require(motion.GetOrientation() == before && motion.Accelerometer == accelerationBefore,
                    "转屏后零角速度仍发生重力回拉", failures);
                for (int i = 0; i < 100; i++) Phone(motion, changedGravity, new Vector3(30, 0, 0), time += Step, Vector3.One, to);
                Quaternion expected = Quaternion.CreateFromRotationMatrix(before) * Quaternion.CreateFromAxisAngle(Vector3.UnitX, MathF.PI / 6);
                Require(Angle(motion.GetOrientation(), Matrix4x4.CreateFromQuaternion(expected)) < 0.002f,
                    "转屏后没有按新的屏幕轴继续响应", failures);
            }
        }
    }

    private static void CheckSuspensionBoundary(List<string> failures)
    {
        foreach (bool pollSuspended in new[] { false, true })
        foreach (float pausedPitch in new[] { 30f, 90f })
        foreach (Vector3 factors in new[] { Vector3.One, new Vector3(-1, 1, 1) })
        {
            var motion = new MotionInput();
            ulong time = Step;
            Phone(motion, Vector3.UnitZ, Vector3.Zero, time, factors);
            for (int i = 0; i < 100; i++) Phone(motion, Vector3.UnitZ, new Vector3(20, 0, 0), time += Step, factors);
            Matrix4x4 before = motion.GetOrientation();
            Vector3 accelerationBefore = motion.Accelerometer;
            Vector3 rotationBefore = motion.Rotation;
            if (pollSuspended)
            {
                Phone(motion, Vector3.UnitZ, Vector3.Zero, time += Step, factors, epoch: 1, suspended: true);
            }
            Vector3 changedGravity = Vector3.Transform(Vector3.UnitZ,
                Quaternion.Conjugate(Quaternion.CreateFromAxisAngle(Vector3.UnitX, pausedPitch * MathF.PI / 180)));
            Phone(motion, changedGravity, new Vector3(60, 0, 0), time += 120_000_000, factors, epoch: 1);
            Require(motion.GetOrientation() == before && motion.Rotation == rotationBefore &&
                    motion.Accelerometer == accelerationBefore && motion.Gyroscrope == Vector3.Zero,
                "恢复首帧积分暂停时长或丢失游戏姿态", failures);
            for (int i = 0; i < 1000; i++) Phone(motion, changedGravity, Vector3.Zero, time += Step, factors, epoch: 1);
            Require(motion.GetOrientation() == before && motion.Accelerometer == accelerationBefore,
                "暂停期间手机姿态变化在恢复后产生持续运动", failures);
        }
    }

    private static void CheckDeadzoneAfterMask(List<string> failures)
    {
        var motion = new MotionInput();
        Phone(motion, Vector3.UnitZ, Vector3.Zero, Step, Vector3.One);
        for (ulong i = 2; i <= 102; i++)
        {
            motion.Update(Vector3.UnitZ, new Vector3(300, 0.01f, 0), i * Step, 100, 0.1f,
                Vector3.UnitZ, new Vector3(0, 1, 1), 0);
        }
        Require(motion.GetOrientation() == Matrix4x4.Identity && motion.Gyroscrope == Vector3.Zero && motion.Rotation == Vector3.Zero,
            "禁用轴的大角速度使其他轴噪声越过死区", failures);
    }

    private static void CheckSourceSwitch(List<string> failures)
    {
        var motion = new MotionInput();
        ulong time = Step;
        Phone(motion, Vector3.UnitY, Vector3.Zero, time, Vector3.One);
        for (int i = 0; i < 100; i++) Phone(motion, Vector3.UnitY, new Vector3(30, 0, 0), time += Step, new Vector3(-1, 1, 1));
        motion.Update(Vector3.UnitZ, Vector3.Zero, time += Step, 100, 0);
        Require(motion.GetOrientation() == Matrix4x4.Identity && motion.Rotation == Vector3.Zero,
            "切换实体来源后残留手机相对姿态", failures);
        motion.Update(Vector3.UnitZ, new Vector3(0, 0, 30), time += Step, 100, 0);
        Require(motion.Gyroscrope.Z == 30, "实体来源仍受手机反向控制", failures);
        Phone(motion, Vector3.UnitX, new Vector3(50, 0, 0), time += Step, Vector3.One);
        Require(motion.GetOrientation() == Matrix4x4.Identity && motion.Rotation == Vector3.Zero && motion.Accelerometer == -Vector3.UnitX,
            "新手机会话未重新捕获零点与重力参考", failures);
    }

    private static void CheckInvalidSamples(List<string> failures)
    {
        foreach (Action action in new Action[]
        {
            () => new MotionInput().Update(Vector3.UnitZ, Vector3.Zero, 1, 100, 0, Vector3.UnitZ),
            () => new MotionInput().Update(Vector3.UnitZ, Vector3.Zero, 1, 100, 0, Vector3.UnitZ, Vector3.One, 4),
            () => new MotionInput().Update(Vector3.UnitZ, Vector3.Zero, 1, 100, 0, Vector3.Zero, Vector3.One, 0),
            () => new MotionInput().Update(Vector3.UnitZ, Vector3.Zero, 1, 100, 0, Vector3.UnitZ, new Vector3(float.NaN, 1, 1), 0),
            () => new MotionInput().Update(Vector3.UnitZ, new Vector3(float.NaN, 0, 0), 1, 100, 0, Vector3.UnitZ, Vector3.One, 0),
        })
        {
            try { action(); failures.Add("不完整或非法手机采样未明确拒绝"); }
            catch (ArgumentException) { }
        }
    }

    private static void Phone(MotionInput motion, Vector3 gravity, Vector3 gyro, ulong time, Vector3 factors,
        int orientation = 0, ulong epoch = 0, bool suspended = false, Vector3 translation = default) =>
        motion.Update(gravity + translation, gyro, time, 100, 0, gravity, factors, orientation, epoch, suspended);

    private static float Angle(Matrix4x4 a, Matrix4x4 b)
    {
        if (a == b) return 0;
        Quaternion delta = Quaternion.Normalize(Quaternion.Conjugate(Quaternion.CreateFromRotationMatrix(a)) * Quaternion.CreateFromRotationMatrix(b));
        return 2 * MathF.Atan2(new Vector3(delta.X, delta.Y, delta.Z).Length(), MathF.Abs(delta.W)) * 180 / MathF.PI;
    }

    private static void Require(bool condition, string error, List<string> failures)
    {
        if (!condition && !failures.Contains(error)) failures.Add(error);
    }
}
