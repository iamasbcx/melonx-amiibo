// 手机六个运动方向的编辑行。只写传入的设置作用域，不改变正在运行游戏的共享设置对象。
import SwiftUI

struct PhoneMotionSettingsRows: View {
    @ObservedObject var settings: NativeSettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phone Motion Directions")
                .font(.headline)
            Text("Enable or reverse each phone movement independently. Disabled directions keep their reverse setting for later use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach(PhoneMotionAxis.allCases) { axis in
            let enabled = settings.setting(forKey: axis.enabledKey, default: true)
            let inverted = settings.setting(forKey: axis.invertedKey, default: axis.defaultInverted)
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(axis.title))
                    .font(.subheadline)
                HStack(spacing: 16) {
                    Toggle("Enabled", isOn: enabled.projectedValue)
                        .accessibilityLabel(Text(LocalizedStringKey(axis.title)) + Text(verbatim: " — ") + Text("Enabled"))
                    Toggle("Reversed", isOn: inverted.projectedValue)
                        .disabled(!enabled.value)
                        .accessibilityLabel(Text(LocalizedStringKey(axis.title)) + Text(verbatim: " — ") + Text("Reversed"))
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }
}
