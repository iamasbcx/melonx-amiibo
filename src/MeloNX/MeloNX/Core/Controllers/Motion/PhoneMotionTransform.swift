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
        let rotationFactors: SIMD3<Float>
    }

    /// 输入为 CoreMotion 的重力、用户加速度（单位 g）和角速度（rad/s）。
    /// 输出为 GamepadDriver 坐标，加速度/重力单位 g，角速度单位 deg/s；调用方原子提交整帧。
    /// 平移在屏幕坐标下应用开关；旋转系数作为元数据交给核心，不改写物理角速度。
    /// 独立重力和物理角速度供姿态滤波，避免反向控制与重力反馈互相抵消。
    /// 本函数无状态、可并发调用；CoreMotion 已补偿角速度，不将慢速瞄准学习成零偏。
    static func driverSample(
        gravity: SIMD3<Float>,
        userAcceleration: SIMD3<Float>,
        rotationRate: SIMD3<Float>,
        orientation: Orientation,
        controls: PhoneMotionControls = .standard
    ) -> Sample {
        // 姿态融合的重力与角速度必须使用同一右手旋转（行列式 +1）。
        // 游戏平移的方向校正不能施加到重力，否则 Mahony 停止后仍会向反方向校正。
        let mappedGravity = screenVector(gravity, orientation: orientation)
        let translation = screenVector(userAcceleration, orientation: orientation)
        // 平移开关不能施加到包含倾斜信息的重力；0 禁用、-1 反向、+1 原方向。
        let accel = mappedGravity + translation * controls.translationFactors
        let gyro = screenVector(rotationRate, orientation: orientation) * (180 / Float.pi)

        // NpadController 会执行 P(x,y,z)=(x,-z,y)，此处应用 P 的逆变换。
        // 重力、角速度及校正后的游戏加速度统一转换到 driver 坐标。
        return Sample(
            accelerometer: SIMD3(accel.x, accel.z, -accel.y),
            gyroscope: SIMD3(gyro.x, gyro.z, -gyro.y),
            gravity: SIMD3(mappedGravity.x, mappedGravity.z, -mappedGravity.y),
            rotationFactors: controls.rotationFactors
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
