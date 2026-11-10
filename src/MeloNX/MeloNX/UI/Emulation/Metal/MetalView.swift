//
//  MetalView.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import SwiftUI
import MetalKit
import Melo_Controller

class MetalView: MTKView {
    @ObservedObject var menuViewShower: InGameConfigView_MenuView = .shared
    // 原生触摸使用稳定槽位；释放中间触点时不再让其他触点的 index 改变。
    private var activeTouches: [ObjectIdentifier: Int] = [:]
    private var freeTouchIndices: [Int] = []
    private var nextTouchIndex: Int = 0

    // 屏幕滑动视角状态。设置页可在创建/复用 MetalView 后更新这些属性。
    var touchLookEnabled: Bool = false
    var touchLookSensitivity: CGFloat = 0.012
    var touchLookDeadZone: CGFloat = 0.5
    var touchLookInvertX: Bool = false
    var touchLookInvertY: Bool = false
    var touchLookGameId: String?
    /// 归一化视角区域，默认是右半屏；区域外仍发送游戏触摸事件。
    var touchLookActivationRect: CGRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    /// 视角输入的短暂保持时间，避免单个移动事件被游戏采样遗漏。
    var touchLookHoldDuration: TimeInterval = 0.04
    private var touchLookTouches: [ObjectIdentifier: CGPoint] = [:]
    private var touchLookResetWorkItem: DispatchWorkItem?

    private var aspectRatio: AspectRatio = .fixed16x9

    private var layoutOrientation: LayoutOrientation {
        // 竖屏时游戏画面仍可能固定为 16:9；布局方向以所在界面为准，不能由画面宽高推断。
        switch window?.windowScene?.interfaceOrientation {
        case .portrait?, .portraitUpsideDown?: return .portrait
        case .landscapeLeft?, .landscapeRight?: return .landscape
        default: return bounds.height > bounds.width ? .portrait : .landscape
        }
    }

    /// 切换游戏布局时清理旧触点，并立即应用对应的全局/单游戏视角区域。
    func configureTouchLook(gameId: String?) {
        let gameId = ControllerInputProfile.normalizedGameId(gameId)
        guard touchLookGameId != gameId else {
            syncTouchLookSettings()
            return
        }
        resetTouchTracking()
        touchLookGameId = gameId
        setAspectRatio()
    }

    func setAspectRatio() {
        self.aspectRatio = RyujinxController.shared.currentSettings.aspectRatio
        syncTouchLookSettings()
        Ryujinx.setViewSize(self.bounds)
        updateUnboundedPresentTargetFps()
    }

    /// 从当前全局/单游戏设置同步滑动视角参数，保证游戏启动后设置立即生效。
    private func syncTouchLookSettings() {
        let settings = NativeSettingsManager.shared
        touchLookEnabled = settings.setting(forKey: "TouchLookEnabled", default: false).value
        touchLookSensitivity = CGFloat(TouchLookSensitivityConfiguration.coefficient(from: settings))
        let deadZone = CGFloat(settings.setting(forKey: "TouchLookDeadZone", default: 0.5).value)
        touchLookDeadZone = deadZone.isFinite ? min(20, max(0, deadZone)) : 0.5
        touchLookInvertX = settings.setting(forKey: "TouchLookInvertX", default: false).value
        touchLookInvertY = settings.setting(forKey: "TouchLookInvertY", default: false).value
        let touchLookLayout = LayoutManager.touchLookLayout(for: touchLookGameId, orientation: layoutOrientation)
        touchLookActivationRect = touchLookLayout.rect
        touchLookEnabled = touchLookEnabled && !touchLookLayout.hidden
    }

