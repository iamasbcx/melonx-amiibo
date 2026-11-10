// 游戏内输入设置。当前游戏与全局管理器相互独立，切换编辑范围不会替换运行态 shared。
import SwiftUI
import Combine

enum InputSettingsScope: String, CaseIterable, Identifiable {
    case currentGame
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentGame: return "Current Game"
        case .global: return "Global Defaults"
        }
    }
}

struct InputControlsSettingsView: View {
    let game: GameInfo
    let onEditLayout: ((InputSettingsScope) -> Void)?
    @State private var scope: InputSettingsScope
    @Environment(\.dismiss) private var dismiss

    init(game: GameInfo, scope: InputSettingsScope, onEditLayout: ((InputSettingsScope) -> Void)? = nil) {
        self.game = game
        self.onEditLayout = onEditLayout
        self._scope = State(initialValue: game.titleId.isEmpty || game.titleId == "0" ? .global : scope)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Editing Scope", selection: $scope) {
                        if !game.titleId.isEmpty && game.titleId != "0" {
                            Text("Current Game").tag(InputSettingsScope.currentGame)
                        }
                        Text("Global Defaults").tag(InputSettingsScope.global)
                    }
                    .pickerStyle(.segmented)
                    if scope == .currentGame {
                        Text(verbatim: game.titleName)
                            .font(.subheadline)
                    }
                } header: {
                    Text("Editing Scope")
                } footer: {
                    Text("Current-game values override global defaults for each setting. Global changes apply wherever the game has no override.")
                }

                // 重建作用域内容及草稿，防止未应用的灵敏度被提交到另一份设置中。
                InputControlsSettingsForm(game: game, scope: scope, onEditLayout: onEditLayout)
                    .id(scope)
            }
            .navigationTitle("Input Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct InputControlsSettingsForm: View {
    let game: GameInfo
    let scope: InputSettingsScope
    let onEditLayout: ((InputSettingsScope) -> Void)?
    @StateObject private var settings: NativeSettingsManager
    @State private var confirmingReset = false
    @State private var inputRevision = 0
    @State private var resetError: String?

    init(game: GameInfo, scope: InputSettingsScope, onEditLayout: ((InputSettingsScope) -> Void)?) {
        self.game = game
        self.scope = scope
        self.onEditLayout = onEditLayout
        self._settings = StateObject(wrappedValue: scope == .currentGame
            ? NativeSettingsManager(game.titleId, true)
            : NativeSettingsManager())
    }

    private var gameId: String? { scope == .currentGame ? game.titleId : nil }

    /// 恢复输入继承时保留模拟器配置及布局位置文件。
    private var scopedKeys: [String] {
        ["TouchLookEnabled", "TouchLookSensitivityMultiplier", "TouchLookInvertX", "TouchLookInvertY",
         "On-ScreenControllerOpacity", "On-ScreenControllerScale", "stickButton", "virtualControllerOffDefault",
         "disableTouch", "showScreenShotButton", "buttonSlide"]
            + PhoneMotionAxis.allCases.flatMap { [$0.enabledKey, $0.invertedKey] }
    }

    private var joystickDpad: Binding<Bool> {
        let key = "joystickDpad-" + (gameId ?? "global")
        return Binding(get: {
            UserDefaults.standard.object(forKey: key) as? Bool
                ?? UserDefaults.standard.object(forKey: "joystickDpad-global") as? Bool ?? false
        }, set: {
            UserDefaults.standard.set($0, forKey: key)
            settings.objectWillChange.send()
        })
    }

    private var opacity: Binding<Float> {
        let setting = settings.setting(forKey: "On-ScreenControllerOpacity", default: 1.0)
        return Binding(
            get: {
                let value = setting.value
                return Float(value.isFinite ? min(1, max(0.05, value)) : 1)
            },
            set: { value in
                setting.value = Double(value.isFinite ? min(1, max(0.05, value)) : 1)
            }
        )
    }

    private var controllerScale: Binding<Float> {
        let setting = settings.setting(forKey: "On-ScreenControllerScale", default: 1.0)
        return Binding(
            get: {
                let value = setting.value
                return Float(value.isFinite ? min(3, max(0.1, value)) : 1)
            },
            set: { value in
                setting.value = Double(value.isFinite ? min(3, max(0.1, value)) : 1)
            }
        )
    }

    var body: some View {
        ScopedControllerSelectionView(gameId: gameId)

        Section {
            NativeToggleRow("Disable Touch", icon: "hand.point.up.left.fill",
                            isOn: settings.setting(forKey: "disableTouch", default: false).projectedValue,
                            info: "Disables the touch screen (not the virtual controller).")
            NativeToggleRow("Menu Button (in-game)", icon: "gearshape",
                            isOn: settings.setting(forKey: "showScreenShotButton", default: true).projectedValue)
            NativeToggleRow("Touch Look", icon: "hand.draw",
                            isOn: settings.setting(forKey: "TouchLookEnabled", default: false).projectedValue)
            TouchLookSensitivityRow(settings: settings)
                .id(inputRevision)
            PhoneMotionSettingsRows(settings: settings)
            NativeToggleRow("Invert Touch Look X", icon: "arrow.left.and.right",
                            isOn: settings.setting(forKey: "TouchLookInvertX", default: false).projectedValue)
            NativeToggleRow("Invert Touch Look Y", icon: "arrow.up.and.down",
                            isOn: settings.setting(forKey: "TouchLookInvertY", default: false).projectedValue)
        } header: {
            Text("Camera and Phone Motion")
        }

        Section {
            if let onEditLayout {
                Button {
                    onEditLayout(scope)
                } label: {
                    Label("Edit Virtual Controller Layout", systemImage: "formfitting.gamecontroller")
                }
            }
            SliderRow("Scale", value: controllerScale, range: 0.1...3.0, step: 0.05,
                      minLabel: "Smaller", maxLabel: "Larger")
            SliderRow("Opacity", value: opacity, range: 0.05...1.0, step: 0.05,
                      minLabel: "More Transparent", maxLabel: "Less Transparent", suffix: "")
            NativeToggleRow("Show Stick Buttons (L3/R3)", icon: "l.joystick.press.down",
                            isOn: settings.setting(forKey: "stickButton", default: false).projectedValue)
            NativeToggleRow("Slide Between Buttons", icon: "hand.draw",
                            isOn: settings.setting(forKey: "buttonSlide", default: true).projectedValue)
            NativeToggleRow("Use D-Pad for Left Stick", icon: "dpad",
                            isOn: joystickDpad)
            NativeToggleRow("Deselected by Default", icon: "formfitting.gamecontroller.fill",
                            isOn: settings.setting(forKey: "virtualControllerOffDefault", default: ProcessInfo.processInfo.isiOSAppOnMac).projectedValue,
                            info: "Deselects the virtual controller by default, regardless of whether a physical controller is connected.")
        } header: {
            Text("Virtual Controller Appearance")
        } footer: {
            Text("Edit the controller layout to change button positions, grid snapping, and the right stick or swipe-area size and visibility.")
        }

        if scope == .currentGame {
            Section {
                Button("Use Global Input Defaults", role: .destructive) {
                    confirmingReset = true
                }
            } footer: {
                Text("Removes only this game's input overrides shown on this page. Other game settings and controller layouts are kept.")
            }
            .confirmationDialog("Use Global Input Defaults?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Use Global Input Defaults", role: .destructive) { resetInputOverrides() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Input Settings Error", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
                Button("OK", role: .cancel) { resetError = nil }
            } message: {
                Text(verbatim: resetError ?? "")
            }
        }
    }

    private func resetInputOverrides() {
        do {
            try ControllerMappingStore.shared.resetOverrides(gameId: game.titleId)
            try resetKeyboardConfig(gameId: game.titleId)
            ControllerInputProfile.resetOverrides(gameId: game.titleId)
            for key in scopedKeys {
                UserDefaults.standard.removeObject(forKey: key + game.titleId)
            }
            UserDefaults.standard.removeObject(forKey: "joystickDpad-" + game.titleId)
            inputRevision += 1
            settings.refreshOverrideMarker()
        } catch {
            resetError = error.localizedDescription
        }
    }
}
