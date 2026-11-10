//
//  BaseController.swift
//  MeloNX
//
//  Created by Stossy11 on 19/10/2025.
//

import Foundation
import CoreHaptics
import UIKit
import GameController
import CoreMotion
import Melo_Controller

class BaseController: Equatable, Identifiable {
    private(set) lazy var pointer: UnsafeMutableRawPointer = {
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }()
    
    var id: String {
        let pointerInt64 = Int64(bitPattern: UInt64(UInt(bitPattern: self.pointer)))
        return String(pointerInt64, radix: 16, uppercase: true)
    }
    
    var orgName: String = "MeloNX Virtual Controller"
    
    var controllerType: ControllerType = .proController
    
    var virtual: Bool = false
    var name: String { virtual ? orgName : nativeController?.vendorName ?? orgName }
    var nativeController: GCController?
    
    // Motion
    var orientation: UIDeviceOrientation = UIDevice.current.orientation == .unknown ? .landscapeLeft : UIDevice.current.orientation
    let motionOperation = OperationQueue()
    let motionSubmitInterval: UInt64 = 10_000_000 // 100Hz, in nanoseconds
    var lastMotionSubmit: UInt64 = 0
    
    private var rumbleController: RumbleController?
    var motionManager = CMMotionManager()
    
    var inputQueue: DispatchQueue
    var motionQueue: DispatchQueue
    
    private let lifecycleLock = NSLock()
    private var _isActive: Bool = true
    private let inputAttachment = InputAttachmentState()
    let inputResourceActivity = InputResourceActivity()

    /// 传感器/设备回调必须在注册时捕获令牌，不能在旧事件最终写入时重新获取令牌。
    var activeInputAttachment: UInt64? { inputAttachment.activeGeneration }
    var activeMotionRegistration: UInt64? { inputAttachment.activeMotionGeneration }

    func beginMotionRegistration(attachment: UInt64) -> UInt64? {
        inputAttachment.beginMotion(generation: attachment)
    }

    func endMotionRegistration() { inputAttachment.endMotion() }

    func performIfInputAttached(generation: UInt64, motionGeneration: UInt64? = nil, _ action: () -> Void) {
        inputAttachment.performIfActive(generation: generation, motionGeneration: motionGeneration, action)
    }

    /// 先使排队输入失效，再异步停止传感器；旧停止任务不能关闭重新绑定后的采样。
    func endInputAttachment() {
        inputResourceActivity.setAllowed(false)
        inputAttachment.end()
        // 保留设备直到停止任务完成，避免断开后资源释放先于传感器关闭。
        DispatchQueue.main.async { [self] in
            // 同一对象可立即重绑；先清除旧震动，再由后续主线程资源刷新/新回调开启新输出。
            // 传感器仍需绑定检查，防止旧停止任务撤销新注册。
            stopHaptics()
            guard activeInputAttachment == nil else { return }
            stopInputSensors()
        }
    }

    /// 仅主线程调用；子类可同时关闭外设传感器，不改变可复用设备对象的有效状态。
    func stopInputSensors() { stopMotion() }

    /// 主线程按当前游戏/界面需求管理资源；运动停用时冻结核心姿态，恢复首帧由核心重新计时。
    func refreshInputResources(allowed: Bool) {
        precondition(Thread.isMainThread)
        inputResourceActivity.setAllowed(allowed)
        if allowed {
            refreshMotionIfNeeded()
        } else {
            stopInputSensors()
            stopHaptics()
            if let attachment = activeInputAttachment {
                performIfInputAttached(generation: attachment) { Ryujinx.suspendGamepadMotion(pointer) }
            }
        }
    }

