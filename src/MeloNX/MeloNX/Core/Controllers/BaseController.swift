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
    /// 最近一次有效的界面方向。传感器回调不能依赖 UIDeviceOrientation 的瞬时 faceUp/unknown 状态。
    var motionInterfaceOrientation: UIInterfaceOrientation = .unknown
    let motionOrientationLock = NSLock()
    let motionOperation = OperationQueue()
    var lastAccel = SIMD3<Float>(repeating: 0)
    var lastGyro = SIMD3<Float>(repeating: 0)
    let filterAlpha: Float = 0.05
    let motionSubmitInterval: UInt64 = 10_000_000 // 100Hz, in nanoseconds
    var lastMotionSubmit: UInt64 = 0
    
    private var rumbleController: RumbleController?
    var motionManager = CMMotionManager()
    
    var inputQueue: DispatchQueue
    var motionQueue: DispatchQueue
    
    private let lifecycleLock = NSLock()
    private var _isActive: Bool = true
    
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
        setupController()
        Ryujinx.attachGamepad(self.pointer, self.name, controllerType == .handheld ? 8 : index, controllerType)
    }
    
    public func setupController() {
        // Motion setup is usually low frequency, async is fine here
        inputQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupMotion()
        }
        
        setupHaptics()
    }
    
    func updateAxisValue(x: Float, y: Float, forAxis axis: Int) {
        guard isActive else { return }
        
        InGameInputSession.shared.performIfActive {
            Ryujinx.setGamepadStickAxis(self.pointer, stickId: axis, x: x, y: y)
        }
    }
    
    func thumbstickMoved(_ stick: ThumbstickType, x: Double, y: Double) {
        if stick == .right {
            updateAxisValue(x: Float(x), y: Float(-y), forAxis: 2)
        } else {
            updateAxisValue(x: Float(x), y: Float(-y), forAxis: 1)
        }
    }
    
    func setButtonState(_ state: UInt8, for button: VirtualControllerButton) {
        guard isActive else { return }
        
        InGameInputSession.shared.performIfActive {
            Ryujinx.setGamepadButtonState(self.pointer, buttonId: button.rawValue, pressed: state == 1)
        }
    }

    /// 设置页挂起后清空来宾输入；直接提交释放，不能经过已关闭的输入屏障。
    func releaseInputs() {
        guard isActive else { return }
        let buttons: [VirtualControllerButton] = [
            .A, .B, .X, .Y, .back, .guide, .start, .leftStick, .rightStick,
            .leftShoulder, .rightShoulder, .dPadUp, .dPadDown, .dPadLeft, .dPadRight,
            .leftTrigger, .rightTrigger
        ]
        for button in buttons {
            Ryujinx.setGamepadButtonState(pointer, buttonId: button.rawValue, pressed: false)
        }
        Ryujinx.setGamepadStickAxis(pointer, stickId: 1, x: 0, y: 0)
        Ryujinx.setGamepadStickAxis(pointer, stickId: 2, x: 0, y: 0)
        Ryujinx.suspendGamepadMotion(pointer)
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
        rumbleController?.rumble(data: data)
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
            guard let self = self else { return }
            
            let registerRumbleCallback = {
                let userData = Unmanaged.passUnretained(self).toOpaque()
                
                RegisterCallback(
                    "rumble-\(self.id)",
                    self.rumbleCallback,
                    userData
                )
            }
            
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
            
            registerRumbleCallback()
        }
    }
    
    func cleanup() {
        guard markInactive() else { return }
        
        let callbackName = "rumble-\(self.id)"
        callbackName.withCString { UnregisterCallback($0) }
        
        stopMotion()
        rumbleController = nil
        
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
