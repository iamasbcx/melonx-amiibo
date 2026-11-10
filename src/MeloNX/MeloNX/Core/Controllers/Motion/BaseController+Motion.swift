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
            // 只在启动采样时读取一次界面方向。不能在每个传感器回调中读取
            // UIDeviceOrientation，否则设备短暂处于 faceUp/portrait 时会切换坐标矩阵。
            let interfaceOrientation = self.captureMotionInterfaceOrientation()
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
                
                let (mappedAccel, mappedGyro) = self.remapToSwitchCoords(
                    accel: rawAccel,
                    gyro: rawGyro,
                    interfaceOrientation: interfaceOrientation
                )
                // NpadController 仍会把 GamepadDriver 坐标转换为 Switch 坐标，
                // 这里传入其逆变换，避免手机路径重复换轴。
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
    
    /// 在采样开始时获取稳定的界面方向。这里显式把设备方向转换为界面方向，
    /// 后续采样不再根据设备物理姿态切换矩阵，避免游戏锁定横屏时坐标轴跳变。
    private func captureMotionInterfaceOrientation() -> UIInterfaceOrientation {
        let deviceOrientation = UIDevice.current.orientation.isValidInterfaceOrientation
            ? UIDevice.current.orientation
            : orientation

        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            // UIDeviceOrientation.landscapeLeft 对应 UIInterfaceOrientation.landscapeRight。
            return .landscapeRight
        case .landscapeRight:
            // UIDeviceOrientation.landscapeRight 对应 UIInterfaceOrientation.landscapeLeft。
            return .landscapeLeft
        default:
            return .landscapeRight
        }
    }
}
