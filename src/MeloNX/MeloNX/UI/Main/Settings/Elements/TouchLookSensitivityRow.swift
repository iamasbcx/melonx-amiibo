//
//  TouchLookSensitivityRow.swift
//  MeloNX
//
//  编辑滑动视角灵敏度倍数。文本编辑期间只更新暂态草稿，点击应用或键盘完成后才写入设置。
//

import SwiftUI

struct TouchLookSensitivityRow: View {
    @ObservedObject var settings: NativeSettingsManager
    @FocusState private var isFocused: Bool
    @State private var draft = ""
    @State private var inputError: TouchLookSensitivityConfiguration.InputError?
    @State private var hasUnappliedEdits = false

    init(settings: NativeSettingsManager) {
        self._settings = ObservedObject(wrappedValue: settings)
    }

    private var currentMultiplier: Double {
        TouchLookSensitivityConfiguration.multiplier(from: settings)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { draft }, set: { value in
            draft = value
            inputError = nil
            hasUnappliedEdits = true
        })
    }

    private var validationMessage: LocalizedStringKey? {
        switch inputError {
        case .empty:
            return "Enter a sensitivity multiplier."
        case .invalidNumber:
            return "Enter a valid decimal number, such as 2.5."
        case .outOfRange:
            return "Enter a multiplier from 0.25 to 100."
        case nil:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Touch Look Sensitivity")
                Spacer(minLength: 8)
                TextField("", text: draftBinding, prompt: Text(verbatim: "1.0"))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .frame(width: 82)
                    .accessibilityLabel(Text("Touch Look Sensitivity Multiplier"))
                    .onSubmit { applyAndDismiss() }
                Text(verbatim: "×")
                    .foregroundStyle(.secondary)
                Button("Apply") {
                    applyAndDismiss()
                }
                .buttonStyle(.bordered)
            }

            Text("Try 2–3x if swiping feels slow. 1x is the original speed; 0.5x gives finer control.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Range: 0.25–100x. Tap Apply to save. High values reach the game's right-stick speed limit sooner; 100x does not mean 100 times the turning speed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onAppear { refreshDraft() }
        .onChange(of: currentMultiplier) { _ in
            // 设置重置可刷新闲置编辑器，但不能覆盖用户尚未提交的数字或空文本。
            if !isFocused && !hasUnappliedEdits { refreshDraft() }
        }
        .onChange(of: settings.titleId) { _ in
            isFocused = false
            refreshDraft()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isFocused {
                    Spacer()
                    Button("Done") { applyAndDismiss() }
                }
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 15
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func refreshDraft() {
        draft = formatted(currentMultiplier)
        inputError = nil
        hasUnappliedEdits = false
    }

    private func applyAndDismiss() {
        switch TouchLookSensitivityConfiguration.parseMultiplier(draft) {
        case .success(let value):
            TouchLookSensitivityConfiguration.setMultiplier(value, in: settings)
            draft = formatted(value)
            inputError = nil
            hasUnappliedEdits = false
            isFocused = false
        case .failure(let error):
            inputError = error
            isFocused = true
        }
    }
}