    func refreshMotionIfNeeded() {
        guard inputResourceActivity.activeGeneration != nil else { return }
        let usesNativeMotion = nativeController?.motion != nil && !usesDeviceHandlers
        let mappingEnabled = virtual || ControllerMappingStore.shared.runtimeMapping(for: self).motionEnabled
        let enabled = mappingEnabled && (usesNativeMotion ||
            InputPowerPolicy.phoneMotionEnabled(PhoneMotionContextStore.shared.snapshot.controls))
        if enabled {
            if activeMotionRegistration == nil { setupMotion() }
        } else if activeMotionRegistration != nil {
            stopInputSensors()
            if let attachment = activeInputAttachment {
                performIfInputAttached(generation: attachment) { Ryujinx.suspendGamepadMotion(pointer) }
            }
        }
    }
    
    var isActive: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return _isActive
    }
    
    var usesDeviceHandlers: Bool {
        virtual ? true : (name.lowercased() == "Joy-Con (l/R)".lowercased() ||
                          name.lowercased().hasSuffix("backbone") ||
                          name.lowercased() == "backbone one")
    }
    
    
    init(nativeController: GCController?, virtual: Bool? = nil) {
        self.nativeController = nativeController
        self.virtual = virtual ?? (nativeController == nil)
        
        if !self.virtual {
            orgName = "Unknown"
        }
        
        let identifier = UUID().uuidString
        let queueLabel = self.virtual ? "com.stossy11.MeloNX.controller.virtual" : "com.stossy11.MeloNX.controller.\(identifier)"
        
        self.inputQueue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        self.motionQueue = DispatchQueue(label: queueLabel + ".motion", qos: .userInitiated)
        // 按采样先后读取界面方向并提交运动，避免旋转时新旧方向的样本交错。
        self.motionOperation.maxConcurrentOperationCount = 1
        
    }
    
    public func attach(_ index: Int, controllerType: ControllerType) {
        guard isActive else { return }
        inputAttachment.begin()
        setupController()
        Ryujinx.attachGamepad(self.pointer, self.name, controllerType == .handheld ? 8 : index, controllerType)
    }
    
    public func setupController() {
        // 注册与停止均串到主线程；采样队列只读取独立快照，不反向同步等待主线程。
        guard let attachment = activeInputAttachment else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeInputAttachment == attachment else { return }
            self.setupMotion(expectedAttachment: attachment)
        }
        
        setupHaptics()
    }
    
    func updateAxisValue(x: Float, y: Float, forAxis axis: Int, attachment expectedAttachment: UInt64? = nil) {
        guard isActive, let attachment = expectedAttachment ?? activeInputAttachment else { return }
        
        InGameInputSession.shared.performIfActive {
            performIfInputAttached(generation: attachment) {
                Ryujinx.setGamepadStickAxis(self.pointer, stickId: axis, x: x, y: y)
            }
        }
    }
    
    func thumbstickMoved(_ stick: ThumbstickType, x: Double, y: Double) {
        if stick == .right {
            updateAxisValue(x: Float(x), y: Float(-y), forAxis: 2)
        } else {
            updateAxisValue(x: Float(x), y: Float(-y), forAxis: 1)
        }
    }
    
    func setButtonState(_ state: UInt8, for button: VirtualControllerButton, attachment expectedAttachment: UInt64? = nil) {
        guard isActive, let attachment = expectedAttachment ?? activeInputAttachment else { return }
        
        InGameInputSession.shared.performIfActive {
            performIfInputAttached(generation: attachment) {
                Ryujinx.setGamepadButtonState(self.pointer, buttonId: button.rawValue, pressed: state == 1)
            }
        }
    }

    /// 设置页挂起后清空来宾输入；直接提交释放，不能经过已关闭的输入屏障。
    func releaseInputs() {
        guard isActive, let attachment = activeInputAttachment else { return }
        let buttons: [VirtualControllerButton] = [
            .A, .B, .X, .Y, .back, .guide, .start, .leftStick, .rightStick,
            .leftShoulder, .rightShoulder, .dPadUp, .dPadDown, .dPadLeft, .dPadRight,
            .leftTrigger, .rightTrigger
        ]
        performIfInputAttached(generation: attachment) {
            for button in buttons {
                Ryujinx.setGamepadButtonState(pointer, buttonId: button.rawValue, pressed: false)
            }
            Ryujinx.setGamepadStickAxis(pointer, stickId: 1, x: 0, y: 0)
            Ryujinx.setGamepadStickAxis(pointer, stickId: 2, x: 0, y: 0)
            Ryujinx.suspendGamepadMotion(pointer)
        }
    }
    
    private let rumbleCallback: @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Void = { dataPtr, userData in
        
        guard let userData else { return }
        
        let instance = Unmanaged<BaseController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        
        guard let dataPtr else { return }
        
        let callbackData = dataPtr.load(as: CallbackData.self)
        guard let rumbleData = RumbleData(callbackData: callbackData) else { return }
        
        instance.rumble(data: rumbleData)
    }

    func rumble(data: RumbleData) {
        guard let attachment = activeInputAttachment,
              let generation = inputResourceActivity.activeGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeInputAttachment == attachment,
                  self.inputResourceActivity.activeGeneration == generation else { return }
            let active = InputPowerPolicy.hasVibration(durationMs: data.durationMs,
                amplitudes: [data.left.amplitudeLow, data.left.amplitudeHigh, data.right.amplitudeLow, data.right.amplitudeHigh])
            if active { self.createHapticsIfNeeded() }
            self.rumbleController?.rumble(data: data)
        }
    }
    
    func cool() {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        
        RegisterCallback(
            "rumble-\(self.id)",
            rumbleCallback,
            userData
        )
    }
    
    func setupHaptics() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.activeInputAttachment != nil else { return }
            self.cool()
        }
    }

    /// 只有收到有效震动时才创建引擎；所有资源所有权由主线程维护。
    private func createHapticsIfNeeded() {
        precondition(Thread.isMainThread)
        guard rumbleController == nil else { return }
        if let nativeController = self.nativeController,
           !self.usesDeviceHandlers,
           let haptics = nativeController.haptics {
            let localities = haptics.supportedLocalities
            
            if localities.contains(.leftHandle), localities.contains(.rightHandle) {
                self.rumbleController = RumbleController(
                    leftEngine: haptics.createEngine(withLocality: .leftHandle),
                    rightEngine: haptics.createEngine(withLocality: .rightHandle),
                    fallbackEngine: haptics.createEngine(withLocality: .default),
                    rumbleMultiplier: 2.5
                )
            } else if localities.contains(.handles) {
                self.rumbleController = RumbleController(
                    engine: haptics.createEngine(withLocality: .handles),
                    rumbleMultiplier: 2.5
                )
            } else if localities.contains(.default) {
                self.rumbleController = RumbleController(
                    engine: haptics.createEngine(withLocality: .default),
                    rumbleMultiplier: 2.5
                )
            } else if localities.contains(.all) {
                self.rumbleController = RumbleController(
                    engine: haptics.createEngine(withLocality: .all),
                    rumbleMultiplier: 2.5
                )
            } else {
                self.rumbleController = nil
            }
        } else {
            let deviceEngine: CHHapticEngine?
            
            if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                deviceEngine = try? CHHapticEngine()
            } else {
                deviceEngine = nil
            }
            
            self.rumbleController = RumbleController(
                engine: deviceEngine,
                rumbleMultiplier: 2.0
            )
        }
    }

    func stopHaptics() {
        rumbleController?.stop()
        rumbleController = nil
    }
    
    func cleanup() {
        guard markInactive() else { return }
        
        let callbackName = "rumble-\(self.id)"
        callbackName.withCString { UnregisterCallback($0) }
        
        endInputAttachment()
        
        let pointer = self.pointer

        inputQueue.async {
            Ryujinx.detachGamepad(pointer)
        }
    }
    
    private func markInactive() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        
        guard _isActive else { return false }
        
        _isActive = false
        return true
    }
    
    static func == (lhs: BaseController, rhs: BaseController) -> Bool {
        lhs.id == rhs.id
    }
}
