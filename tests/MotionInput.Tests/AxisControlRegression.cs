using System.Numerics;
using Ryujinx.Input;
using Ryujinx.Input.Motion;

// 直接验证生产增量姿态变换及 MotionInput；覆盖任意初始姿态，避免只测试欧拉零点。
internal static class AxisControlRegression
{
    public static void Run(List<string> failures)
    {
        CheckDefaultParity(failures);
        foreach (Vector3 axis in new[] { Vector3.UnitX, Vector3.UnitY, Vector3.UnitZ })
        {
            foreach (float factor in new[] { -1f, 0f, 1f })
            {
                CheckAxis(axis, factor, failures);
            }
        }
        CheckSwitchContinuity(failures);
        CheckPhysicalFilterIsolation(failures);
        CheckSuspensionContinuity(failures);
        CheckInvalidFactors(failures);
        Console.WriteLine("旋转轴控制：默认一致、三轴正向/反向/禁用、切换连续、虚拟重力及暂停恢复通过");
    }

    private static void CheckDefaultParity(List<string> failures)
    {
        var physical = new MotionInput();
        var enabled = new MotionInput();
        for (int index = 1; index <= 360; index++)
        {
            float radians = MathF.Min(index, 120) * MathF.PI / 720f;
            Vector3 gravity = new(0, MathF.Sin(radians), MathF.Cos(radians));
            Vector3 acceleration = gravity + new Vector3(0.173f, -0.111f, 0.087f);
            Vector3 gyro = index < 120 ? new Vector3(15, 0, 0) : Vector3.Zero;
            physical.Update(acceleration, gyro, (ulong)index * 16_666, 100, 0, gravity);
            enabled.Update(acceleration, gyro, (ulong)index * 16_666, 100, 0, gravity, Vector3.One);
            Require(physical.GetOrientation() == enabled.GetOrientation() && physical.Accelerometer == enabled.Accelerometer && physical.Gyroscrope == enabled.Gyroscrope && physical.Rotation == enabled.Rotation,
                "默认轴控制改变了原有物理输出", failures);
        }
    }

    private static void CheckAxis(Vector3 axis, float factor, List<string> failures)
    {
        var transform = new MotionAxisTransform();
        Quaternion initial = Quaternion.CreateFromYawPitchRoll(0.31f, -0.25f, 0.19f);
        Vector3 gravity = Vector3.Transform(Vector3.UnitZ, Quaternion.Conjugate(initial));
        transform.Update(initial, initial, gravity, Vector3.One);
        Vector3 factors = Vector3.One + axis * (factor - 1);
        Quaternion previous = initial;
        Quaternion expected = initial;
        for (int index = 1; index <= 120; index++)
        {
            Quaternion current = Quaternion.Normalize(initial * Quaternion.CreateFromAxisAngle(axis, index * 0.005f));
            Vector3 currentGravity = Vector3.Transform(Vector3.UnitZ, Quaternion.Conjugate(current));
            transform.Update(previous, current, currentGravity, factors);
            expected = Quaternion.Normalize(initial * Quaternion.CreateFromAxisAngle(axis, index * 0.005f * factor));
            Require(AngleDifference(transform.Orientation, expected) < 0.001f, $"轴 {axis} 系数 {factor} 的姿态增量不符", failures);
            if (factor != 1)
            {
                // 固定世界参考下，游戏重力随虚拟姿态旋转；它不能仍追随物理姿态。
                Vector3 worldGravity = Vector3.Transform(transform.GravityForGame(currentGravity), transform.Orientation);
                Require(Vector3.Distance(worldGravity, Vector3.UnitZ) < 0.0001f, "虚拟重力与受控姿态不相容", failures);
            }
            previous = current;
        }
    }

    private static void CheckSwitchContinuity(List<string> failures)
    {
        var transform = new MotionAxisTransform();
        Quaternion physical = Quaternion.CreateFromAxisAngle(Vector3.UnitX, 0.3f);
        Vector3 gravity = Vector3.Transform(Vector3.UnitZ, Quaternion.Conjugate(physical));
        transform.Update(physical, physical, gravity, Vector3.One);
        Quaternion output = transform.Orientation;
        foreach (Vector3 factors in new[] { new Vector3(-1, 0, 1), Vector3.Zero, Vector3.One })
        {
            transform.Update(physical, physical, gravity, factors);
            Require(AngleDifference(output, transform.Orientation) < 0.0001f, "静止时切换控制导致姿态跳变", failures);
        }
        Quaternion next = Quaternion.Normalize(physical * Quaternion.CreateFromAxisAngle(Vector3.UnitY, 0.25f));
        transform.Update(physical, next, Vector3.Transform(Vector3.UnitZ, Quaternion.Conjugate(next)), new Vector3(1, -1, 1));
        output = transform.Orientation;
        transform.Update(next, next, gravity, Vector3.One);
        Require(AngleDifference(output, transform.Orientation) < 0.0001f && AngleDifference(next, transform.Orientation) > 0.1f,
            "恢复正向时丢失当前游戏姿态偏置", failures);
        transform.Update(next, next, gravity, null);
        Require(transform.Orientation == next && transform.GravityForGame(gravity) == gravity, "切换实体输入后残留手机方向控制", failures);
    }

