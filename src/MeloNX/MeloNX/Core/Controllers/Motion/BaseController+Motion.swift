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
                
                let rawAccel = SIMD3<Float>(
                    -Float(m.gravity.x + m.userAcceleration.x),
                     -Float(m.gravity.y + m.userAcceleration.y),
                     -Float(m.gravity.z + m.userAcceleration.z)
                )
                
                let rawGyro = SIMD3<Float>(
                    Float(m.rotationRate.x),
                    -Float(m.rotationRate.y),
                    -Float(m.rotationRate.z)
                ) * (180.0 / .pi)
                
                let interfaceOrientation = self.currentMotionInterfaceOrientation()
                let (mappedAccel, mappedGyro) = self.remapToSwitchCoords(
                    accel: rawAccel,
                    gyro: rawGyro,
                    interfaceOrientation: interfaceOrientation
                )
                // NpadController 会继续执行固定的 GamepadDriver→Switch 换轴，
                // 这里先还原为 driver 坐标，避免同一方向矩阵被重复应用。
                let driverAccel = SIMD3<Float>(mappedAccel.x, mappedAccel.z, -mappedAccel.y)
                let driverGyro = SIMD3<Float>(mappedGyro.x, mappedGyro.z, -mappedGyro.y)
                self.submitMotion(accelerometer: driverAccel, gyroscope: driverGyro)
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
    
    /// 将固定的 iOS 界面坐标转换为 Switch 目标坐标，再由调用方转换为
    /// native GamepadDriver 坐标。坐标系只允许在这一处按界面方向旋转。
    /// UIInterfaceOrientation 与 UIDeviceOrientation 的横屏枚举相反，不能直接混用。
    private func remapToSwitchCoords(
        accel: SIMD3<Float>,
        gyro: SIMD3<Float>,
        interfaceOrientation: UIInterfaceOrientation
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        var finalAccel: SIMD3<Float>
        var finalGyro: SIMD3<Float>
        
        switch interfaceOrientation {
        case .landscapeLeft:
            // UI landscapeLeft 对应 UIDevice landscapeRight。
            finalAccel = SIMD3<Float>(-accel.y, accel.x, accel.z)
            finalGyro = SIMD3<Float>(-gyro.y, gyro.x, gyro.z)
        case .landscapeRight:
            // UI landscapeRight 对应 UIDevice landscapeLeft。
            finalAccel = SIMD3<Float>(accel.y, -accel.x, accel.z)
            finalGyro = SIMD3<Float>(gyro.y, -gyro.x, gyro.z)
        case .portraitUpsideDown:
            finalAccel = SIMD3<Float>(-accel.x, accel.z, accel.y)
            finalGyro = SIMD3<Float>(-gyro.x, gyro.z, gyro.y)
        default:
            finalAccel = SIMD3<Float>(accel.x, accel.z, -accel.y)
            finalGyro = SIMD3<Float>(gyro.x, gyro.z, -gyro.y)
        }
        
        return (finalAccel, finalGyro)
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
}
