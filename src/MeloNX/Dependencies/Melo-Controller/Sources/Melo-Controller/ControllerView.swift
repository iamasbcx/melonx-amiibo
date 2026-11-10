//
//  ControllerView.swift
//  Melo-Controller
//
//  Created by Stossy11 on 16/7/2024.
//

import SwiftUI
import GameController
import CoreMotion

/// A closure type used to build an individual button in a custom controller layout.
/// Receives a ``VirtualControllerButton`` and returns a type-erased view.
public typealias SubView = (VirtualControllerButton) -> AnyView

/// A closure type used to build a joystick in a custom controller layout.
///
/// Parameters:
/// - `String`: The joystick ID (e.g. `"leftJoystick"`, `"rightJoystick"`)
/// - `Bool`: `true` if this is the right stick (`iscool`)
/// - `Binding<Bool>`: Controls whether the overlapping D-pad / ABXY overlay is hidden
public typealias JoystickSubView = (String, Bool, Binding<Bool>) -> AnyView

/// A full on-screen nintendo-style game controller  as a SwiftUI view.
///
/// `ControllerView` handles orientation changes, layout persistence, and edit mode.
/// By default it renders a standard portrait or landscape layout automatically.
/// Pass a `customControllerLayout` closure to provide your own arrangement of buttons and sticks.
///
/// **Basic usage (default layout):**
/// ```swift
/// ControllerView(controller: myController, isEditing: false)
/// ```
///
/// **Custom layout:**
/// ```swift
/// ControllerView(controller: myController, isEditing: false) { button, joystick, isPortrait in
///     HStack {
///         joystick("leftJoystick", false, $hideDpad)
///         Spacer()
///         joystick("rightJoystick", true, $hideABXY)
///     }
/// }
/// ```
public struct ControllerView: View {
    var gameId: String?
    var gameName: String?
    private let touchLookEnabled: Bool
    private let touchLookSensitivity: CGFloat
    private let touchLookInvertX: Bool
    private let touchLookInvertY: Bool
    private let visualOpacity: Double
    private let onTouchLookBegan: () -> Void
    @StateObject private var inputRouter: ControllerInputRouter
    @State private var canvasSize = CGSize.zero
    @StateObject var controllerHandler = ControllerHandler()
    @StateObject private var preferences: ControllerPreferences
    private var controllerScale: Double { preferences.scale }
    private var stickButton: Bool { preferences.stickButton }
    @State private var hideDpad = false
    @State private var hideABXY = false
    @State private var selectedButton: String?
    @State private var selectedJoystick: String?
    @State private var selectedTouchLook = false
    @State private var showEditControls = true
    @State var isEditing: Bool = false
    private var isEditingInput: Bool
    @State private var loadedLayoutOrientation: LayoutOrientation?

    private var layoutOrientation: LayoutOrientation {
        controllerHandler.isPortrait ? .portrait : .landscape
    }

    /// An optional closure that replaces the built-in portrait/landscape layouts.
    ///
    /// The closure receives:
    /// - A ``SubView`` factory:  call it with any ``VirtualControllerButton`` to get a fully wired, editable button view.
    /// - A ``JoystickSubView`` factory: call it with an ID, `iscool`, and a `showBackground` binding to get a wired joystick.
    /// - A `Bool` indicating whether the device is currently in portrait orientation.
    ///
    /// Set to `nil` (the default) to use the automatic portrait/landscape layout.
    @State var customControllerLayout: ((@escaping SubView, @escaping JoystickSubView, Bool) -> AnyView)? = nil