    private static void CheckPhysicalFilterIsolation(List<string> failures)
    {
        var normal = new MotionInput();
        var reversed = new MotionInput();
        var disabled = new MotionInput();
        float movingPitch = 0;
        float finalPitch = 0;
        for (int index = 1; index <= 300; index++)
        {
            float degrees = index < 30 ? 0 : MathF.Min(30, (index - 30) * 0.5f);
            float radians = degrees * MathF.PI / 180;
            Vector3 gravity = new(0, MathF.Sin(radians), MathF.Cos(radians));
            Vector3 gyro = index >= 30 && index < 90 ? new Vector3(30, 0, 0) : Vector3.Zero;
            Vector3 translation = new(0.25f, -0.15f, 0.1f);
            ulong time = (ulong)index * 16_666;
            normal.Update(gravity + translation, gyro, time, 100, 0, gravity, Vector3.One);
            reversed.Update(gravity + translation, gyro, time, 100, 0, gravity, new Vector3(-1, 1, 1));
            disabled.Update(gravity + translation, gyro, time, 100, 0, gravity, Vector3.Zero);
            Require(disabled.GetOrientation() == Matrix4x4.Identity && disabled.Gyroscrope == Vector3.Zero && disabled.Rotation == Vector3.Zero,
                "禁用所有旋转轴后仍输出姿态运动", failures);
            if (index > 1)
            {
                Require(Vector3.Distance(-disabled.Accelerometer - translation, Vector3.UnitZ) < 0.0001f, "禁用轴后游戏重力仍追随真实倾斜", failures);
            }
            finalPitch = Pitch(reversed.GetOrientation());
            if (index == 89) movingPitch = finalPitch;
        }
        Require(movingPitch < -20 && finalPitch < -28 && finalPitch > -32, "反向俯仰停止后被重力拉回原方向", failures);
        Require(MathF.Abs(reversed.Rotation.X + normal.Rotation.X) < 0.001f, "反向角度积分方向错误", failures);
    }

    private static void CheckSuspensionContinuity(List<string> failures)
    {
        foreach (bool pollsWhileSuspended in new[] { false, true })
        {
            var motion = new MotionInput();
            Vector3 gravity = Vector3.UnitZ;
            Vector3 translation = new(0.2f, -0.3f, 0.1f);
            Vector3 factors = new(1, 1, -1);
            for (ulong index = 1; index <= 100; index++)
            {
                motion.Update(gravity + translation, new Vector3(0, 0, 30), index * 10_000, 100, 0, gravity, factors);
            }

            Matrix4x4 orientationBefore = motion.GetOrientation();
            Vector3 rotationBefore = motion.Rotation;
            Vector3 gameGravityBefore = -motion.Accelerometer - translation;
            if (pollsWhileSuspended)
            {
                for (ulong index = 1; index <= 10; index++)
                {
                    motion.Update(gravity, Vector3.Zero, 1_000_000 + index * 1_000_000, 100, 0, gravity, factors, 1, true);
                    Require(motion.GetOrientation() == orientationBefore && motion.Rotation == rotationBefore,
                        "暂停轮询改变了当前游戏姿态", failures);
                    Require(motion.Gyroscrope == Vector3.Zero && Vector3.Distance(motion.Accelerometer, -gameGravityBefore) < 0.0001f,
                        "暂停后仍保留瞬时平移或角速度", failures);
                }
            }

            // 用两分钟间隔检测暂停期间没有轮询、恢复采样已覆盖暂停标记的情况。
            motion.Update(gravity + translation, new Vector3(0, 0, 60), 121_000_000, 100, 0, gravity, factors, 1);
            Require(motion.GetOrientation() == orientationBefore && motion.Rotation == rotationBefore && motion.Gyroscrope == Vector3.Zero,
                "恢复首帧积分了暂停时间或丢失受控姿态", failures);
            motion.Update(gravity + translation, new Vector3(0, 0, 60), 121_010_000, 100, 0, gravity, factors, 1);
            Require(MathF.Abs(motion.Rotation.Z - rotationBefore.Z + 0.6f) < 0.0001f && motion.Gyroscrope.Z == -60,
                "恢复后的有效样本没有继续应用方向控制", failures);
        }
    }

    private static void CheckInvalidFactors(List<string> failures)
    {
        try
        {
            new MotionInput().Update(Vector3.UnitZ, Vector3.Zero, 1, 100, 0, Vector3.UnitZ, new Vector3(float.NaN, 1, 1));
            failures.Add("非有限控制系数未明确拒绝");
        }
        catch (ArgumentOutOfRangeException) { }
    }

    private static float Pitch(Matrix4x4 matrix) => MathF.Atan2(-matrix.M32, matrix.M33) * 180 / MathF.PI;

    private static float AngleDifference(Quaternion a, Quaternion b)
    {
        Quaternion delta = Quaternion.Normalize(Quaternion.Conjugate(a) * b);
        return 2 * MathF.Atan2(new Vector3(delta.X, delta.Y, delta.Z).Length(), MathF.Abs(delta.W));
    }

    private static void Require(bool condition, string error, List<string> failures)
    {
        if (!condition && !failures.Contains(error)) failures.Add(error);
    }
}
