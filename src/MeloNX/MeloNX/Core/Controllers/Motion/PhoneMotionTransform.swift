// 手机运动输入的坐标边界：CoreMotion → 当前屏幕 → NativeGamepad。
// 纯数学模块不依赖 UIKit，供应用和独立回归测试编译同一份实现。
import Foundation
import simd

nonisolated enum PhoneMotionTransform {
    /// 与 UIInterfaceOrientation 一一对应；未知方向由调用方保留最近有效值。
    nonisolated enum Orientation: String, CaseIterable, Sendable {
        case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
    }

    nonisolated struct Sample: Sendable {
        let accelerometer: SIMD3<Float>
        let gyroscope: SIMD3<Float>
        let gravity: SIMD3<Float>
    }

    /// 输入为 CoreMotion 的重力、用户加速度（单位 g）和角速度（rad/s）。
    /// 输出为 GamepadDriver 坐标，加速度/重力单位 g，角速度单位 deg/s；调用方原子提交整帧。
    /// 总加速度供游戏读取；独立重力供姿态滤波，避免把不改变姿势的平移误判为倾斜。
    /// 本函数无状态、可并发调用；CoreMotion 已补偿角速度，不将慢速瞄准学习成零偏。
    static func driverSample(
        gravity: SIMD3<Float>,
        userAcceleration: SIMD3<Float>,
        rotationRate: SIMD3<Float>,
        orientation: Orientation
    ) -> Sample {
        // 两种传感器必须使用同一右手旋转（行列式 +1）。若只给加速度 X 取反，
        // Mahony 会把俯仰积分与重力识别为相反方向，停止后仍向反方向校正。
        let accel = screenVector(gravity + userAcceleration, orientation: orientation)
        let mappedGravity = screenVector(gravity, orientation: orientation)
        let gyro = screenVector(rotationRate, orientation: orientation) * (180 / Float.pi)

        // NpadController 会执行 P(x,y,z)=(x,-z,y)，此处应用 P 的逆变换。
        // 屏幕旋转先同时作用于两种传感器，再统一转换到 driver 坐标。
        return Sample(
            accelerometer: SIMD3(accel.x, accel.z, -accel.y),
            gyroscope: SIMD3(gyro.x, gyro.z, -gyro.y),
            gravity: SIMD3(mappedGravity.x, mappedGravity.z, -mappedGravity.y)
        )
    }

    private static func screenVector(_ value: SIMD3<Float>, orientation: Orientation) -> SIMD3<Float> {
        let base = SIMD3(value.x, -value.y, -value.z)
        switch orientation {
        case .portrait:
            return base
        case .portraitUpsideDown:
            return SIMD3(-base.x, -base.y, base.z)
        case .landscapeLeft:
            return SIMD3(-base.y, base.x, base.z)
        case .landscapeRight:
            return SIMD3(base.y, -base.x, base.z)
        }
    }
}
