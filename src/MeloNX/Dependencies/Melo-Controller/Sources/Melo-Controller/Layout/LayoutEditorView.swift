//
//  LayoutEditorView.swift
//  Melo-Controller
//
//  Created by Stossy11 on 26/1/2026.
//

import SwiftUI

class JoystickDPadUIHandler: ObservableObject {
    @Published var gameId: String?

    var joystickDpad: Bool {
        get {
            let defaults = UserDefaults.standard
            let scope = gameId.flatMap { $0.isEmpty ? nil : $0 } ?? "global"
            return defaults.object(forKey: "joystickDpad-\(scope)") as? Bool
                ?? defaults.bool(forKey: "joystickDpad-global")
        }
        set {
            let scope = gameId.flatMap { $0.isEmpty ? nil : $0 } ?? "global"
            UserDefaults.standard.set(newValue, forKey: "joystickDpad-\(scope)")
            objectWillChange.send()
        }
    }
}

struct LayoutEditorView: View {
    @ObservedObject var preferences: ControllerPreferences
    @StateObject var joystickDpad = JoystickDPadUIHandler()

    @Binding var hideDpad: Bool
    @Binding var hideABXY: Bool
    @Binding var isEditing: Bool
    @Binding var showEditControls: Bool
    @Binding var layout: LayoutConfig

    @Binding var selectedButton: String?
    @Binding var selectedJoystick: String?
    @Binding var selectedTouchLook: Bool
    let orientation: LayoutOrientation
    let canvasSize: CGSize

