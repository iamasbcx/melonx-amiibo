using System.Numerics;
using System.Text.Json;
using Ryujinx.Input;

// 运动输入回归测试：直接链接生产 MotionInput/MotionSensorFilter，验证加速度与陀螺仪坐标契约。
// 命令行可传入 Swift 侧导出的 JSON；不传参数时运行确定性的合成轨迹。
const float Sensitivity = 100f;
const float Deadzone = 0f;
const ulong SamplePeriodUs = 16_666;

var failures = new List<string>();
RunSyntheticRegression(failures);
RunTranslationRegression(failures);

if (args.Length > 0)
{
    foreach (string path in args)
    {
        RunJsonRegression(path, failures);
    }
}
else if (Environment.GetEnvironmentVariable("MOTION_TRACE_JSON") is { Length: > 0 } jsonPath)
{
    RunJsonRegression(jsonPath, failures);
}

if (failures.Count > 0)
{
    Console.Error.WriteLine("运动回归失败：");
    foreach (string failure in failures)
    {
        Console.Error.WriteLine($"- {failure}");
    }
    return 1;
}

Console.WriteLine("运动回归通过；实际 Swift 映射是否通过以以上 Swift 轨迹输出为准。");
return 0;

static void RunSyntheticRegression(List<string> failures)
{
    // 目标轨迹：静止 0.5 秒，绕 Switch X 轴正向转到 30 度，再静止 3 秒。
    // 静止重力方向固定为 (0, 0, 1)，旋转阶段的加速度与角速度使用同一右手坐标系。
    List<Sample> correct = CreatePitchTrace(invertAcceleration: false);
    List<Sample> wrong = CreatePitchTrace(invertAcceleration: true);

    TraceResult result = Replay(correct);
    float movingPitch = result.MovingEndPitch;
    float stablePitch = result.FinalPitch;
    Console.WriteLine($"合成正确坐标：运动末端 pitch={movingPitch:F2}°，静止末端 pitch={stablePitch:F2}°");
    ValidatePitchTrace("合成正确坐标", result, failures);

    TraceResult wrongResult = Replay(wrong);
    float wrongStablePitch = wrongResult.FinalPitch;
    Console.WriteLine($"合成错误加速度对照：运动末端 pitch={wrongResult.MovingEndPitch:F2}°，静止末端 pitch={wrongStablePitch:F2}°（应显著反向）");
    if (!wrongResult.AllFinite || wrongResult.MovingEndPitch < 1f || wrongStablePitch > -15f)
    {
        failures.Add($"错误加速度对照未重现停后反向：moving={wrongResult.MovingEndPitch:F2}°, stable={wrongStablePitch:F2}°");
    }

    TraceResult zero = Replay(CreateStaticTrace());
    float zeroPitch = zero.FinalPitch;
    Console.WriteLine($"零角速度静止：pitch={zeroPitch:F2}°");
    if (!zero.AllFinite || MathF.Abs(zeroPitch) > 0.01f || zero.IntegratedRotation != Vector3.Zero || !zero.LastGyroscopeIsZero)
    {
        failures.Add($"零角速度静止姿态漂移：pitch={zeroPitch:F2}°");
    }

    // 微小俯仰也必须保持，不通过添加死区掩盖错误；0.5°/s 持续一秒应积分为约 0.5°。
    TraceResult small = Replay(CreatePitchTrace(invertAcceleration: false, targetAngle: 0.5f));
    Console.WriteLine($"慢速俯仰：积分={small.IntegratedRotation.X:F4}°，静止末端 pitch={small.FinalPitch:F4}°");
    if (!small.AllFinite || MathF.Abs(small.IntegratedRotation.X - 0.5f) > 0.01f || small.FinalPitch < 0.45f || small.FinalPitch > 0.55f)
    {
        failures.Add("慢速俯仰积分/姿态超出 0.5° 基准，可能错误吞掉低角速度或反向修正");
    }
}

