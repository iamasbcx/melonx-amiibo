//
//  JoystickViewRepresentable.swift
//  Melo-Controller
//
//  Created by Stossy11 on 28/2/2026.
//


import SwiftUI

struct JoystickViewRepresentable: UIViewRepresentable {
    var right: Bool
    @Binding var showBackground: Bool
    var controller: any Controller
    var visualOpacity: Double = 1.0
    var enabled: Bool
    var onActiveChanged: ((Bool) -> Void)?

    /// 创建摇杆输入视图。透明度只应用于摇杆的视觉子视图，不能作用于承载触摸的 UIView。
    init(controller: any Controller, right: Bool, showBackground: Binding<Bool>, visualOpacity: Double = 1.0,
         enabled: Bool = true, onActiveChanged: ((Bool) -> Void)? = nil) {
        self.right = right
        self._showBackground = showBackground
        self.controller = controller
        self.visualOpacity = visualOpacity
        self.enabled = enabled
        self.onActiveChanged = onActiveChanged
    }

    func makeUIView(context: Context) -> JoystickView {
        let view = JoystickView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: JoystickView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: JoystickView) {
        let controller = controller
        let right = right
        let showBackground = _showBackground
        let onActiveChanged = onActiveChanged
        view.right = right
        view.visualOpacity = CGFloat(visualOpacity.isFinite ? min(1, max(0.05, visualOpacity)) : 1)

        view.onPositionChanged = { newPosition in
            controller.joystickMoved(position: newPosition, right: right)
        }

        view.onActiveChanged = { active in
            showBackground.wrappedValue = active
            onActiveChanged?(active)
        }
        view.inputEnabled = enabled
    }
}
