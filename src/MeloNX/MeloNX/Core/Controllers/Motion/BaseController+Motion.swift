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
            guard ControllerMappingStore.shared.mapping(for: self).motionEnabled else {
                nativeController.motion?.valueChangedHandler = nil
                nativeController.motion?.sensorsActive = false
                
                return
            }
            
            nativeController.motion?.sensorsActive = true
            
            // Thank you @BXYMartin :3
            nativeController.motion?.valueChangedHandler = { [weak self] m in
                guard let self = self else { return }
                
                guard self.shouldSubmitMotion() else { return }
                
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
                
                self.submitMotion(accelerometer: accel, gyroscope: gyro)
            }
        } else {
            guard self.motionManager.isDeviceMotionAvailable else { return }
            
            self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60Hz
            _ = self.currentMotionInterfaceOrientation()
            self.motionManager.startDeviceMotionUpdates(to: self.motionOperation) { [weak self] (data, error) in
                guard let self = self, let m = data else { return }
                guard self.shouldSubmitMotion() else { return }
                
                let interfaceOrientation = self.currentMotionInterfaceOrientation()
                guard let transformOrientation = self.phoneMotionOrientation(interfaceOrientation) else { return }
                let sample = PhoneMotionTransform.driverSample(
                    acceleration: SIMD3<Float>(
                        Float(m.gravity.x + m.userAcceleration.x),
                        Float(m.gravity.y + m.userAcceleration.y),
                        Float(m.gravity.z + m.userAcceleration.z)
                    ),
                    rotationRate: SIMD3<Float>(
                        Float(m.rotationRate.x),
                        Float(m.rotationRate.y),
                        Float(m.rotationRate.z)
                    ),
                    orientation: transformOrientation
                )
                self.submitMotion(accelerometer: sample.accelerometer, gyroscope: sample.gyroscope)
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
        let now = DispatchTime.now().uptimeNanoseconds
        
        guard now &- lastMotionSubmit >= motionSubmitInterval else { return false }
        
        lastMotionSubmit = now
        
        return true
    }
    
    private func submitMotion(accelerometer: SIMD3<Float>, gyroscope: SIMD3<Float>) {
        guard isActive else { return }
        
        let pointer = self.pointer
        
        motionQueue.async { [weak self] in
            guard self?.isActive == true else { return }
            
            Ryujinx.setGamepadMotion(pointer, motionType: 1, axis: accelerometer)
            Ryujinx.setGamepadMotion(pointer, motionType: 2, axis: gyroscope)
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
