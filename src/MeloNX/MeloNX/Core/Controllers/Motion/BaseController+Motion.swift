//
//  BaseController+Motion.swift
//  MeloNX
//
//  Created by Stossy11 on 16/11/2025.
//

import Foundation
import CoreMotion
import GameController
import UIKit

extension BaseController {
    /// 传感器注册只在主线程执行；绑定和注册代次均由回调捕获，旧设备回调不得进入新绑定。
    func setupMotion(expectedAttachment: UInt64? = nil) {
        guard let attachment = expectedAttachment ?? activeInputAttachment else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setupMotion(expectedAttachment: attachment)
            }
            return
        }
        guard isActive, activeInputAttachment == attachment else { return }
        stopMotion()
        guard let registration = beginMotionRegistration(attachment: attachment) else { return }
        if let nativeController, nativeController.motion != nil, !self.usesDeviceHandlers {
            guard ControllerMappingStore.shared.runtimeMapping(for: self).motionEnabled else {
                nativeController.motion?.valueChangedHandler = nil
                nativeController.motion?.sensorsActive = false
                
                return
            }
            
            nativeController.motion?.sensorsActive = true
            
            // Thank you @BXYMartin :3
            nativeController.motion?.valueChangedHandler = { [weak self] m in
                guard let self = self, self.activeInputAttachment == attachment,
                      self.activeMotionRegistration == registration else { return }
                
                guard let generation = InGameInputSession.shared.activeGeneration,
                      self.shouldSubmitMotion() else { return }
                
                let rawAccelX = Float(m.acceleration.x)
                let rawAccelY = Float(m.acceleration.y)
                let rawAccelZ = Float(m.acceleration.z)
                
                let rawGyroDeg = SIMD3<Float>(
                    Float(m.rotationRate.x),
                    Float(m.rotationRate.y),
                    Float(m.rotationRate.z)
                ) * 180.0 / .pi
                
                let accel = SIMD3(-rawAccelX, -rawAccelZ, rawAccelY)
                let gyro = SIMD3(rawGyroDeg.x, rawGyroDeg.z, -rawGyroDeg.y)
                
                self.submitMotion(accelerometer: accel, gyroscope: gyro, generation: generation, attachment: attachment, registration: registration)
            }
        } else {
            guard self.motionManager.isDeviceMotionAvailable else { return }
            
            self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60Hz
            _ = self.currentMotionInterfaceOrientation()
            self.motionManager.startDeviceMotionUpdates(to: self.motionOperation) { [weak self] (data, error) in
                guard let self = self, let m = data, self.activeInputAttachment == attachment,
                      self.activeMotionRegistration == registration else { return }
                guard let generation = InGameInputSession.shared.activeGeneration,
                      self.shouldSubmitMotion() else { return }
                
                let context = self.currentPhoneMotionContext()
                guard let transformOrientation = self.phoneMotionOrientation(context.orientation) else { return }
                let sample = PhoneMotionTransform.driverSample(
                    gravity: SIMD3<Float>(
                        Float(m.gravity.x), Float(m.gravity.y), Float(m.gravity.z)
                    ),
                    userAcceleration: SIMD3<Float>(
                        Float(m.userAcceleration.x), Float(m.userAcceleration.y), Float(m.userAcceleration.z)
                    ),
                    rotationRate: SIMD3<Float>(
                        Float(m.rotationRate.x),
                        Float(m.rotationRate.y),
                        Float(m.rotationRate.z)
                    ),
                    orientation: transformOrientation,
                    controls: context.controls
                )
                self.submitMotion(accelerometer: sample.accelerometer, gyroscope: sample.gyroscope, gravity: sample.gravity, rotationFactors: sample.rotationFactors, screenOrientation: sample.screenOrientation, generation: generation, attachment: attachment, registration: registration)
            }
        }
    }
    
    func stopMotion() {
        endMotionRegistration()
        nativeController?.motion?.valueChangedHandler = nil
        nativeController?.motion?.sensorsActive = false
        
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }
    
    private func shouldSubmitMotion() -> Bool {
        guard !InGameInputSession.shared.isSuspended else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        
        guard now &- lastMotionSubmit >= motionSubmitInterval else { return false }
        
        lastMotionSubmit = now
        
        return true
    }
    
    /// 手机携带独立重力，完整采样在核心中原子保存；实体手柄没有该数据时继续提交自身传感器。
    private func submitMotion(accelerometer: SIMD3<Float>, gyroscope: SIMD3<Float>, gravity: SIMD3<Float>? = nil, rotationFactors: SIMD3<Float> = SIMD3(repeating: 1), screenOrientation: Int32? = nil, generation: UInt64, attachment: UInt64, registration: UInt64) {
        guard isActive, activeInputAttachment == attachment, activeMotionRegistration == registration,
              !InGameInputSession.shared.isSuspended else { return }
        
        let pointer = self.pointer
        
        motionQueue.async { [weak self] in
            guard let self, self.isActive, !InGameInputSession.shared.isSuspended else { return }
            
            // 与编辑会话的清空动作互斥，防止检查后才到达的旧帧重新写入运动状态。
            InGameInputSession.shared.performIfActive(generation: generation) {
                self.performIfInputAttached(generation: attachment, motionGeneration: registration) {
                    if let gravity, let screenOrientation {
                        Ryujinx.setGamepadPhoneMotionSample(pointer, acceleration: accelerometer, gyroscope: gyroscope, gravity: gravity, rotationFactors: rotationFactors, screenOrientation: screenOrientation)
                    } else {
                        Ryujinx.setGamepadMotion(pointer, motionType: 1, axis: accelerometer)
                        Ryujinx.setGamepadMotion(pointer, motionType: 2, axis: gyroscope)
                    }
                }
            }
        }
    }

    /// 同一主线程快照内读取方向和配置，避免一帧跨越两次主线程读取而混用新旧界面状态。
    private func currentPhoneMotionContext() -> (orientation: UIInterfaceOrientation, controls: PhoneMotionControls) {
        if Thread.isMainThread {
            return (currentMotionInterfaceOrientation(), PhoneMotionControls.read(from: NativeSettingsManager.shared))
        }
        return DispatchQueue.main.sync {
            (currentMotionInterfaceOrientation(), PhoneMotionControls.read(from: NativeSettingsManager.shared))
        }
    }
    
    /// 获取当前窗口的界面方向。方向变化后下一帧立即使用新矩阵，未知方向沿用上次有效值。
    private func currentMotionInterfaceOrientation() -> UIInterfaceOrientation {
        let sceneOrientation: UIInterfaceOrientation?
        if Thread.isMainThread {
            sceneOrientation = primaryMotionSceneOrientation()
        } else {
            sceneOrientation = DispatchQueue.main.sync {
                primaryMotionSceneOrientation()
            }
        }

        motionOrientationLock.lock()
        defer { motionOrientationLock.unlock() }
        if let sceneOrientation {
            motionInterfaceOrientation = sceneOrientation
        }
        return isUsableInterfaceOrientation(motionInterfaceOrientation) ? motionInterfaceOrientation : .portrait
    }

    /// 手机输入以主应用窗口为准；外接显示器的横屏方向不能覆盖手机竖屏方向。
    @MainActor private func primaryMotionSceneOrientation() -> UIInterfaceOrientation? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive && $0.windows.contains(where: { $0.isKeyWindow }) }
            ?? scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
        guard let orientation = scene?.interfaceOrientation, isUsableInterfaceOrientation(orientation) else { return nil }
        return orientation
    }

    private func isUsableInterfaceOrientation(_ orientation: UIInterfaceOrientation) -> Bool {
        switch orientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }

    nonisolated private func phoneMotionOrientation(_ orientation: UIInterfaceOrientation) -> PhoneMotionTransform.Orientation? {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }
}
