//
//  CopyLayoutView.swift
//  Melo-Controller
//
//  Created by Stossy11 on 26/1/2026.
//

import SwiftUI

struct CopyLayoutView: View {
    let targetGameId: String?
    let orientation: LayoutOrientation
    @Binding var layout: LayoutConfig
    @Environment(\.presentationMode) var presentationMode
    @State private var availableLayouts: [String] = []

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("可用布局")) {
                    Button(action: {
                        copyLayout(from: nil)
                    }) {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundColor(.blue)
                            Text("默认布局")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.gray)
                        }
                    }

                    ForEach(availableLayouts, id: \.self) { gameId in
                        if gameId != targetGameId {
                            Button(action: {
                                copyLayout(from: gameId)
                            }) {
                                HStack {
                                    Image(systemName: "gamecontroller.fill")
                                        .foregroundColor(.green)
                                    Text(gameId)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("复制布局")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("取消") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
        .onAppear {
            loadAvailableLayouts()
        }
    }

    private func loadAvailableLayouts() {
        availableLayouts = LayoutManager.shared.getAllGameLayouts()
    }

    private func copyLayout(from sourceGameId: String?) {
        let sourceLayout = LayoutManager.shared.load(for: sourceGameId, orientation: orientation)
        layout = sourceLayout
        LayoutManager.shared.save(layout, for: targetGameId, orientation: orientation)
        presentationMode.wrappedValue.dismiss()
    }
}

struct EditableButtonView: View {
    let button: VirtualControllerButton
    var controller: any Controller
    @Binding var layout: LayoutConfig
    var gameId: String?
    var visualOpacity: Double = 1.0
    var isEditing: Bool
    @Binding var selectedButton: String?
    @Binding var selectedJoystick: String?
    @Binding var selectedTouchLook: Bool
    @GestureState private var dragOffset = CGSize.zero

    var body: some View {
        Group {
            if isEditing {
                ButtonView(controller: controller, disabled: true, button: button)
                    .opacity(layout.buttons[button.id]?.hidden ?? false ? 0.35 : 1)
                    .editorSelectionRing(isSelected: selectedButton == button.id, isCircular: !button.isTrigger)
                    .scaleEffect((layout.buttons[button.id]?.scale ?? 1.0) * (selectedButton == button.id ? 1.06 : 1.0))
                    .offset(
                        x: (layout.buttons[button.id]?.offset.width ?? 0) + dragOffset.width,
                        y: (layout.buttons[button.id]?.offset.height ?? 0) + dragOffset.height
                    )
                    .onTapGesture {
                        selectedButton = selectedButton == button.id ? nil : button.id
                        selectedJoystick = nil
                        selectedTouchLook = false
                        Haptics.shared.play(.light)
                    }
                    .gesture(
                        DragGesture()
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                                selectedButton = button.id
                                selectedJoystick = nil
                                selectedTouchLook = false
                            }
                            .onEnded { value in
                                var item = layout.buttons[button.id, default: ButtonLayout()]
                                item.offset.width += value.translation.width
                                item.offset.height += value.translation.height
                                item.offset = layout.snapped(item.offset)
                                layout.buttons[button.id] = item
                            }
                    )
            } else {
                if layout.buttons[button.id, default: ButtonLayout()].hidden {
                    ButtonView(controller: controller, button: button, opacity: visualOpacity, layout: $layout, gameId: gameId)
                        .scaleEffect(layout.buttons[button.id]?.scale ?? 1.0)
                        .offset(layout.buttons[button.id]?.offset ?? .zero)
                        .opacity(0)
                } else {
                    ButtonView(controller: controller, button: button, opacity: visualOpacity, layout: $layout, gameId: gameId)
                        .scaleEffect(layout.buttons[button.id]?.scale ?? 1.0)
                        .offset(layout.buttons[button.id]?.offset ?? .zero)
                }
            }
        }
    }
}
