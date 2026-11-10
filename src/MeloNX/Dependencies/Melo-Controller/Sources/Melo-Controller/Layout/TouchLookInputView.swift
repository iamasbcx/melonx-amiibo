//
//  TouchLookInputView.swift
//  Melo-Controller
//
//  运行态滑动视角输入层。仅视角区域参与命中，按钮和摇杆由上层控件优先处理。
//

import SwiftUI
import UIKit

final class TouchLookInputUIView: UIView {
    var controller: any Controller
    var layout: TouchLookLayout
    var enabled: Bool
    var sensitivity: CGFloat
    var invertX: Bool
    var invertY: Bool
    private var touches: [ObjectIdentifier: CGPoint] = [:]
    private var resetWorkItem: DispatchWorkItem?

    init(controller: any Controller, layout: TouchLookLayout, enabled: Bool, sensitivity: CGFloat, invertX: Bool, invertY: Bool) {
        self.controller = controller
        self.layout = layout
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.invertX = invertX
        self.invertY = invertY
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard enabled, !layout.hidden, bounds.width > 0, bounds.height > 0 else { return false }
        if let window, ControllerTouchRouter.shared.hasControl(at: convert(point, to: window), in: window) {
            return false
        }
        let rect = CGRect(
            x: layout.centerX * bounds.width - layout.width * bounds.width / 2,
            y: layout.centerY * bounds.height - layout.height * bounds.height / 2,
            width: layout.width * bounds.width,
            height: layout.height * bounds.height
        )
        return rect.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { self.touches[ObjectIdentifier(touch)] = touch.location(in: self) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let previous = self.touches[id] else { continue }
            let current = touch.location(in: self)
            self.touches[id] = current
            var delta = CGPoint(
                x: current.x - previous.x,
                y: current.y - previous.y
            )
            guard hypot(delta.x, delta.y) >= 0.5 else { continue }
            delta.x *= sensitivity
            delta.y *= sensitivity
            if invertX { delta.x = -delta.x }
            if invertY { delta.y = -delta.y }
            delta.x = max(-1, min(1, delta.x))
            delta.y = max(-1, min(1, delta.y))
            controller.joystickMoved(position: delta, right: true)
            resetWorkItem?.cancel()
            let reset = DispatchWorkItem { [weak self] in
                self?.controller.joystickMoved(position: .zero, right: true)
            }
            resetWorkItem = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: reset)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches { self.touches.removeValue(forKey: ObjectIdentifier(touch)) }
        if self.touches.isEmpty {
            resetWorkItem?.cancel()
            controller.joystickMoved(position: .zero, right: true)
        }
    }
}

struct TouchLookInputView: UIViewRepresentable {
    let controller: any Controller
    let layout: TouchLookLayout
    let enabled: Bool
    let sensitivity: CGFloat
    let invertX: Bool
    let invertY: Bool

    func makeUIView(context: Context) -> TouchLookInputUIView {
        TouchLookInputUIView(controller: controller, layout: layout, enabled: enabled, sensitivity: sensitivity, invertX: invertX, invertY: invertY)
    }

    func updateUIView(_ uiView: TouchLookInputUIView, context: Context) {
        uiView.controller = controller
        uiView.layout = layout
        uiView.enabled = enabled
        uiView.sensitivity = sensitivity
        uiView.invertX = invertX
        uiView.invertY = invertY
    }
}
