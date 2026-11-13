//
//  InGameConfigView.swift
//  MeloNX
//
//  Created by Stossy11 on 7/7/2026.
//

import SwiftUI
import Melo_Controller
import Combine

/// 菜单仅发送请求，弹层由不随横竖屏分支卸载的 EmulationView 持有。
struct InGameSettingsRequest: Equatable {
    enum Destination: Equatable { case input, layout }
    let destination: Destination
    let scope: InputSettingsScope
}

class InGameConfigView_MenuView: ObservableObject {
    @Published var hideTask: Task<Void, Never>? = nil
    @Published var showButton: Bool = false
    @Published var settingsRequest: InGameSettingsRequest?

    static var shared: InGameConfigView_MenuView = .init()

    func triggerButton() {
        hideTask?.cancel()

        showButton = true

        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            if !Task.isCancelled {
                showButton = false
            }
        }
    }
}

struct InGameConfigView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject var controllerManager: ControllerManager = .shared
    @ObservedObject var nativeSettingsManager: NativeSettingsManager = .shared
    @StateObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @State var rotationlock: Bool = false
    @State private var showAmiiboSelection: Bool = false
    @State private var showFastForwardSettings: Bool = false



    var body: some View {
        Menu {
            menuButton
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding()
        // 触摸后短暂显示；闲置时完全隐藏，避免齿轮遮挡横屏游戏画面。
        .opacity(menuViewHandler.showButton ? 1 : 0)
        .allowsHitTesting(menuViewHandler.showButton)
        .animation(.easeInOut(duration: 0.6), value: menuViewHandler.showButton)
        .sheet(isPresented: $showAmiiboSelection) {
            AmiiboSelectionView()
        }
        .sheet(isPresented: $showFastForwardSettings) {
            FastForwardButtonSettingsView(
                nativeSettingsManager: nativeSettingsManager,
                ryujinxController: ryujinxController
            )
        }
    }


    @ViewBuilder
    private var menuButton: some View {
        Button {
            ryujinxController.isPaused.toggle()
            ryujinxController.wasManuallyPaused = ryujinxController.isPaused
        } label: {
            Label {
                Text(ryujinxController.isPaused ? String(localized: "Play") : String(localized: "Pause"))
            } icon: {
                Image(systemName: ryujinxController.isPaused ? "play.circle" : "pause.circle")
            }
        }

        Toggle(isOn: fastForwardEnabledBinding) {
            Label(LocalizedStringKey("Enable Fast Forward"), systemImage: "forward.fill")
        }

        Toggle(isOn: fastForwardButtonVisibleBinding) {
            Label(LocalizedStringKey("Show Fast Forward Button"), systemImage: "rectangle.inset.filled")
        }
        .disabled(!fastForwardEnabledBinding.wrappedValue)

        Button {
            showFastForwardSettings = true
        } label: {
            Label(LocalizedStringKey("Fast Forward Button Settings"), systemImage: "slider.horizontal.3")
        }
        .disabled(!fastForwardEnabledBinding.wrappedValue || ryujinxController.isStopping)

        Button {
            menuViewHandler.settingsRequest = InGameSettingsRequest(destination: .input, scope: availableScopes.first ?? .global)
        } label: {
            Label {
                Text(LocalizedStringKey("Configure Controllers"))
            } icon: {
                Image(systemName: "gamecontroller")
            }
        }

        settingsMenu("Input Settings", icon: "slider.horizontal.3", destination: .input)
        settingsMenu("Edit Virtual Controller Layout", icon: "formfitting.gamecontroller", destination: .layout)

        // 目录只提供虚拟身份；打开菜单时继续运行游戏，避免阻塞来宾读取请求。
        Button {
            if case .started(let game, _) = ryujinxController.isRunning {
                AmiiboService.shared.start(titleId: game.titleId)
                AmiiboService.shared.refreshCatalog()
            }
            showAmiiboSelection = true
        } label: {
            Label(LocalizedStringKey("虚拟 amiibo"), systemImage: "person.crop.circle.badge.checkmark")
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            Button {
                rotationlock.toggle()
                if rotationlock {
                    OrientationManager.lockCurrentOrientation(UIDevice.current.orientation)
                } else {
                    OrientationManager.lockOrientation(.all, rotateTo: UIDevice.current.orientation)
                }
            } label: {
                Label {
                    Text(LocalizedStringKey("Rotation Lock"))
                } icon: {
                    Image(systemName: rotationlock ? "lock" : "lock.open")
                }
            }
        }


        Button(role: .destructive) {
            ryujinxController.stopGame()
        } label: {
            Label {
                Text(LocalizedStringKey(ryujinxController.isStopping ? "Exiting..." : "Exit Game"))
            } icon: {
                Image(systemName: ryujinxController.isStopping ? "hourglass" : "x.circle")
            }
        }
        .disabled(ryujinxController.isStopping)

    }

    private var availableScopes: [InputSettingsScope] {
        if case .started(let game, _) = ryujinxController.isRunning,
           ControllerInputProfile.normalizedGameId(game.titleId) != nil {
            return InputSettingsScope.allCases
        }
        return [.global]
    }

    private var fastForwardEnabledBinding: Binding<Bool> {
        let setting = nativeSettingsManager.setting(forKey: "FastForwardEnabled", default: true)
        return Binding(
            get: { setting.value },
            set: { enabled in
                if !enabled {
                    ryujinxController.releaseTurboMode()
                }
                setting.value = enabled
            }
        )
    }

    private var fastForwardButtonVisibleBinding: Binding<Bool> {
        nativeSettingsManager.setting(forKey: "FastForwardButtonVisible", default: true).projectedValue
    }

    private func settingsMenu(_ title: String, icon: String, destination: InGameSettingsRequest.Destination) -> some View {
        Menu {
            ForEach(availableScopes) { scope in
                Button(LocalizedStringKey(scope.title)) {
                    menuViewHandler.settingsRequest = InGameSettingsRequest(destination: destination, scope: scope)
                }
            }
        } label: {
            Label(LocalizedStringKey(title), systemImage: icon)
        }
        .disabled(ryujinxController.isStopping)
    }

}

