//
//  JoystickView.swift
//  Melo-Controller
//
//  Created by Stossy11 on 26/1/2026.
//

import SwiftUI

struct EditableJoystickView: View {
    let id: String
    let iscool: Bool
    var controller: any Controller
    @Binding var showBackground: Bool
    @Binding var layout: LayoutConfig
    var isEditing: Bool
    @Binding var selectedJoystick: String?
    @Binding var selectedButton: String?
    @GestureState private var dragOffset = CGSize.zero
    @AppStorage("On-ScreenControllerScale") var controllerScale: Double = 1.0

    private var editorPlaceholder: some View {
        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.22))

            Circle()
                .strokeBorder(
                    Color.white.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 6])
                )

            VStack(spacing: 4) {
                Image(systemName: iscool ? "r.joystick.fill" : "l.joystick.fill")
                    .font(.system(size: 30, weight: .semibold))
                Text(iscool ? "右摇杆" : "左摇杆")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundColor(.white.opacity(0.8))
        }
        .frame(width: 160, height: 160)
    }

    var body: some View {
        if isEditing {
            editorPlaceholder
                .opacity(layout.joysticks[id]?.hidden ?? false ? 0.35 : 1)
                .editorSelectionRing(isSelected: selectedJoystick == id, tint: .green)
                .scaleEffect(
                    (layout.joysticks[id]?.scale ?? 1.0)
                        * controllerScale
                        * (selectedJoystick == id ? 1.04 : 1.0)
                )
                .offset(
                    x: (layout.joysticks[id]?.offset.width ?? 0) + dragOffset.width,
                    y: (layout.joysticks[id]?.offset.height ?? 0) + dragOffset.height
                )
                .onTapGesture {
                    selectedJoystick = selectedJoystick == id ? nil : id
                    selectedButton = nil
                    Haptics.shared.play(.light)
                }
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation
                            selectedJoystick = id
                            selectedButton = nil
                        }
                        .onEnded { value in
                            var item = layout.joysticks[id, default: JoystickLayout()]
                            item.offset.width += value.translation.width
                            item.offset.height += value.translation.height
                            item.offset = layout.snapped(item.offset)
                            layout.joysticks[id] = item
                        }
                )
        } else {
            JoystickViewRepresentable(controller: controller, right: iscool, showBackground: $showBackground)
                .frame(width: 160, height: 160)
                .scaleEffect((layout.joysticks[id]?.scale ?? 1.0) * controllerScale)
                .offset(layout.joysticks[id]?.offset ?? .zero)
        }
    }
}