static void RunJsonRegression(string path, List<string> failures)
{
    try
    {
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("JSON 根元素必须是数组");
        }

        int count = 0;
        foreach (JsonElement traceElement in root.EnumerateArray())
        {
            string name = traceElement.GetProperty("name").GetString() ?? throw new InvalidDataException("缺少轨迹名称");
            string kind = traceElement.GetProperty("kind").GetString() ?? throw new InvalidDataException("缺少轨迹类型");
            List<Sample> samples = ParseSamples(traceElement.GetProperty("samples"));
            if (samples.Count < 3)
            {
                throw new InvalidDataException($"{name} 样本数量不足");
            }

            TraceResult result = Replay(samples);
            Console.WriteLine($"Swift 轨迹 {name}：samples={samples.Count}，运动末端 pitch={result.MovingEndPitch:F2}°，静止末端 pitch={result.FinalPitch:F2}°，积分={result.IntegratedRotation.X:F2}°");
            if (kind == "pitch")
            {
                ValidatePitchTrace($"Swift 轨迹 {name}", result, failures);
            }
            else if (kind == "translation")
            {
                ValidateTranslationTrace($"Swift 轨迹 {name}", result, failures);
            }
            else
            {
                throw new InvalidDataException($"未知轨迹类型：{kind}");
            }
            count++;
        }

        if (count == 0)
        {
            throw new InvalidDataException("JSON 未包含轨迹");
        }
    }
    catch (Exception error)
    {
        failures.Add($"读取运动 JSON {path} 失败：{error.Message}");
    }
}

static List<Sample> ParseSamples(JsonElement samplesElement)
{
    var samples = new List<Sample>();
    foreach (JsonElement sample in samplesElement.EnumerateArray())
    {
        samples.Add(new Sample(
            ReadVector(sample.GetProperty("acceleration")),
            ReadVector(sample.GetProperty("gyroscope")),
            sample.GetProperty("timestamp").GetUInt64(),
            ReadVector(sample.GetProperty("gravity"))));
    }
    return samples;
}

static Vector3 ReadVector(JsonElement element)
{
    float[] values = element.EnumerateArray().Select(value => value.GetSingle()).ToArray();
    if (values.Length != 3)
    {
        throw new InvalidDataException("向量必须包含 3 个数值");
    }
    return new Vector3(values[0], values[1], values[2]);
}

static List<Sample> CreatePitchTrace(bool invertAcceleration, float targetAngle = 30f)
{
    var samples = new List<Sample>();
    const int staticSamples = 30;
    const int movingSamples = 60;
    const int finalStaticSamples = 180;

    for (int index = 0; index < staticSamples + movingSamples + finalStaticSamples; index++)
    {
        float angle = index < staticSamples
            ? 0f
            : MathF.Min(targetAngle, (index - staticSamples) * targetAngle / movingSamples);
        float radians = angle * MathF.PI / 180f;
        float rate = index >= staticSamples && index < staticSamples + movingSamples ? targetAngle : 0f;
        Vector3 acceleration = new(0f, MathF.Sin(radians), MathF.Cos(radians));
        if (invertAcceleration)
        {
            acceleration = new Vector3(-acceleration.X, -acceleration.Y, acceleration.Z);
        }
        samples.Add(new Sample(acceleration, new Vector3(rate, 0f, 0f), (ulong)(index + 1) * SamplePeriodUs));
    }
    return samples;
}

static List<Sample> CreateStaticTrace()
{
    return Enumerable.Range(1, 180)
        .Select(index => new Sample(new Vector3(0f, 0f, 1f), Vector3.Zero, (ulong)index * SamplePeriodUs))
        .ToList();
}