/// 悬浮快进按钮的游戏专属配置；倍率按游戏保存并限制在 1.0 至 20.0 倍。
private struct FastForwardButtonSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var nativeSettingsManager: NativeSettingsManager
    @ObservedObject var ryujinxController: RyujinxController
    @FocusState private var isMultiplierFocused: Bool
    @State private var multiplierDraft: String = "2.0"
    @State private var multiplierError: MultiplierInputError?

    private let multiplierKey = "FastForwardMultiplier"
    private let defaultMultiplier = 2.0

    private enum MultiplierInputError: Equatable {
        case invalid
        case outOfRange
    }

    init(nativeSettingsManager: NativeSettingsManager, ryujinxController: RyujinxController) {
        self.nativeSettingsManager = nativeSettingsManager
        self.ryujinxController = ryujinxController
        let value: Double = nativeSettingsManager.setting(forKey: "FastForwardMultiplier", default: 2.0).value
        _multiplierDraft = State(initialValue: Self.formattedMultiplier(value))
    }

    private var sizeBinding: Binding<Double> {
        let setting = nativeSettingsManager.setting(forKey: "FastForwardButtonSize", default: 44.0)
        return Binding(
            get: { setting.value },
            set: { setting.value = min(72.0, max(36.0, $0)) }
        )
    }

    private var opacityBinding: Binding<Double> {
        let setting = nativeSettingsManager.setting(forKey: "FastForwardButtonOpacity", default: 0.7)
        return Binding(
            get: { setting.value },
            set: { setting.value = min(1.0, max(0.3, $0)) }
        )
    }

    private var currentMultiplier: Double {
        let value: Double = nativeSettingsManager.setting(forKey: multiplierKey, default: defaultMultiplier).value
        return Self.normalizedMultiplier(value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizedStringKey("Fast Forward Button")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(LocalizedStringKey("Fast Forward Multiplier"))
                            Spacer()
                            TextField("2.0", text: $multiplierDraft)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .focused($isMultiplierFocused)
                                .frame(width: 82)
                                .onSubmit { commitMultiplier() }
                            Text(verbatim: "x").foregroundStyle(.secondary)
                        }
                        Text(LocalizedStringKey("Range: 1.0x to 20.0x"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey("Actual speed depends on the game and device. Audio may be muted during fast forward."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let multiplierError {
                            Text(multiplierError == .invalid
                                 ? LocalizedStringKey("Enter a valid decimal number.")
                                 : LocalizedStringKey("The value was limited to 1.0x to 20.0x."))
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    NavigationLink {
                        FastForwardButtonPositionEditor(nativeSettingsManager: nativeSettingsManager)
                    } label: {
                        Label(LocalizedStringKey("Edit Position"), systemImage: "move.3d")
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text(LocalizedStringKey("Button Size"))
                            Spacer()
                            Text("\(Int(sizeBinding.wrappedValue.rounded())) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: sizeBinding, in: 36...72, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text(LocalizedStringKey("Button Opacity"))
                            Spacer()
                            Text("\(Int((opacityBinding.wrappedValue * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: opacityBinding, in: 0.3...1.0, step: 0.05)
                    }
                }

            }
            .navigationTitle(LocalizedStringKey("Fast Forward Button Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("Done")) {
                        commitMultiplier()
                        dismiss()
                    }
                }
            }
            .onAppear {
                refreshMultiplierDraft()
                synchronizeMultiplier()
            }
            .onChange(of: currentMultiplier) { _ in
                if !isMultiplierFocused { refreshMultiplierDraft() }
            }
            .onDisappear {
                commitMultiplier()
            }
        }
    }

    private static func normalizedMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return 2.0 }
        let clamped = min(20.0, max(1.0, value))
        return (clamped * 10.0).rounded() / 10.0
    }

    private static func formattedMultiplier(_ value: Double) -> String {
        String(format: "%.1f", normalizedMultiplier(value))
    }

    private func refreshMultiplierDraft() {
        multiplierDraft = Self.formattedMultiplier(currentMultiplier)
        multiplierError = nil
    }

    private func synchronizeMultiplier() {
        ryujinxController.setTurboMultiplier(Int((currentMultiplier * 100).rounded()))
    }

    private func commitMultiplier() {
        let input = multiplierDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(input), parsed.isFinite else {
            multiplierError = .invalid
            let fallback = defaultMultiplier
            nativeSettingsManager.setting(forKey: multiplierKey, default: defaultMultiplier).value = fallback
            multiplierDraft = Self.formattedMultiplier(fallback)
            ryujinxController.setTurboMultiplier(Int(fallback * 100))
            return
        }

        multiplierError = parsed < 1.0 || parsed > 20.0 ? .outOfRange : nil
        let normalized = Self.normalizedMultiplier(parsed)
        nativeSettingsManager.setting(forKey: multiplierKey, default: defaultMultiplier).value = normalized
        multiplierDraft = Self.formattedMultiplier(normalized)
        ryujinxController.setTurboMultiplier(Int((normalized * 100).rounded()))
        isMultiplierFocused = false
    }
}

