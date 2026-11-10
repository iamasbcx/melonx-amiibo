// 与应用编译同一份运动映射、倍数解析代码，验证方向契约并生成给生产 C# 滤波器的回放数据。
import Foundation
import simd

@main
struct ControllerInputTests {
    typealias Orientation = PhoneMotionTransform.Orientation

    struct Sample: Encodable {
        let acceleration: [Float]
        let gyroscope: [Float]
        let gravity: [Float]
        let timestamp: UInt64
    }

    struct Trace: Encodable {
        let name: String
        let kind: String
        let samples: [Sample]
    }

    static func main() throws {
        checkSensitivity()
        let traces = Orientation.allCases.flatMap { orientation in
            [checkMotion(orientation)] + checkTranslation(orientation)
        }
        if CommandLine.arguments.count > 1 {
            let data = try JSONEncoder().encode(traces)
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        print("ControllerInputTests: 100x sensitivity, four motion orientations and translation separation passed")
    }

    static func checkSensitivity() {
        typealias Config = TouchLookSensitivityConfiguration
        for (text, expected) in [("1", 1.0), (" 2.5 ", 2.5), (".5", 0.5), ("2,5", 2.5), ("0.25", 0.25), ("10.01", 10.01), ("50", 50.0), ("100", 100.0)] {
            precondition(Config.parseMultiplier(text) == .success(expected), "Invalid parsing: \(text)")
        }
        for text in ["", " \n"] {
            precondition(Config.parseMultiplier(text) == .failure(.empty))
        }
        for text in ["nan", "inf", "1e309", "2x", "1.2.3", "1,2,3", "2..", "--1"] {
            precondition(Config.parseMultiplier(text) == .failure(.invalidNumber), "Accepted invalid input: \(text)")
        }
        for text in ["0", "-1", "0.249", "100.01", "101"] {
            precondition(Config.parseMultiplier(text) == .failure(.outOfRange), "Accepted out-of-range input: \(text)")
        }
        precondition(Config.normalizedMultiplier(.nan) == 1)
        precondition(Config.normalizedMultiplier(.infinity) == 1)
        precondition(Config.normalizedMultiplier(-1) == 0.25)
        precondition(Config.normalizedMultiplier(100) == 100)
        precondition(Config.normalizedMultiplier(101) == 100)
        precondition(abs(Config.coefficient(for: 1) - 0.012) < 1e-12)
        precondition(abs(Config.coefficient(for: 2.5) - 0.030) < 1e-12)
        // 大倍率必须完整进入运行态系数，不能被旧的 10 倍或 0.05 系数上限截断。
        precondition(abs(Config.coefficient(for: 10) - 0.120) < 1e-12)
        precondition(abs(Config.coefficient(for: 100) - 1.200) < 1e-12)
    }

    static func checkMotion(_ orientation: Orientation) -> Trace {
        let pitchAxis: SIMD3<Float>
        let yawAxis: SIMD3<Float>
        let expectedBasis: SIMD3<Float>
        switch orientation {
        case .portrait:
            pitchAxis = SIMD3(1, 0, 0)
            yawAxis = SIMD3(0, 1, 0)
            expectedBasis = SIMD3(1, -2, -3)
        case .portraitUpsideDown:
            pitchAxis = SIMD3(-1, 0, 0)
            yawAxis = SIMD3(0, -1, 0)
            expectedBasis = SIMD3(-1, 2, -3)
        case .landscapeLeft:
            pitchAxis = SIMD3(0, 1, 0)
            yawAxis = SIMD3(-1, 0, 0)
            expectedBasis = SIMD3(2, 1, -3)
        case .landscapeRight:
            pitchAxis = SIMD3(0, -1, 0)
            yawAxis = SIMD3(1, 0, 0)
            expectedBasis = SIMD3(-2, -1, -3)
        }
        let basis = PhoneMotionTransform.driverSample(gravity: SIMD3(1, 2, 3), userAcceleration: .zero, rotationRate: SIMD3(1, 2, 3), orientation: orientation)
        expect(npad(basis.accelerometer), expectedBasis)
        expect(npad(basis.gravity), expectedBasis)
        expect(npad(basis.gyroscope) * (Float.pi / 180), expectedBasis)
        let yaw = PhoneMotionTransform.driverSample(gravity: SIMD3(0, 0, -1), userAcceleration: .zero, rotationRate: yawAxis, orientation: orientation)
        expect(npad(yaw.gyroscope) * (Float.pi / 180), SIMD3(0, -1, 0))
        let roll = PhoneMotionTransform.driverSample(gravity: SIMD3(0, 0, -1), userAcceleration: .zero, rotationRate: SIMD3(0, 0, 1), orientation: orientation)
        expect(npad(roll.gyroscope) * (Float.pi / 180), SIMD3(0, 0, -1))

        // 缓慢瞄准仍是运动，不能在短时间内学习为静止零偏。
        for _ in 0..<120 {
            let slow = PhoneMotionTransform.driverSample(gravity: SIMD3(0, 0, -1), userAcceleration: .zero, rotationRate: pitchAxis * (2 * Float.pi / 180), orientation: orientation)
            expect(npad(slow.gyroscope), SIMD3(2, 0, 0))
        }

        var samples: [Sample] = []
        for index in 0..<270 {
            let degrees = min(30, max(0, Float(index - 30) * 0.5))
            let theta = degrees * Float.pi / 180
            // 手机相对世界转动 +theta，机体测得的重力使用逆旋转 -theta。
            let initialGravity = SIMD3<Float>(0, 0, -1)
            let gravity = initialGravity * cos(theta) - simd_cross(pitchAxis, initialGravity) * sin(theta)
            let rate: Float = (30..<90).contains(index) ? 30 : 0
            let input = PhoneMotionTransform.driverSample(
                gravity: gravity,
                userAcceleration: .zero,
                rotationRate: pitchAxis * (rate * Float.pi / 180),
                orientation: orientation
            )
            let accel = npad(input.accelerometer)
            let gyro = npad(input.gyroscope)
            expect(accel, SIMD3(0, sin(theta), cos(theta)))
            expect(gyro, SIMD3(rate, 0, 0))
            samples.append(encoded(input, index: index))
        }
        print("PhoneMotionTransform: \(orientation.rawValue) passed")
        return Trace(name: orientation.rawValue, kind: "pitch", samples: samples)
    }

    /// 平移没有角速度；即使手持姿态不同，重力也不能跟随用户加速度改变。
    /// C# 回放将每帧与同姿态、没有平移的基线比较，允许滤波器本身的初始化收敛。
    static func checkTranslation(_ orientation: Orientation) -> [Trace] {
        let diagonal = Float(0.5).squareRoot()
        // 竖持时的世界重力始终朝当前屏幕下方；横屏后它沿手机硬件 X 轴。
        let down: SIMD3<Float>
        switch orientation {
        case .portrait: down = SIMD3(0, -1, 0)
        case .portraitUpsideDown: down = SIMD3(0, 1, 0)
        case .landscapeLeft: down = SIMD3(1, 0, 0)
        case .landscapeRight: down = SIMD3(-1, 0, 0)
        }
        let poses: [(String, SIMD3<Float>)] = [
            ("flat", SIMD3(0, 0, -1)),
            ("upright", down),
            ("inclined", down * diagonal + SIMD3(0, 0, -diagonal))
        ]
        return poses.map { name, gravity in
            let stationary = PhoneMotionTransform.driverSample(gravity: gravity, userAcceleration: .zero, rotationRate: .zero, orientation: orientation)
            var samples: [Sample] = []
            for index in 0..<360 {
                // 同一段平移包含加速、匀速、减速；结束后保持三秒，检查残余反向校正。
                let horizontal: Float = (60..<90).contains(index) ? 0.4 : ((120..<150).contains(index) ? -0.4 : 0)
                let translation: SIMD3<Float>
                switch orientation {
                case .portrait: translation = SIMD3(horizontal, 0, 0)
                case .portraitUpsideDown: translation = SIMD3(-horizontal, 0, 0)
                case .landscapeLeft: translation = SIMD3(0, horizontal, 0)
                case .landscapeRight: translation = SIMD3(0, -horizontal, 0)
                }
                let input = PhoneMotionTransform.driverSample(gravity: gravity, userAcceleration: translation, rotationRate: .zero, orientation: orientation)
                expect(input.gravity, stationary.gravity)
                expect(input.gyroscope, .zero)
                expect(npad(input.accelerometer - stationary.accelerometer), SIMD3(horizontal, 0, 0))
                samples.append(encoded(input, index: index))
            }
            return Trace(name: "\(orientation.rawValue)-\(name)", kind: "translation", samples: samples)
        }
    }

    static func encoded(_ sample: PhoneMotionTransform.Sample, index: Int) -> Sample {
        let accel = npad(sample.accelerometer)
        let gyro = npad(sample.gyroscope)
        let gravity = npad(sample.gravity)
        return Sample(acceleration: [accel.x, accel.y, accel.z], gyroscope: [gyro.x, gyro.y, gyro.z], gravity: [gravity.x, gravity.y, gravity.z], timestamp: UInt64(index + 1) * 16_666)
    }

    /// 重现生产 NpadController 的固定变换，防止 Swift 端遗漏或重复换轴。
    static func npad(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value.x, -value.z, value.y)
    }

    static func expect(_ value: SIMD3<Float>, _ expected: SIMD3<Float>) {
        precondition(simd_length(value - expected) < 1e-4, "Vector mismatch: \(value), expected \(expected)")
    }
}
