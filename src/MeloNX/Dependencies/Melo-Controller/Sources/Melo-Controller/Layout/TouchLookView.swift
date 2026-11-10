//
//  TouchLookView.swift
//  Melo-Controller
//
//  屏幕滑动视角区域的布局编辑控件。正常游戏输入由宿主 MetalView 处理，
//  本视图只在布局编辑模式显示，避免透明层拦截按钮、摇杆和原生触摸。
//

import SwiftUI

struct EditableTouchLookView: View {
    @Binding var layout: LayoutConfig
    @Binding var isSelected: Bool
    var isEditing: Bool
    var onSelect: () -> Void = {}
    @GestureState private var dragOffset = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            if isEditing {
                let item = layout.touchLook
                let width = max(60, proxy.size.width * item.width)
                let height = max(60, proxy.size.height * item.height)
                let center = CGPoint(
                    x: proxy.size.width * item.centerX + dragOffset.width,
                    y: proxy.size.height * item.centerY + dragOffset.height
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cyan.opacity(item.hidden ? 0.08 : 0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    Color.cyan.opacity(item.hidden ? 0.45 : 0.9),
                                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                                )
                        }

                    VStack(spacing: 5) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 26, weight: .semibold))
                        Text("滑动视角区域")
                            .font(.caption.weight(.semibold))
                        Text(item.hidden ? "已隐藏" : "拖动调整位置")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: width, height: height)
                .position(center)
                .editorSelectionRing(isSelected: isSelected, isCircular: false, tint: .cyan)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                    isSelected = true
                    Haptics.shared.play(.light)
                }
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation
                            isSelected = true
                        }
                        .onEnded { value in
                            var updated = layout.touchLook
                            updated.centerX += value.translation.width / max(1, proxy.size.width)
                            updated.centerY += value.translation.height / max(1, proxy.size.height)
                            if layout.gridEnabled {
                                let gridX = layout.gridSpacing / max(1, proxy.size.width)
                                let gridY = layout.gridSpacing / max(1, proxy.size.height)
                                updated.centerX = (updated.centerX / gridX).rounded() * gridX
                                updated.centerY = (updated.centerY / gridY).rounded() * gridY
                            }
                            updated.clamp()
                            layout.touchLook = updated
                        }
                )
            }
        }
        .allowsHitTesting(isEditing)
    }
}