    @State private var showingLayoutOptions = false
    @State private var showingResetAlert = false

    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.dismiss) var dismiss

    var gameId: String?
    var gameName: String?

    private var gameTitle: String? {
        guard let gameId = gameId else { return nil }
        return gameName ?? gameId
    }

    private var isWide: Bool { verticalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .pad }

    private var selectionKey: String {
        "\(selectedButton ?? "-")|\(selectedJoystick ?? "-")|\(selectedTouchLook)"
    }

    private func syncDpadHandler() {
        joystickDpad.gameId = gameId
    }

    private func saveLayout() {
        LayoutManager.shared.save(layout, for: gameId, orientation: orientation)
    }

    private func clearSelection() {
        selectedButton = nil
        selectedJoystick = nil
        selectedTouchLook = false
    }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
                .fixedSize(horizontal: false, vertical: true)

            // 参数面板允许滚动；工具栏留在安全区内，不随长面板被挤出或被滚动层覆盖。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let gameTitle = gameTitle { gameBadge(gameTitle) }
                    inspector
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            .frame(maxHeight: max(120, min(420, canvasSize.height * 0.55)), alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: selectionKey)
        .onAppear {
            syncDpadHandler()
        }
        .onChange(of: gameId) { _ in
            syncDpadHandler()
        }
        .sheet(isPresented: $showingLayoutOptions) {
            LayoutOptionsView(gameId: gameId, gameName: gameName, orientation: orientation, layout: $layout)
        }
        .alert("Reset This Layout?", isPresented: $showingResetAlert) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                layout = LayoutConfig()
                LayoutManager.shared.reset(for: gameId, orientation: orientation)
                clearSelection()
            }
        } message: {
            Text("所有按键和摇杆将恢复默认位置、大小和选项。")
        }
    }


    private var toolbar: some View {
        HStack(spacing: 16) {
            EditorChip(icon: "eye.slash", title: "隐藏", showTitle: isWide) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showEditControls = false
                }
            }

            EditorChip(icon: "slider.horizontal.3", title: "选项", showTitle: isWide) {
                showingLayoutOptions = true
            }

            EditorChip(icon: "arrow.counterclockwise", title: "全部重置", tint: .orange, showTitle: isWide) {
                showingResetAlert = true
            }

            Spacer(minLength: 4)

            Button {
                saveLayout()
                clearSelection()
                isEditing = false
                dismiss()
            } label: {
                Text("完成")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    }

    private func gameBadge(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 220)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    }


    @ViewBuilder
    private var inspector: some View {
        if selectedTouchLook {
            touchLookControls
                .transition(.move(edge: .leading).combined(with: .opacity))
        } else if let selectedButton = selectedButton {
            buttonControls(for: selectedButton)
                .transition(.move(edge: .leading).combined(with: .opacity))
        } else if let selectedJoystick = selectedJoystick {
            joystickControls(for: selectedJoystick)
                .transition(.move(edge: .leading).combined(with: .opacity))
        } else {
            globalControls
                .transition(.opacity)
        }
    }

    private var globalControls: some View {
        EditorCard {
            EditorCardHeader(
                title: "整个手柄",
                subtitle: "点击按键或摇杆进行编辑，拖动即可移动。"
            )

            EditorSliderRow(
                title: "手柄大小",
                value: Binding(get: { CGFloat(preferences.scale) }, set: { preferences.scale = Double($0) }),
                range: 0.1...3.0
            )

            EditorToggleRow(
                title: "按键间滑动",
                subtitle: "手指从一个按键直线滑动到另一个按键。",
                isOn: $preferences.buttonSlide
            )

            Button {
                selectedButton = nil
                selectedJoystick = nil
                selectedTouchLook = true
            } label: {
                Label("编辑滑动视角区域", systemImage: "hand.draw")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            EditorToggleRow(
                title: "\u{7F51}\u{683C}\u{5438}\u{9644}",
                subtitle: "\u{62D6}\u{52A8}\u{7ED3}\u{675F}\u{548C}\u{65B9}\u{5411}\u{5FAE}\u{8C03}\u{90FD}\u{4F1A}\u{5BF9}\u{9F50}\u{5230}\u{7F51}\u{683C}\u{3002}",
                isOn: Binding(
                    get: { layout.gridEnabled },
                    set: { enabled in
                        layout.gridEnabled = enabled
                        if enabled { layout.snapAllOffsets(in: canvasSize) }
                    }
                )
            )

            if layout.gridEnabled {
                EditorSliderRow(
                    title: "\u{7F51}\u{683C}\u{95F4}\u{8DDD}",
                    value: Binding(
                        get: { layout.gridSpacing },
                        set: { spacing in
                            layout.gridSpacing = min(64, max(8, spacing))
                            layout.snapAllOffsets(in: canvasSize)
                        }
                    ),
                    range: 8...64,
                    step: 4
                )
            }
        }
    }

    private var touchLookControls: some View {
        EditorCard {
            EditorCardHeader(title: "滑动视角区域", subtitle: "空白区域滑动时控制右摇杆视角") {
                EditorResetButton {
                    layout.touchLook = TouchLookLayout()
                    selectedTouchLook = false
                }
            }

            EditorSliderRow(
                title: "区域宽度",
                value: Binding(
                    get: { layout.touchLook.width },
                    set: { value in
                        var item = layout.touchLook
                        item.width = value
                        item.clamp()
                        layout.touchLook = item
                    }
                ),
                range: 0.1...1.0,
                step: 0.05
            )

            EditorSliderRow(
                title: "区域高度",
                value: Binding(
                    get: { layout.touchLook.height },
                    set: { value in
                        var item = layout.touchLook
                        item.height = value
                        item.clamp()
                        layout.touchLook = item
                    }
                ),
                range: 0.1...1.0,
                step: 0.05
            )

            EditorToggleRow(
                title: "隐藏滑动视角",
                subtitle: "隐藏后仍可通过设置开关恢复。",
                isOn: Binding(
                    get: { layout.touchLook.hidden },
                    set: { value in
                        var item = layout.touchLook
                        item.hidden = value
                        layout.touchLook = item
                    }
                )
            )

            EditorNudgePad { dx, dy in
                var item = layout.touchLook
                let center = ControllerLayoutGeometry.nudgedCenter(CGPoint(x: item.centerX, y: item.centerY),
                    size: CGSize(width: item.width, height: item.height), canvas: canvasSize,
                    dx: dx, dy: dy, gridSpacing: layout.gridEnabled ? layout.gridSpacing : nil)
                item.centerX = center.x
                item.centerY = center.y
                item.clamp()
                layout.touchLook = item
            }
        }
    }


    private func buttonControls(for buttonId: String) -> some View {
        EditorCard {
            EditorCardHeader(
                title: LayoutEditorNaming.displayName(for: buttonId),
                subtitle: "按键"
            ) {
                EditorResetButton {
                    layout.buttons[buttonId] = nil
                    selectedButton = nil
                }
            }

            EditorSliderRow(
                title: "大小",
                value: Binding(
                    get: { layout.buttons[buttonId]?.scale ?? 1.0 },
                    set: { layout.buttons[buttonId, default: ButtonLayout()].scale = $0 }
                )
            )

            EditorToggleRow(
                title: "隐藏按键",
                isOn: Binding(
                    get: { layout.buttons[buttonId]?.hidden ?? false },
                    set: { layout.buttons[buttonId, default: ButtonLayout()].hidden = $0 }
                )
            )

            EditorToggleRow(
                title: "切换模式",
                subtitle: "点击一次保持按下，再次点击释放。",
                isOn: Binding(
                    get: { layout.buttons[buttonId]?.toggle ?? false },
                    set: { layout.buttons[buttonId, default: ButtonLayout()].toggle = $0 }
                )
            )

            EditorNudgePad { dx, dy in
                nudgeButton(buttonId, dx: dx, dy: dy)
            }

            if buttonId.lowercased().contains("dpad") {
                EditorToggleRow(
                    title: "十字键模拟摇杆",
                    isOn: Binding(
                        get: { joystickDpad.joystickDpad },
                        set: { joystickDpad.joystickDpad = $0 }
                    )
                )
            }
        }
    }


    private func joystickControls(for joystickId: String) -> some View {
        EditorCard {
            EditorCardHeader(
                title: LayoutEditorNaming.displayName(for: joystickId),
                subtitle: "摇杆"
            ) {
                EditorResetButton {
                    layout.joysticks[joystickId] = nil
                    selectedJoystick = nil
                }
            }

            EditorSliderRow(
                title: "大小",
                value: Binding(
                    get: { layout.joysticks[joystickId]?.scale ?? 1.0 },
                    set: { layout.joysticks[joystickId, default: JoystickLayout()].scale = $0 }
                )
            )

            EditorToggleRow(
                title: "隐藏摇杆",
                isOn: Binding(
                    get: { layout.joysticks[joystickId]?.hidden ?? false },
                    set: { layout.joysticks[joystickId, default: JoystickLayout()].hidden = $0 }
                )
            )

            EditorToggleRow(
                title: "隐藏下方按键",
                subtitle: "使用摇杆时淡化重叠的十字键或 ABXY 按键。",
                isOn: Binding(
                    get: { layout.joysticks[joystickId]?.hide ?? true },
                    set: { layout.joysticks[joystickId, default: JoystickLayout()].hide = $0 }
                )
            )

            EditorToggleRow(
                title: "始终显示背景",
                isOn: Binding(
                    get: { layout.joysticks[joystickId]?.background ?? false },
                    set: { layout.joysticks[joystickId, default: JoystickLayout()].background = $0 }
                )
            )

            EditorNudgePad { dx, dy in
                nudgeJoystick(joystickId, dx: dx, dy: dy)
            }
        }
    }

    private func nudgeButton(_ id: String, dx: Int, dy: Int) {
        var item = layout.buttons[id, default: ButtonLayout()]
        let step = layout.gridEnabled ? layout.gridSpacing : 1
        item.offset.width += CGFloat(dx) * step
        item.offset.height += CGFloat(dy) * step
        item.offset = layout.snapped(item.offset)
        layout.buttons[id] = item
    }

    private func nudgeJoystick(_ id: String, dx: Int, dy: Int) {
        var item = layout.joysticks[id, default: JoystickLayout()]
        let step = layout.gridEnabled ? layout.gridSpacing : 1
        item.offset.width += CGFloat(dx) * step
        item.offset.height += CGFloat(dy) * step
        item.offset = layout.snapped(item.offset)
        layout.joysticks[id] = item
    }
}