static TraceResult Replay(IReadOnlyList<Sample> samples)
{
    var input = new MotionInput();
    var baseline = new MotionInput();
    int lastMovingIndex = -1;
    for (int index = 0; index < samples.Count; index++)
    {
        if (samples[index].Gyroscope != Vector3.Zero)
        {
            lastMovingIndex = index;
        }
    }

    bool allFinite = true;
    float movingEndPitch = 0f;
    float minStablePitch = float.PositiveInfinity;
    ulong lastTimestamp = 0;
    float stableDuration = 0f;
    float maxOrientationDegrees = 0f;
    float maxBaselineDeviation = 0f;
    bool totalAccelerationPreserved = true;
    for (int index = 0; index < samples.Count; index++)
    {
        Sample sample = samples[index];
        if (sample.Timestamp == 0 || sample.Timestamp <= lastTimestamp || !VectorFinite(sample.Acceleration) || !VectorFinite(sample.Gyroscope))
        {
            throw new InvalidDataException($"样本 {index} 包含非法时间戳或非有限向量");
        }
        if (sample.Acceleration.LengthSquared() < 0.01f)
        {
            throw new InvalidDataException($"样本 {index} 缺少有效重力方向");
        }
        if (sample.Gravity is Vector3 gravity && (!VectorFinite(gravity) || gravity.LengthSquared() < 0.01f))
        {
            throw new InvalidDataException($"样本 {index} 包含非法独立重力");
        }
        input.Update(sample.Acceleration, sample.Gyroscope, sample.Timestamp, (int)Sensitivity, Deadzone, sample.Gravity);
        // 同一姿态和角速度、没有平移加速度的对照。允许竖直/倾斜持握的初始重力对齐过程。
        baseline.Update(sample.Gravity ?? sample.Acceleration, sample.Gyroscope, sample.Timestamp, (int)Sensitivity, Deadzone, sample.Gravity);
        Matrix4x4 orientation = input.GetOrientation();
        float pitch = PitchDegrees(orientation);
        allFinite &= MatrixFinite(orientation) && float.IsFinite(pitch) && VectorFinite(input.Rotation);
        maxOrientationDegrees = MathF.Max(maxOrientationDegrees, OrientationDifference(orientation, Matrix4x4.Identity));
        maxBaselineDeviation = MathF.Max(maxBaselineDeviation, OrientationDifference(orientation, baseline.GetOrientation()));
        if (index > 0)
        {
            totalAccelerationPreserved &= input.Accelerometer == -sample.Acceleration;
        }
        if (index == lastMovingIndex)
        {
            movingEndPitch = pitch;
        }
        if (index > lastMovingIndex)
        {
            minStablePitch = MathF.Min(minStablePitch, pitch);
            stableDuration += lastTimestamp == 0 ? 0f : (sample.Timestamp - lastTimestamp) / 1_000_000f;
        }
        lastTimestamp = sample.Timestamp;
    }
    return new TraceResult(
        movingEndPitch,
        PitchDegrees(input.GetOrientation()),
        minStablePitch,
        stableDuration,
        input.Rotation,
        input.Gyroscrope == Vector3.Zero,
        allFinite,
        maxOrientationDegrees,
        maxBaselineDeviation,
        totalAccelerationPreserved);
}

static void RunTranslationRegression(List<string> failures)
{
    foreach (float direction in new[] { -1f, 1f })
    {
        List<Sample> samples = Enumerable.Range(1, 240).Select(index =>
        {
            float acceleration = index is >= 30 and < 90 ? direction * 0.6f : index is >= 90 and < 150 ? -direction * 0.6f : 0f;
            return new Sample(new Vector3(acceleration, 0f, 1f), Vector3.Zero, (ulong)index * SamplePeriodUs, Vector3.UnitZ);
        }).ToList();
        TraceResult corrected = Replay(samples);
        TraceResult wrong = Replay(samples.Select(sample => sample with { Gravity = null }).ToList());
        Console.WriteLine($"纯平移 {direction:+0;-0}：原总加速度融合最大假转角={wrong.MaxOrientationDegrees:F2}°，分离重力后相对基线偏差={corrected.MaxBaselineDeviation:F4}°");
        ValidateTranslationTrace("合成纯平移", corrected, failures);
        if (wrong.MaxOrientationDegrees < 5f)
        {
            failures.Add("原总加速度融合对照未复现平移产生假转向");
        }
    }

    List<Sample> tiltAndTranslation = CreatePitchTrace(invertAcceleration: false).Select((sample, index) => sample with
    {
        Gravity = sample.Acceleration,
        Acceleration = sample.Acceleration + new Vector3(index is >= 30 and < 150 ? 0.6f : 0f, 0f, 0f),
    }).ToList();
    TraceResult tilted = Replay(tiltAndTranslation);
    ValidatePitchTrace("真实俯仰叠加平移", tilted, failures);
    if (tilted.MaxBaselineDeviation > 0.05f || !tilted.TotalAccelerationPreserved)
    {
        failures.Add("真实俯仰叠加平移改变了基线姿态，或丢失真实总加速度");
    }
    Console.WriteLine($"真实俯仰叠加平移：末端 pitch={tilted.FinalPitch:F2}°，相对基线偏差={tilted.MaxBaselineDeviation:F4}°");
}