enum FastForwardButtonPosition {
    static func normalized(for value: String) -> CGPoint {
        switch value {
        case "topLeading": return CGPoint(x: 0.08, y: 0.08)
        case "bottomLeading": return CGPoint(x: 0.08, y: 0.92)
        case "bottomTrailing": return CGPoint(x: 0.92, y: 0.92)
        default: return CGPoint(x: 0.92, y: 0.08)
        }
    }
}

/// 在预览画布中拖动按钮并保存归一化坐标；游戏运行时按当前屏幕尺寸换算位置。
private struct FastForwardButtonPositionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var nativeSettingsManager: NativeSettingsManager
    @State private var editingPortrait: Bool
    @State private var canvasSize: CGSize = .zero
    @State private var buttonPoint: CGPoint = .zero

    init(nativeSettingsManager: NativeSettingsManager) {
        self.nativeSettingsManager = nativeSettingsManager
        _editingPortrait = State(initialValue: UIScreen.main.bounds.height >= UIScreen.main.bounds.width)
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker(LocalizedStringKey("Orientation"), selection: $editingPortrait) {
                Text(LocalizedStringKey("Portrait")).tag(true)
                Text(LocalizedStringKey("Landscape")).tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.black.opacity(0.85))
                    Text(LocalizedStringKey("Drag the button to choose its position"))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding()
                    Circle()
                        .fill(Color.accentColor.opacity(0.95))
                        .overlay {
                            Image(systemName: "forward.fill")
                                .foregroundStyle(.white)
                        }
                        .frame(width: 52, height: 52)
                        .position(buttonPoint)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let margin: CGFloat = 30
                                    let x = min(max(value.location.x, margin), max(margin, geometry.size.width - margin))
                                    let y = min(max(value.location.y, margin), max(margin, geometry.size.height - margin))
                                    buttonPoint = CGPoint(x: x, y: y)
                                }
                                .onEnded { _ in
                                    saveCurrentPosition()
                                }
                        )
                }
                .onAppear {
                    canvasSize = geometry.size
                    buttonPoint = point(for: geometry.size)
                }
                .onChange(of: geometry.size) { newSize in
                    canvasSize = newSize
                    buttonPoint = point(for: newSize)
                }
            }
            .padding(.horizontal)

            Button(LocalizedStringKey("Reset Position")) {
                let value = FastForwardButtonPosition.normalized(for: "topTrailing")
                writePosition(value)
                buttonPoint = point(for: canvasSize)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical)
        .navigationTitle(LocalizedStringKey("Edit Position"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LocalizedStringKey("Done")) { dismiss() }
            }
        }
        .onChange(of: editingPortrait) { _ in
            buttonPoint = point(for: canvasSize)
        }
    }

    private func point(for size: CGSize) -> CGPoint {
        let suffix = editingPortrait ? "Portrait" : "Landscape"
        let fallback = FastForwardButtonPosition.normalized(for: "topTrailing")
        let storedX: Double = nativeSettingsManager.setting(forKey: "FastForwardButton\(suffix)X", default: Double(fallback.x)).value
        let storedY: Double = nativeSettingsManager.setting(forKey: "FastForwardButton\(suffix)Y", default: Double(fallback.y)).value
        let x = storedX.isFinite ? min(1.0, max(0.0, storedX)) : fallback.x
        let y = storedY.isFinite ? min(1.0, max(0.0, storedY)) : fallback.y
        return CGPoint(
            x: CGFloat(x) * size.width,
            y: CGFloat(y) * size.height
        )
    }

    private func saveCurrentPosition() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let normalized = CGPoint(
            x: min(1.0, max(0.0, buttonPoint.x / canvasSize.width)),
            y: min(1.0, max(0.0, buttonPoint.y / canvasSize.height))
        )
        writePosition(normalized)
    }

    private func writePosition(_ position: CGPoint) {
        let suffix = editingPortrait ? "Portrait" : "Landscape"
        nativeSettingsManager.setting(forKey: "FastForwardButton\(suffix)X", default: Double(position.x)).value = Double(position.x)
        nativeSettingsManager.setting(forKey: "FastForwardButton\(suffix)Y", default: Double(position.y)).value = Double(position.y)
    }
}
