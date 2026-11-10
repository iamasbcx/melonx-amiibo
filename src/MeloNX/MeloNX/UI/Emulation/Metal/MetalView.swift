//
//  MetalView.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import SwiftUI
import MetalKit

class MetalView: MTKView {
    // 此视图只提交游戏原生触屏。滑动视角由全屏手柄层独占，未选虚拟手柄时不接管触点。
    @ObservedObject var menuViewShower: InGameConfigView_MenuView = .shared
    // 原生触摸使用稳定槽位；释放中间触点时不再让其他触点的 index 改变。
    private var activeTouches: [ObjectIdentifier: Int] = [:]
    private var freeTouchIndices: [Int] = []
    private var nextTouchIndex: Int = 0

    func setAspectRatio() {
        Ryujinx.setViewSize(bounds)
        updateUnboundedPresentTargetFps()
    }

    private func updateUnboundedPresentTargetFps() {
        Ryujinx.setUnboundedPresentTargetFps(for: window?.screen)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateUnboundedPresentTargetFps()
        setAspectRatio()
        if window == nil {
            resetTouchTracking()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateUnboundedPresentTargetFps()
        setAspectRatio()
    }
    
    private func transformToTargetCoordinates(_ point: CGPoint) -> CGPoint {
        return point
    }

    private func getNextAvailableIndex() -> Int {
        if let index = freeTouchIndices.popLast() {
            return index
        }
        defer { nextTouchIndex += 1 }
        return nextTouchIndex
    }

    private func slot(for touch: UITouch) -> Int {
        let id = ObjectIdentifier(touch)
        if let index = activeTouches[id] {
            return index
        }
        let index = getNextAvailableIndex()
        activeTouches[id] = index
        return index
    }

    private func releaseSlot(for touch: UITouch) -> Int? {
        let id = ObjectIdentifier(touch)
        guard let index = activeTouches.removeValue(forKey: id) else { return nil }
        freeTouchIndices.append(index)
        return index
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard !isTouchInputDisabled else { resetTouchTracking(); return }
        setAspectRatio()
        for touch in touches {
            Ryujinx.touchBegan(transformToTargetCoordinates(touch.location(in: self)), index: slot(for: touch))
        }
        menuViewShower.triggerButton()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard !isTouchInputDisabled else { resetTouchTracking(); return }
        setAspectRatio()
        for touch in touches {
            guard let index = activeTouches[ObjectIdentifier(touch)] else { continue }
            Ryujinx.touchMoved(transformToTargetCoordinates(touch.location(in: self)), index: index)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finishTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        finishTouches(touches)
    }

    private func finishTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if let index = releaseSlot(for: touch) { Ryujinx.touchEnded(index: index) }
        }
    }

    private var isTouchInputDisabled: Bool {
        InGameInputSession.shared.isSuspended
            || NativeSettingsManager.shared.setting(forKey: "disableTouch", default: false).value
    }

    func resetTouchTracking() {
        // 页面退出或失焦时主动结束仍在协议层的触点，避免游戏收到永久按下状态。
        for index in activeTouches.values {
            Ryujinx.touchEnded(index: index)
        }
        activeTouches.removeAll()
        freeTouchIndices.removeAll(keepingCapacity: true)
        nextTouchIndex = 0
    }
}



struct MetalViewRepresentable: UIViewRepresentable {
    var showView: Bool
    
    init(showView: Bool = true) {
        self.showView = showView
    }
    
    func makeUIView(context: Context) -> UIView {
        let view = showView ? Self.createView() : MetalView()
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @discardableResult
    static func createView() -> UIView {
        if Ryujinx.emulationView == nil {
            let view = MetalView()
            
            guard let metalLayer = view.layer as? CAMetalLayer else {
                fatalError("[Swift] Error: MTKView's layer is not a CAMetalLayer")
            }
            
            UIApplication.shared.isIdleTimerDisabled = true
            
            //metalLayer.presentsWithTransaction = false
            //metalLayer.allowsNextDrawableTimeout = false
            
            if metalLayer.device == nil {
                metalLayer.device = MTLCreateSystemDefaultDevice()
            }
            
            view.framebufferOnly = false

            if #available(iOS 16.0, *) {
                MetalFxBridge.registerCallbacks()
            }
            
            let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
            
            Ryujinx.setNativeWindow(layerPtr)
            Ryujinx.setUnboundedPresentTargetFps(for: view.window?.screen)
            
            Ryujinx.emulationView = view
            return view
        }
        
        return Ryujinx.emulationView!
    }
}