static void ValidateTranslationTrace(string name, TraceResult result, List<string> failures)
{
    if (!result.AllFinite || result.MaxBaselineDeviation > 0.05f || result.IntegratedRotation != Vector3.Zero || !result.LastGyroscopeIsZero || !result.TotalAccelerationPreserved)
    {
        failures.Add($"{name} 平移污染姿态或运动数据：相对基线偏差={result.MaxBaselineDeviation:F4}°，rotation={result.IntegratedRotation}，总加速度保留={result.TotalAccelerationPreserved}");
    }
}

static float OrientationDifference(Matrix4x4 first, Matrix4x4 second)
{
    Quaternion left = Quaternion.Normalize(Quaternion.CreateFromRotationMatrix(first));
    Quaternion right = Quaternion.Normalize(Quaternion.CreateFromRotationMatrix(second));
    // 相同矩阵直接归零，避免 acos 在 float 单位四元数舍入误差附近放大为假角差。
    if (first == second)
    {
        return 0f;
    }
    return 2f * MathF.Acos(Math.Clamp(MathF.Abs(Quaternion.Dot(left, right)), 0f, 1f)) * 180f / MathF.PI;
}

static void ValidatePitchTrace(string name, TraceResult result, List<string> failures)
{
    // 当前生产滤波器系数是 0.45，运动末端允许有限滞后；静止三秒后应收敛到 +30°。
    // 该期望来自合成物理轨迹，不复制 Swift 的坐标变换或生产滤波算法。
    if (!result.AllFinite || result.MovingEndPitch < 20f || result.FinalPitch < 28f || result.FinalPitch > 32f)
    {
        failures.Add($"{name} 姿态未保持 +30°：moving={result.MovingEndPitch:F2}°, stable={result.FinalPitch:F2}°");
    }
    if (result.MinStablePitch < result.MovingEndPitch - 0.5f || result.StableDuration < 2.8f)
    {
        failures.Add($"{name} 停后反转或静止样本不足：最低 pitch={result.MinStablePitch:F2}°, 静止={result.StableDuration:F2}s");
    }
    if (MathF.Abs(result.IntegratedRotation.X - 30f) > 0.1f || MathF.Abs(result.IntegratedRotation.Y) > 0.1f || MathF.Abs(result.IntegratedRotation.Z) > 0.1f || !result.LastGyroscopeIsZero)
    {
        failures.Add($"{name} 角速度未归零或角度积分不符：rotation={result.IntegratedRotation}");
    }
}

static float PitchDegrees(Matrix4x4 orientation)
{
    return MathF.Atan2(-orientation.M32, orientation.M33) * 180f / MathF.PI;
}

static bool VectorFinite(Vector3 value) => float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);

static bool MatrixFinite(Matrix4x4 value) =>
    float.IsFinite(value.M11) && float.IsFinite(value.M12) && float.IsFinite(value.M13) && float.IsFinite(value.M14) &&
    float.IsFinite(value.M21) && float.IsFinite(value.M22) && float.IsFinite(value.M23) && float.IsFinite(value.M24) &&
    float.IsFinite(value.M31) && float.IsFinite(value.M32) && float.IsFinite(value.M33) && float.IsFinite(value.M34) &&
    float.IsFinite(value.M41) && float.IsFinite(value.M42) && float.IsFinite(value.M43) && float.IsFinite(value.M44);

readonly record struct Sample(Vector3 Acceleration, Vector3 Gyroscope, ulong Timestamp, Vector3? Gravity = null);

readonly record struct TraceResult(float MovingEndPitch, float FinalPitch, float MinStablePitch, float StableDuration, Vector3 IntegratedRotation, bool LastGyroscopeIsZero, bool AllFinite, float MaxOrientationDegrees, float MaxBaselineDeviation, bool TotalAccelerationPreserved);