    private func updateUnboundedPresentTargetFps() {
        Ryujinx.setUnboundedPresentTargetFps(for: window?.screen)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateUnboundedPresentTargetFps()
        syncTouchLookSettings()
        if window == nil {
            resetTouchTracking()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateUnboundedPresentTargetFps()
        syncTouchLookSettings()
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

    private func resolvedTouchLookRect() -> CGRect {
        let rect = touchLookActivationRect
        let normalized = rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
        if normalized {
            return CGRect(
                x: rect.minX * bounds.width,
                y: rect.minY * bounds.height,
                width: rect.width * bounds.width,
                height: rect.height * bounds.height
            )
        }
        return rect.intersection(bounds)
    }

    private func isTouchLookStart(_ location: CGPoint) -> Bool {
        guard touchLookEnabled else { return false }
        return resolvedTouchLookRect().contains(location)
    }

    private func submitTouchLookDelta(_ raw: CGPoint) {
        let deadZone = max(0, touchLookDeadZone)
        guard abs(raw.x) >= deadZone || abs(raw.y) >= deadZone else { return }

        var delta = CGPoint(
            x: raw.x * touchLookSensitivity,
            y: raw.y * touchLookSensitivity
        )
        if touchLookInvertX { delta.x = -delta.x }
        if touchLookInvertY { delta.y = -delta.y }
        delta.x = max(-1, min(1, delta.x))
        delta.y = max(-1, min(1, delta.y))

        VirtualControllerManager.shared.joystickMoved(position: delta, right: true)
        touchLookResetWorkItem?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            VirtualControllerManager.shared.joystickMoved(position: .zero, right: true)
            self.touchLookResetWorkItem = nil
        }
        touchLookResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, touchLookHoldDuration), execute: reset)
    }

    private func resetTouchLook() {
        touchLookTouches.removeAll(keepingCapacity: true)
        touchLookResetWorkItem?.cancel()
        touchLookResetWorkItem = nil
        VirtualControllerManager.shared.joystickMoved(position: .zero, right: true)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        
        guard !isTouchInputDisabled else { resetTouchTracking(); return }
        
        setAspectRatio()
        var shouldShowMenu = false
        
        for touch in touches {
            let location = touch.location(in: self)
            let id = ObjectIdentifier(touch)
            if isTouchLookStart(location) {
                // 视角触点不进入 Ryujinx 触摸协议，归属在开始时固定。
                touchLookTouches[id] = location
                continue
            }

            shouldShowMenu = true
            let index = slot(for: touch)
            let transformed = transformToTargetCoordinates(location)
            Ryujinx.touchBegan(transformed, index: index)
        }

        if shouldShowMenu {
            menuViewShower.triggerButton()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        
        
        guard !isTouchInputDisabled else { resetTouchTracking(); return }
        
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if touchLookTouches.removeValue(forKey: id) != nil {
                // 视角触点结束时最后一个触点必须立即归零，避免松手后继续转动。
                if touchLookTouches.isEmpty {
                    resetTouchLook()
                }
                continue
            }
            
            if let touchIndex = releaseSlot(for: touch) {
                Ryujinx.touchEnded(index: touchIndex)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        
        guard !isTouchInputDisabled else { resetTouchTracking(); return }
        
        setAspectRatio()
        
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let previous = touchLookTouches[id] {
                let current = touch.location(in: self)
                touchLookTouches[id] = current
                submitTouchLookDelta(CGPoint(x: current.x - previous.x, y: current.y - previous.y))
                continue
            }
            
            
            guard let touchIndex = activeTouches[id] else {
                continue
            }
            
            let location = touch.location(in: self)
            let transformed = transformToTargetCoordinates(location)
            Ryujinx.touchMoved(transformed, index: touchIndex)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard !isTouchInputDisabled else { resetTouchTracking(); return }
        
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if touchLookTouches.removeValue(forKey: id) != nil {
                if touchLookTouches.isEmpty {
                    resetTouchLook()
                }
                continue
            }
            
            if let touchIndex = releaseSlot(for: touch) {
                Ryujinx.touchEnded(index: touchIndex)
            }
        }
    }
    

    /// 触摸路径与设置页使用相同的游戏作用域，编辑时禁止触点进入来宾游戏。
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
        resetTouchLook()
    }
}



struct MetalViewRepresentable: UIViewRepresentable {
    var showView: Bool
    var gameId: String?
    
    init(showView: Bool = true, gameId: String? = nil) {
        self.showView = showView
        self.gameId = gameId
    }
    
    func makeUIView(context: Context) -> UIView {
        if showView {
            let view = Self.createView()
            (view as? MetalView)?.configureTouchLook(gameId: gameId)
            return view
        } else {
            let view = MetalView()
            view.configureTouchLook(gameId: gameId)
            return view
        }
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? MetalView)?.configureTouchLook(gameId: gameId)
    }
    
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
