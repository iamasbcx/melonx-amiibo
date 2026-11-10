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
    func setupMotion() {
        if let nativeController, nativeController.motion != nil, !self.usesDeviceHandlers {
            guard ControllerMappingStore.shared.runtimeMapping(for: self).motionEnabled else {
                nativeController.motion?.valueChangedHandler = nil
                nativeController.motion?.sensorsActive = false
                
                return
            }
            
            nativeController.motion?.sensorsActive = true
            
            // Thank you @BXYMartin :3
            nativeController.motion?.valueChangedHandler = { [weak self] m in
                guard let self = self else { return }
                
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
                
                self.submitMotion(accelerometer: accel, gyroscope: gyro, generation: generation)
            }
        } else {
            guard self.motionManager.isDeviceMotionAvailable else { return }
            
            self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60Hz
            _ = self.currentMotionInterfaceOrientation()
            self.motionManager.startDeviceMotionUpdates(to: self.motionOperation) { [weak self] (data, error) in
                guard let self = self, let m = data else { return }
                guard let generation = InGameInputSession.shared.activeGeneration,
                      self.shouldSubmitMotion() else { return }
                
                let interfaceOrientation = self.currentMotionInterfaceOrientation()
                guard let transformOrientation = self.phoneMotionOrientation(interfaceOrientation) else { return }
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
                    controls: self.currentPhoneMotionControls()
                )
                self.submitMotion(accelerometer: sample.accelerometer, gyroscope: sample.gyroscope, gravity: sample.gravity, rotationFactors: sample.rotationFactors, generation: generation)
            }
        }
    }
    
    func stopMotion() {
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
    private func submitMotion(accelerometer: SIMD3<Float>, gyroscope: SIMD3<Float>, gravity: SIMD3<Float>? = nil, rotationFactors: SIMD3<Float> = SIMD3(repeating: 1), generation: UInt64) {
        guard isActive, !InGameInputSession.shared.isSuspended else { return }
        
        let pointer = self.pointer
        
        motionQueue.async { [weak self] in
            guard self?.isActive == true, !InGameInputSession.shared.isSuspended else { return }
            
            // 与编辑会话的清空动作互斥，防止检查后才到达的旧帧重新写入运动状态。
            InGameInputSession.shared.performIfActive(generation: generation) {
                if let gravity {
                    Ryujinx.setGamepadMotionSample(pointer, acceleration: accelerometer, gyroscope: gyroscope, gravity: gravity, rotationFactors: rotationFactors)
                } else {
                    Ryujinx.setGamepadMotion(pointer, motionType: 1, axis: accelerometer)
                    Ryujinx.setGamepadMotion(pointer, motionType: 2, axis: gyroscope)
                }
            }
        }
    }

    /// 同一局始终读取当前游戏的覆盖及全局回退；设置改动从下一帧开始生效。
    private func currentPhoneMotionControls() -> PhoneMotionControls {
        if Thread.isMainThread {
            return PhoneMotionControls.read(from: NativeSettingsManager.shared)
        }
        return DispatchQueue.main.sync {
            PhoneMotionControls.read(from: NativeSettingsManager.shared)
        }
    }
    
    /// 获取当前窗口的界面方向。方向变化后下一帧立即使用新矩阵，未知方向沿用上次有效值。
    private func currentMotionInterfaceOrientation() -> UIInterfaceOrientation {
        let sceneOrientation: UIInterfaceOrientation?
        if Thread.isMainThread {
            sceneOrientation = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
                .first(where: { self.isUsableInterfaceOrientation($0) })
        } else {
            sceneOrientation = DispatchQueue.main.sync {
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
                    .first(where: { self.isUsableInterfaceOrientation($0) })
            }
        }

        motionOrientationLock.lock()
        defer { motionOrientationLock.unlock() }
        if let sceneOrientation {
            motionInterfaceOrientation = sceneOrientation
        }
        return isUsableInterfaceOrientation(motionInterfaceOrientation) ? motionInterfaceOrientation : .portrait
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
