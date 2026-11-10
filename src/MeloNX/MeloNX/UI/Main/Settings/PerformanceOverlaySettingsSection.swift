import SwiftUI
import UIKit
import CoreGraphics

/// 性能信息设置；宿主传入全局或当前游戏实例，未覆盖项继承全局默认值。
/// 预览使用固定示例数值，外观与显示开关立即写入当前作用域并刷新同一呈现组件。
struct PerformanceOverlaySettingsSection: View {
    @ObservedObject var settings: NativeSettingsManager
    @State private var colorError: String?

    private var appearance: PerformanceOverlayAppearance { PerformanceOverlayAppearance(settings: settings) }
    private var isCurrentGame: Bool { settings.pullOriginal && !settings.titleId.isEmpty }

    var body: some View {
        Section {
            NativeToggleRow("Performance Overlay", icon: "speedometer",
                            isOn: settings.performacehud(false).projectedValue)

            if settings.performacehud(false).bool {
                preview
                displayControls
                appearanceControls

                NativeToggleRow("Move Overlay below Screen", icon: "arrow.uturn.down",
                                isOn: settings.overlayBelowScreen(true).projectedValue,
                                info: "When device is in portrait, the overlay will be moved below the game screen.")
            }

            Picker("Overlay Position", selection: settings.performancePosition(PerformanceOverlayPosition.topRight).projectedValue) {
                ForEach(PerformanceOverlayPosition.allCases, id: \.self) { position in
                    Text(position.displayValue).tag(position)
                }
            }
        } header: {
            Text("Performance Overlay")
        } footer: {
            Text(isCurrentGame
                 ? "当前游戏设置：未修改的项目继承全局默认值。性能信息始终显示为紧凑单行，窄屏会适度缩小文字。"
                 : "全局默认设置：用于没有单独覆盖对应项目的游戏。性能信息始终显示为紧凑单行，窄屏会适度缩小文字。")
        }
        .alert("无法保存颜色", isPresented: Binding(
            get: { colorError != nil },
            set: { if !$0 { colorError = nil } }
        )) {
            Button("好", role: .cancel) { colorError = nil }
        } message: {
            Text(colorError ?? "无法读取所选颜色，请重新选择。")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时外观预览")
                .font(.subheadline)
            PerformanceOverlayLine(text: previewText, appearance: appearance)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .padding(.horizontal, 8)
                // 明暗渐变用于观察文字对比和透明度，不模拟真实游戏画面。
                .background(LinearGradient(colors: [Color(white: 0.65), Color(white: 0.2)],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 8))
            Text("这里使用示例数据，仅预览样式和显示项目。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var displayControls: some View {
        NativeToggleRow("Show Battery Percentage", icon: "battery.100percent.bolt",
                        isOn: settings.showBatteryPercentage(false).projectedValue)
        NativeToggleRow("Show Frame Time", icon: "clock.arrow.2.circlepath",
                        isOn: settings.performanceFrameTime(true).projectedValue)
        NativeToggleRow("Show Memory Usage", icon: "memorychip",
                        isOn: settings.performanceRam(true).projectedValue)
        NativeToggleRow("Show FIFO", icon: "arrow.left.arrow.right",
                        isOn: settings.performanceFIFO(false).projectedValue)
    }

    @ViewBuilder
    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("文字大小")
                Spacer()
                Text("\(Int(appearance.fontSize)) 点")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: fontSizeBinding, in: PerformanceOverlayAppearance.fontSizeRange, step: 1)
                .accessibilityLabel("文字大小")
        }

        ColorPicker("文字颜色", selection: colorBinding(key: PerformanceOverlayAppearance.textColorKey,
                                                       defaultRGB: PerformanceOverlayAppearance.defaultTextRGB),
                    supportsOpacity: false)

        Toggle("显示背景", isOn: settings.setting(forKey: PerformanceOverlayAppearance.backgroundEnabledKey, default: true).projectedValue)

        if appearance.backgroundEnabled {
            ColorPicker("背景颜色", selection: colorBinding(key: PerformanceOverlayAppearance.backgroundColorKey,
                                                           defaultRGB: PerformanceOverlayAppearance.defaultBackgroundRGB),
                        supportsOpacity: false)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Text("\(Int(((1 - appearance.backgroundOpacity) * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: transparencyBinding, in: 0...100, step: 1)
                    .accessibilityLabel("背景透明度")
                Text("0% 为不透明，100% 为完全透明。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewText: String {
        var parts = ["FPS 60.0"]
        if settings.performanceFrameTime(true).bool { parts.append("16.7ms") }
        if settings.performanceRam(true).bool { parts.append("RAM 2.5GB"); parts.append("扩展 1.0GB") }
        if settings.performanceFIFO(false).bool { parts.append("FIFO 12.5%") }
        if settings.showBatteryPercentage(false).bool { parts.append("电量 80%") }
        return parts.joined(separator: " · ")
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(appearance.fontSize) },
            set: { settings.setting(forKey: PerformanceOverlayAppearance.fontSizeKey,
                                    default: PerformanceOverlayAppearance.defaultFontSize).value = PerformanceOverlayAppearance.normalizedFontSize($0) }
        )
    }

    /// 界面显示“越大越透明”的百分比，存储和渲染统一使用“越大越不透明”的 opacity。
    private var transparencyBinding: Binding<Double> {
        Binding(
            get: { (1 - appearance.backgroundOpacity) * 100 },
            set: { settings.setting(forKey: PerformanceOverlayAppearance.backgroundOpacityKey,
                                    default: PerformanceOverlayAppearance.defaultBackgroundOpacity).value = 1 - min(100, max(0, $0)) / 100 }
        )
    }

    private func colorBinding(key: String, defaultRGB: Int) -> Binding<Color> {
        Binding(
            get: { PerformanceOverlayAppearance.color(rgb: settings.setting(forKey: key, default: defaultRGB).value, fallback: defaultRGB) },
            set: { color in
                guard let rgb = rgbValue(color) else {
                    colorError = "所选颜色无法转换为 RGB，原来的颜色已保留。请重新选择。"
                    return
                }
                settings.setting(forKey: key, default: defaultRGB).value = rgb
            }
        )
    }

    /// ColorPicker 的颜色先转到标准 sRGB 再编码为整数；拒绝无法转换或非有限分量。
    private func rgbValue(_ color: Color) -> Int? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = UIColor(color).cgColor.converted(to: space, intent: .defaultIntent, options: nil) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(cgColor: converted).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              red.isFinite, green.isFinite, blue.isFinite else { return nil }
        func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return (component(red) << 16) | (component(green) << 8) | component(blue)
    }
}