    /// Creates a `ControllerView` with a custom button/joystick layout.
    ///
    /// - Parameters:
    ///   - controller: The ``Controller`` object that receives all button and stick input.
    ///   - isEditing: Pass `true` to enter edit mode, where buttons and sticks can be
    ///     repositioned and scaled. Pass `false` for normal play.
    ///   - gameId: An optional identifier used to load and save a per-game layout.
    ///     Pass `nil` to use the global layout.
    ///   - gameName: An optional display name for the game, shown in the layout editor
    ///     instead of `gameId`. The layout is still saved under `gameId`.
    ///   - customControllerLayout: A `@ViewBuilder` closure that composes your own
    ///     controller UI using the provided ``SubView`` and ``JoystickSubView`` factories.
    ///     The `Bool` argument is `true` when the device is in portrait orientation,
    ///     which you can use to switch between layouts.
    public init<V: View>(
        controller: any Controller,
        isEditing: Bool,
        gameId: String? = nil,
        gameName: String? = nil,
        touchLookEnabled: Bool = false,
        touchLookSensitivity: CGFloat = 0.012,
        touchLookInvertX: Bool = false,
        touchLookInvertY: Bool = false,
        visualOpacity: Double = 1.0,
        onTouchLookBegan: @escaping () -> Void = {},
        @ViewBuilder customControllerLayout: @escaping (@escaping SubView, @escaping JoystickSubView, Bool) -> V
    ) {
        self.isEditingInput = isEditing
        self._isEditing = State(initialValue: isEditing)
        self.gameId = gameId
        self.gameName = gameName
        self._preferences = StateObject(wrappedValue: ControllerPreferences(gameId: gameId))
        self.onTouchLookBegan = onTouchLookBegan
        self._inputRouter = StateObject(wrappedValue: ControllerInputRouter(controller: controller))
        self.touchLookEnabled = touchLookEnabled
        self.touchLookSensitivity = touchLookSensitivity
        self.touchLookInvertX = touchLookInvertX
        self.touchLookInvertY = touchLookInvertY
        self.visualOpacity = min(1, max(0.05, visualOpacity.isFinite ? visualOpacity : 1))
        self._customControllerLayout = State(initialValue: { s1, s2, s3 in AnyView(customControllerLayout(s1, s2, s3)) })
    }

    public init(
        controller: any Controller,
        isEditing: Bool,
        gameId: String? = nil,
        gameName: String? = nil,
        touchLookEnabled: Bool = false,
        touchLookSensitivity: CGFloat = 0.012,
        touchLookInvertX: Bool = false,
        touchLookInvertY: Bool = false,
        visualOpacity: Double = 1.0,
        onTouchLookBegan: @escaping () -> Void = {}
    ) {
        self.isEditingInput = isEditing
        self._isEditing = State(initialValue: isEditing)
        self.gameId = gameId
        self.gameName = gameName
        self._preferences = StateObject(wrappedValue: ControllerPreferences(gameId: gameId))
        self.onTouchLookBegan = onTouchLookBegan
        self._inputRouter = StateObject(wrappedValue: ControllerInputRouter(controller: controller))
        self.touchLookEnabled = touchLookEnabled
        self.touchLookSensitivity = touchLookSensitivity
        self.touchLookInvertX = touchLookInvertX
        self.touchLookInvertY = touchLookInvertY
        self.visualOpacity = min(1, max(0.05, visualOpacity.isFinite ? visualOpacity : 1))
    }


    @State private var layout: LayoutConfig = LayoutConfig()

