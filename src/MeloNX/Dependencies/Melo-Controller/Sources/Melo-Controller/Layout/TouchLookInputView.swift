//
//  TouchLookInputView.swift
//  Melo-Controller
//
//  运行态滑动视角输入层。仅视角区域参与命中，按钮和摇杆由上层控件优先处理。
//

import SwiftUI
import UIKit

final class TouchLookInputUIView: UIView {
    var onMove: (CGPoint) -> Void
    var onBegin: () -> Void
    var layout: TouchLookLayout { didSet { if layout != oldValue { resetTracking() } } }
    var enabled: Bool
    var sensitivity: CGFloat
    var invertX: Bool
    var invertY: Bool
    private var touches: [ObjectIdentifier: CGPoint] = [:]
    private var resetWorkItem: DispatchWorkItem?
    private var previousSize = CGSize.zero

    init(onMove: @escaping (CGPoint) -> Void, onBegin: @escaping () -> Void, layout: TouchLookLayout, enabled: Bool, sensitivity: CGFloat, invertX: Bool, invertY: Bool) {
        self.onMove = onMove
        self.onBegin = onBegin
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
        let rect = ControllerLayoutGeometry.rect(center: CGPoint(x: layout.centerX, y: layout.centerY),
                                                 size: CGSize(width: layout.width, height: layout.height), canvas: bounds.size)
        return rect.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onBegin()
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
            // 不丢弃亚像素增量；慢速移动同样必须能受用户设置的倍率控制。
            guard delta != .zero else { continue }
            delta.x *= sensitivity
            delta.y *= sensitivity
            if invertX { delta.x = -delta.x }
            if invertY { delta.y = -delta.y }
            delta.x = max(-1, min(1, delta.x))
            delta.y = max(-1, min(1, delta.y))
            onMove(delta)
            resetWorkItem?.cancel()
            let reset = DispatchWorkItem { [weak self] in
                self?.onMove(.zero)
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
            onMove(.zero)
        }
    }

    /// 尺寸、区域、可见性或宿主变化后结束当前手势，禁止旧坐标增量进入新布局。
    func resetTracking() {
        touches.removeAll()
        resetWorkItem?.cancel()
        resetWorkItem = nil
        onMove(.zero)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize { resetTracking(); previousSize = bounds.size }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { resetTracking() }
    }
}

struct TouchLookInputView: UIViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onBegin: () -> Void
    let layout: TouchLookLayout
    let enabled: Bool
    let sensitivity: CGFloat
    let invertX: Bool
    let invertY: Bool

    func makeUIView(context: Context) -> TouchLookInputUIView {
        TouchLookInputUIView(onMove: onMove, onBegin: onBegin, layout: layout, enabled: enabled, sensitivity: sensitivity, invertX: invertX, invertY: invertY)
    }

    func updateUIView(_ uiView: TouchLookInputUIView, context: Context) {
        uiView.onMove = onMove
        uiView.onBegin = onBegin
        uiView.layout = layout
        uiView.enabled = enabled
        uiView.sensitivity = sensitivity
        uiView.invertX = invertX
        uiView.invertY = invertY
        if !enabled || layout.hidden { uiView.resetTracking() }
    }

    static func dismantleUIView(_ uiView: TouchLookInputUIView, coordinator: ()) { uiView.resetTracking() }
}
