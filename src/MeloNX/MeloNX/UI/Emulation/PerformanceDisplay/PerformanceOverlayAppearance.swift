import SwiftUI

/// 性能信息的作用域外观快照；调用方传入全局或当前游戏设置，未覆盖项由设置层继承全局。
/// 颜色保存为 24 位 sRGB，背景透明度独立保存为 opacity，避免颜色中的 alpha 与开关相互叠加。
struct PerformanceOverlayAppearance {
    static let fontSizeKey = "PerformanceOverlay.FontSize"
    static let textColorKey = "PerformanceOverlay.TextColorRGB"
    static let backgroundColorKey = "PerformanceOverlay.BackgroundColorRGB"
    static let backgroundEnabledKey = "PerformanceOverlay.BackgroundEnabled"
    static let backgroundOpacityKey = "PerformanceOverlay.BackgroundOpacity"

    static let fontSizeRange: ClosedRange<Double> = 8...24
    static let defaultFontSize: Double = 10
    static let defaultTextRGB = 0xFFFFFF
    static let defaultBackgroundRGB = 0x000000
    static let defaultBackgroundOpacity: Double = 0.55

    let fontSize: CGFloat
    let textColor: Color
    let backgroundColor: Color
    let backgroundEnabled: Bool
    let backgroundOpacity: Double

    init(settings: NativeSettingsManager) {
        let size = settings.setting(forKey: Self.fontSizeKey, default: Self.defaultFontSize).value
        fontSize = CGFloat(Self.normalizedFontSize(size))
        textColor = Self.color(rgb: settings.setting(forKey: Self.textColorKey, default: Self.defaultTextRGB).value,
                               fallback: Self.defaultTextRGB)
        backgroundColor = Self.color(rgb: settings.setting(forKey: Self.backgroundColorKey, default: Self.defaultBackgroundRGB).value,
                                     fallback: Self.defaultBackgroundRGB)
        backgroundEnabled = settings.setting(forKey: Self.backgroundEnabledKey, default: true).value
        let opacity = settings.setting(forKey: Self.backgroundOpacityKey, default: Self.defaultBackgroundOpacity).value
        backgroundOpacity = opacity.isFinite ? min(1, max(0, opacity)) : Self.defaultBackgroundOpacity
    }

    static func normalizedFontSize(_ size: Double) -> Double {
        size.isFinite ? min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, size)) : defaultFontSize
    }

    /// 非法持久化值只回退当前显示，不改写存储；颜色选择器转换失败由设置页明确提示。
    static func color(rgb: Int, fallback: Int) -> Color {
        let value = (0...0xFFFFFF).contains(rgb) ? rgb : fallback
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

/// 运行时和设置预览共用的单行文本。只负责呈现，不采样性能或读取设置。
/// 窄屏最多缩小到 8 点，剩余超长内容按尾部截断；背景关闭时仍保留相同内边距。
struct PerformanceOverlayLine: View {
    let text: String
    let appearance: PerformanceOverlayAppearance

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: appearance.fontSize, weight: .regular, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(appearance.textColor)
            .lineLimit(1)
            .minimumScaleFactor(8 / appearance.fontSize)
            .allowsTightening(true)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                if appearance.backgroundEnabled {
                    Capsule().fill(appearance.backgroundColor.opacity(appearance.backgroundOpacity))
                }
            }
    }
}
