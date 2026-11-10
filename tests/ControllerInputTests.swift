// 与应用编译同一份运动映射、倍数解析代码，验证方向契约并生成给生产 C# 滤波器的回放数据。
import Foundation
import simd

@main
struct ControllerInputTests {
    typealias Orientation = PhoneMotionTransform.Orientation

    struct Sample: Encodable {
        let acceleration: [Float]
        let gyroscope: [Float]
        let timestamp: UInt64
    }

    struct Trace: Encodable {
        let name: String
        let samples: [Sample]
    }

    static func main() throws {
        checkSensitivity()
        let traces = Orientation.allCases.map { checkMotion($0) }
        if CommandLine.arguments.count > 1 {
            let data = try JSONEncoder().encode(traces)
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        print("ControllerInputTests: sensitivity bounds and four motion orientations passed")
    }

    static func checkSensitivity() {
        typealias Config = TouchLookSensitivityConfiguration
        for (text, expected) in [("1", 1.0), (" 2.5 ", 2.5), (".5", 0.5), ("2,5", 2.5), ("0.25", 0.25), ("10", 10.0)] {
            precondition(Config.parseMultiplier(text) == .success(expected), "Invalid parsing: \(text)")
        }
        for text in ["", " \n"] {
            precondition(Config.parseMultiplier(text) == .failure(.empty))
        }
        for text in ["nan", "inf", "1e309", "2x", "1.2.3", "1,2,3", "2..", "--1"] {
            precondition(Config.parseMultiplier(text) == .failure(.invalidNumber), "Accepted invalid input: \(text)")
        }
        for text in ["0", "-1", "0.249", "10.01"] {
            precondition(Config.parseMultiplier(text) == .failure(.outOfRange), "Accepted out-of-range input: \(text)")
        }
        precondition(Config.normalizedMultiplier(.nan) == 1)
        precondition(Config.normalizedMultiplier(.infinity) == 1)
        precondition(Config.normalizedMultiplier(-1) == 0.25)
        precondition(Config.normalizedMultiplier(100) == 10)
        precondition(abs(Config.coefficient(for: 1) - 0.012) < 1e-12)
        precondition(abs(Config.coefficient(for: 2.5) - 0.030) < 1e-12)
        // 10 倍必须突破旧 0.05 上限，否则大数值仅改变显示而不改变输入。
        precondition(abs(Config.coefficient(for: 10) - 0.120) < 1e-12)
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
        let basis = PhoneMotionTransform.driverSample(acceleration: SIMD3(1, 2, 3), rotationRate: SIMD3(1, 2, 3), orientation: orientation)
        expect(npad(basis.accelerometer), expectedBasis)
        expect(npad(basis.gyroscope) * (Float.pi / 180), expectedBasis)
        let yaw = PhoneMotionTransform.driverSample(acceleration: SIMD3(0, 0, -1), rotationRate: yawAxis, orientation: orientation)
        expect(npad(yaw.gyroscope) * (Float.pi / 180), SIMD3(0, -1, 0))

        // 缓慢瞄准仍是运动，不能在短时间内学习为静止零偏。
        for _ in 0..<120 {
            let slow = PhoneMotionTransform.driverSample(acceleration: SIMD3(0, 0, -1), rotationRate: pitchAxis * (2 * Float.pi / 180), orientation: orientation)
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
                acceleration: gravity,
                rotationRate: pitchAxis * (rate * Float.pi / 180),
                orientation: orientation
            )
            let accel = npad(input.accelerometer)
            let gyro = npad(input.gyroscope)
            expect(accel, SIMD3(0, sin(theta), cos(theta)))
            expect(gyro, SIMD3(rate, 0, 0))
            samples.append(Sample(acceleration: [accel.x, accel.y, accel.z], gyroscope: [gyro.x, gyro.y, gyro.z], timestamp: UInt64(index + 1) * 16_666))
        }
        print("PhoneMotionTransform: \(orientation.rawValue) passed")
        return Trace(name: orientation.rawValue, samples: samples)
    }

    /// 重现生产 NpadController 的固定变换，防止 Swift 端遗漏或重复换轴。
    static func npad(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value.x, -value.z, value.y)
    }

    static func expect(_ value: SIMD3<Float>, _ expected: SIMD3<Float>) {
        precondition(simd_length(value - expected) < 1e-4, "Vector mismatch: \(value), expected \(expected)")
    }
}
