// 手机六轴控制契约：平移在 Swift 适配层处理，旋转系数交给核心控制游戏输出。
// 纯值类型不持有设置或线程状态，允许随每帧传感器采样跨队列传递。
import Foundation

nonisolated enum PhoneMotionAxis: String, CaseIterable, Identifiable {
    case translationX = "TranslationX"
    case translationY = "TranslationY"
    case translationZ = "TranslationZ"
    case rotationY = "RotationY"
    case rotationX = "RotationX"
    case rotationZ = "RotationZ"

    var id: String { rawValue }
    var enabledKey: String { "PhoneMotion.\(rawValue).Enabled" }
    var invertedKey: String { "PhoneMotion.\(rawValue).Inverted" }
    var defaultInverted: Bool { self == .translationX }
    var title: String {
        switch self {
        case .translationX: return "Move Left / Right"
        case .translationY: return "Move Up / Down"
        case .translationZ: return "Move Forward / Backward"
        case .rotationY: return "Turn Left / Right"
        case .rotationX: return "Pitch Up / Down"
        case .rotationZ: return "Tilt Left / Right"
        }
    }
}

nonisolated struct PhoneMotionControls: Sendable, Equatable {
    // 轴顺序均为当前屏幕的 X/Y/Z；仅接受由开关生成的 -1、0、1。
    let translationFactors: SIMD3<Float>
    let rotationFactors: SIMD3<Float>

    static let standard = PhoneMotionControls(
        translationFactors: SIMD3(-1, 1, 1),
        rotationFactors: SIMD3(repeating: 1)
    )

    static func factor(enabled: Bool, inverted: Bool) -> Float {
        enabled ? (inverted ? -1 : 1) : 0
    }
}