enum LayoutEditorNaming {
    static func displayName(for id: String) -> String {
        if id.count == 1 { return id.uppercased() }

        var words: [String] = []
        var current = ""
        for character in id {
            if character.isUppercase && !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }

        return words
            .map { word -> String in
                switch word.lowercased() {
                case "dpad", "d": return "D-Pad"
                case "pad": return "Pad"
                case "abxy": return "ABXY"
                default: return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
            .replacingOccurrences(of: "D Pad", with: "D-Pad")
    }
}

struct EditorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct EditorCardHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            accessory
        }
    }
}

extension EditorCardHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct EditorResetButton: View {
    let action: () -> Void

    var body: some View {
        Button("重置", action: action)
            .font(.caption.weight(.semibold))
            .foregroundColor(.orange)
            .buttonStyle(.plain)
    }
}

struct EditorChip: View {
    let icon: String
    let title: String
    var tint: Color?
    var showTitle: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                if showTitle {
                    Text(title)
                        .font(.caption.weight(.medium))
                }
            }
            .foregroundColor(tint ?? .primary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EditorSliderRow: View {
    let title: String
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat> = 0.5...2.0
    var step: CGFloat = 0.1

    private func nudge(_ amount: CGFloat) {
        let next = (value + amount).rounded(toNearest: step)
        value = min(range.upperBound, max(range.lowerBound, next))
        Haptics.shared.play(.light)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f×", value))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                EditorStepperButton(icon: "minus") { nudge(-step) }

                Slider(value: $value, in: range, step: step)

                EditorStepperButton(icon: "plus") { nudge(step) }
            }
        }
    }
}

struct EditorStepperButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 26)
        }
        .buttonStyle(.plain)
    }
}

/// 四向微调控件，按键和摇杆共用同一组方向操作。
struct EditorNudgePad: View {
    let action: (_ dx: Int, _ dy: Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            EditorStepperButton(icon: "chevron.up") { action(0, -1) }
            HStack(spacing: 8) {
                EditorStepperButton(icon: "chevron.left") { action(-1, 0) }
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 26)
                EditorStepperButton(icon: "chevron.right") { action(1, 0) }
            }
            EditorStepperButton(icon: "chevron.down") { action(0, 1) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct EditorToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

private extension CGFloat {
    func rounded(toNearest step: CGFloat) -> CGFloat {
        guard step > 0 else { return self }

        return (self / step).rounded() * step
    }
}

struct EditorSelectionRing: ViewModifier {
    let isSelected: Bool
    var isCircular: Bool = true
    var tint: Color = .blue

    func body(content: Content) -> some View {
        content
            .overlay {
                Group {
                    if isCircular {
                        Circle()
                            .strokeBorder(tint, lineWidth: 2.5)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint, lineWidth: 2.5)
                    }
                }
                .padding(-7)
                .opacity(isSelected ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: isSelected)
            }
    }
}

extension View {
    func editorSelectionRing(isSelected: Bool, isCircular: Bool = true, tint: Color = .blue) -> some View {
        modifier(EditorSelectionRing(isSelected: isSelected, isCircular: isCircular, tint: tint))
    }
}