    public var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                GeometryReader { canvas in
                    controllerCanvas
                        .onAppear { updateCanvasSize(canvas.size) }
                        .onChange(of: canvas.size) { updateCanvasSize($0) }
                }
                // 按键位置和滑动区域始终基于全屏画布；编辑工具栏独立遵守安全区。
                .ignoresSafeArea(.container, edges: .vertical)
                editorControls
            }
        }
        .environmentObject(controllerHandler)
        .environment(\.controllerAppearance, preferences.snapshot)
        .onDisappear { inputRouter.reset() }
    }

    @ViewBuilder
    private var editorControls: some View {
        // Edit Controls
        if isEditing {
            if showEditControls {
                LayoutEditorView(
                    preferences: preferences,
                    hideDpad: $hideDpad,
                    hideABXY: $hideABXY,
                    isEditing: $isEditing,
                    showEditControls: $showEditControls,
                    layout: $layout,
                    selectedButton: $selectedButton,
                    selectedJoystick: $selectedJoystick,
                    selectedTouchLook: $selectedTouchLook,
                    orientation: layoutOrientation,
                    canvasSize: canvasSize,
                    gameId: gameId,
                    gameName: gameName
                )
                .zIndex(1)
            } else {
                VStack {
                    HStack {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showEditControls = true
                            }
                        }) {
                            Image(systemName: "eye")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(13)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(12)

                        Spacer()
                    }

                    Spacer()
                }
            }
        }
    }

    private func updateCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
        let next: LayoutOrientation = size.height > size.width ? .portrait : .landscape
        guard next != loadedLayoutOrientation else { return }
        if isEditing, let previous = loadedLayoutOrientation {
            LayoutManager.shared.save(layout, for: gameId, orientation: previous)
        }
        inputRouter.reset()
        controllerHandler.updateOrientation(canvasSize: size)
        loadedLayoutOrientation = next
        loadLayout()
    }

    private var controllerCanvas: some View {
        ZStack {
            if isEditing && layout.gridEnabled {
                LayoutGridOverlay(spacing: layout.gridSpacing)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            EditableTouchLookView(
                layout: $layout,
                isSelected: $selectedTouchLook,
                isEditing: isEditing,
                onSelect: {
                    selectedTouchLook = true
                    selectedButton = nil
                    selectedJoystick = nil
                }
            )
            // 未选中时让实体控件优先；选中后提升区域，便于拖动覆盖到控件附近。
            .zIndex(selectedTouchLook ? 0.6 : -0.5)

            if !isEditing && touchLookEnabled {
                TouchLookInputView(
                    onMove: inputRouter.swipeMoved,
                    onBegin: onTouchLookBegan,
                    layout: layout.touchLook,
                    enabled: true,
                    sensitivity: touchLookSensitivity,
                    invertX: touchLookInvertX,
                    invertY: touchLookInvertY
                )
                .allowsHitTesting(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(0.2)
            }

            Group {
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                if let customControllerLayout {
                    customControllerLayout(editableButton, editableJoystick, controllerHandler.isPortrait)
                } else {
                    if controllerHandler.isPortrait && !isPad {
                        portraitLayout
                    } else {
                        landscapeLayout
                    }
                }
            }
            .padding()
            .id(layoutOrientation)
            // 编辑时实体按钮和摇杆必须高于滑动视角区域，确保重叠位置仍可切换选择。
            .zIndex(isEditing ? 0.7 : 0)
            .onChange(of: isEditingInput) { isEditing = $0 }


        }
    }

    private func loadLayout() {
        layout = LayoutManager.shared.load(for: gameId, orientation: layoutOrientation)

    }

    private var portraitLayout: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                HStack(spacing: 30) {
                    VStack(spacing: 15) {
                        shoulderButtonsLeft
                        ZStack {
                            editableJoystick(id: "leftJoystick", showBackground: $hideDpad)

                            if layout.joysticks["leftJoystick"]?.hide ?? true {
                                dpadView
                                    .opacity(hideDpad ? 0 : 1)
                                    .allowsHitTesting(!hideDpad)
                                    .animation(.easeInOut(duration: 0.2), value: hideDpad)
                            } else {
                                dpadView
                            }
                        }
                    }

                    VStack(spacing: 15) {
                        shoulderButtonsRight
                        ZStack {
                            editableJoystick(id: "rightJoystick", iscool: true, showBackground: $hideABXY)
                            if layout.joysticks["rightJoystick"]?.hide ?? true {
                                abxyView
                                    .opacity(hideABXY ? 0 : 1)
                                    .allowsHitTesting(!hideABXY)
                                    .animation(.easeInOut(duration: 0.2), value: hideABXY)
                            } else {
                                abxyView
                            }
                        }
                    }
                }

                if stickButton {
                    HStack(spacing: 60) {
                        HStack {
                            editableButton(.leftStick).padding()
                            editableButton(.back)
                        }
                        HStack {
                            editableButton(.start)
                            editableButton(.rightStick).padding()
                        }
                    }
                } else {
                    HStack(spacing: 60) {
                        HStack {
                            editableButton(.back)
                        }
                        HStack {
                            editableButton(.start)
                        }
                    }
                }
            }
        }
    }

    private var landscapeLayout: some View {
        VStack {
            Spacer()
            HStack {
                VStack(spacing: 20) {
                    shoulderButtonsLeft
                    ZStack {
                        editableJoystick(id: "leftJoystick", showBackground: $hideDpad)

                        if layout.joysticks["leftJoystick"]?.hide ?? true {
                            dpadView
                                .opacity(hideDpad ? 0 : 1)
                                .allowsHitTesting(!hideDpad)
                                .animation(.easeInOut(duration: 0.2), value: hideDpad)
                        } else {
                            dpadView
                        }
                    }
                }

                Spacer()
                centerButtons
                Spacer()

                VStack(spacing: 20) {
                    shoulderButtonsRight
                    ZStack {
                        editableJoystick(id: "rightJoystick", iscool: true, showBackground: $hideABXY)
                        if layout.joysticks["rightJoystick"]?.hide ?? true {
                            abxyView
                                .opacity(hideABXY ? 0 : 1)
                                .allowsHitTesting(!hideABXY)
                                .animation(.easeInOut(duration: 0.2), value: hideABXY)
                        } else {
                            abxyView
                        }
                    }
                }
            }
        }
    }

    private var centerButtons: some View {
        Group {
            if stickButton {
                VStack {
                    HStack(spacing: 50) {
                        editableButton(.leftStick).padding()
                        Spacer()
                        editableButton(.rightStick).padding()
                    }
                    .padding(.top, 30)

                    HStack(spacing: 50) {
                        editableButton(.back)
                        Spacer()
                        editableButton(.start)
                    }
                }
                .padding(.bottom, 20)
            } else {
                HStack(spacing: 50) {
                    editableButton(.back)
                    Spacer()
                    editableButton(.start)
                }
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Button Groups

    private var shoulderButtonsLeft: some View {
        HStack(spacing: 20) {
            editableButton(.leftTrigger)
            editableButton(.leftShoulder)
        }
        .frame(width: 160 * CGFloat(controllerScale), height: 20 * CGFloat(controllerScale))
    }

    private var shoulderButtonsRight: some View {
        HStack(spacing: 20) {
            editableButton(.rightShoulder)
            editableButton(.rightTrigger)
        }
        .frame(width: 160 * CGFloat(controllerScale), height: 20 * CGFloat(controllerScale))
    }

    private var dpadView: some View {
        VStack(spacing: 7) {
            editableButton(.dPadUp)
            HStack(spacing: 22) {
                editableButton(.dPadLeft)
                Spacer(minLength: 22)
                editableButton(.dPadRight)
            }
            editableButton(.dPadDown)
        }
        .frame(width: 145 * CGFloat(controllerScale), height: 145 * CGFloat(controllerScale))
    }

    private var abxyView: some View {
        VStack(spacing: 7) {
            editableButton(.X)
            HStack(spacing: 22) {
                editableButton(.Y)
                Spacer(minLength: 22)
                editableButton(.A)
            }
            editableButton(.B)
        }
        .frame(width: 145 * CGFloat(controllerScale), height: 145 * CGFloat(controllerScale))
    }

    // MARK: - Helper Methods

    private func editableButton(_ button: VirtualControllerButton) -> AnyView {
        .init(
            EditableButtonView(
                button: button,
                controller: inputRouter,
                layout: $layout,
                gameId: gameId,
                visualOpacity: isEditing ? 1 : visualOpacity,
                isEditing: isEditing,
                selectedButton: $selectedButton,
                selectedJoystick: $selectedJoystick,
                selectedTouchLook: $selectedTouchLook
            )
        )
    }

    private func editableJoystick(
        id: String,
        iscool: Bool = false,
        showBackground: Binding<Bool>,
    ) -> AnyView {
        .init(
            EditableJoystickView(
                id: id,
                iscool: iscool,
                controller: inputRouter,
                visualOpacity: isEditing ? 1 : visualOpacity,
                onActiveChanged: { inputRouter.joystickActivityChanged($0, right: iscool) },
                showBackground: showBackground,
                layout: $layout,
                isEditing: isEditing,
                selectedJoystick: $selectedJoystick,
                selectedButton: $selectedButton,
                selectedTouchLook: $selectedTouchLook,
            )
        )
    }
}

/// 编辑模式下显示的对齐参考线，不参与触摸命中，也不会出现在正常游戏画面。
private struct LayoutGridOverlay: View {
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            guard spacing > 0 else { return }
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
    }
}
