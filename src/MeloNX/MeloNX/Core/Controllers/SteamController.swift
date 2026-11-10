//
//  SteamController.swift
//  MeloNX
//
//  Created by Stossy11 on 02/10/2026.
//

import Foundation
import GameController

final class SteamController: NativeController {
    let peripheralID: UUID
    private let setMotionEnabled: (Bool) -> Void
    private let sendRumble: (RumbleData) -> Void
    
    override var name: String { "Steam Controller" }
    
    init(peripheralID: UUID, setMotionEnabled: @escaping (Bool) -> Void, sendRumble: @escaping (RumbleData) -> Void) {
        self.peripheralID = peripheralID
        self.setMotionEnabled = setMotionEnabled
        self.sendRumble = sendRumble
        super.init(nativeController: GCController.withExtendedGamepad())
        applyMapping(ControllerMappingStore.shared.runtimeMapping(for: self))
    }
    
    override func setupController() {
        applyMapping(ControllerMappingStore.shared.runtimeMapping(for: self))
        cool()
    }
    
    override func applyMapping(_ mapping: ControllerMapping) {
        super.applyMapping(mapping)
        if let attachment = activeInputAttachment, mapping.motionEnabled {
            if activeMotionRegistration == nil { _ = beginMotionRegistration(attachment: attachment) }
        } else {
            endMotionRegistration()
        }
        setMotionEnabled(activeInputAttachment != nil && mapping.motionEnabled)
    }
    
    override func refreshMotion() {
        guard let attachment = activeInputAttachment else { return }
        endMotionRegistration()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeInputAttachment == attachment else { return }
            if self.activeMapping.motionEnabled { _ = self.beginMotionRegistration(attachment: attachment) }
            self.setMotionEnabled(self.activeMapping.motionEnabled)
        }
    }

    override func stopInputSensors() {
        endMotionRegistration()
        setMotionEnabled(false)
        super.stopInputSensors()
    }
    
    func receive(_ state: SteamControllerState) {
        let generation = InGameInputSession.shared.activeGeneration
        let attachment = activeInputAttachment
        let motionRegistration = activeMotionRegistration
        inputQueue.async { [weak self] in
            guard let self, self.isActive, let pad = self.nativeController?.extendedGamepad else { return }
            // 编辑期间仍可捕获映射，但跨越挂起/恢复边界的旧帧不能重新进入游戏。
            guard InGameInputSession.shared.activeGeneration == generation,
                  self.activeInputAttachment == attachment else { return }
            let buttons: [(GCControllerButtonInput?, UInt32)] = [
                (pad.buttonA, 0x01), (pad.buttonB, 0x02),
                (pad.buttonX, 0x04), (pad.buttonY, 0x08),
                (pad.leftShoulder, 0x80000), (pad.rightShoulder, 0x200),
                (pad.leftThumbstickButton, 0x8000), (pad.rightThumbstickButton, 0x20),
                (pad.buttonMenu, 0x4000), (pad.buttonOptions, 0x40), (pad.buttonHome, 0x10000),
            ]
            
            for (button, mask) in buttons { button?.setValue(state.buttons & mask != 0 ? 1 : 0) }
            
            func pressed(_ mask: UInt32) -> Float { state.buttons & mask != 0 ? 1 : 0 }
            
            pad.dpad.setValueForXAxis(pressed(0x0800) - pressed(0x1000), yAxis: pressed(0x2000) - pressed(0x0400))
            
            pad.leftTrigger.setValue(state.leftTrigger)
            pad.rightTrigger.setValue(state.rightTrigger)
            pad.leftThumbstick.setValueForXAxis(state.stick.x, yAxis: state.stick.y)
            
            let right = state.rightStick
            
            pad.rightThumbstick.setValueForXAxis(right.x, yAxis: right.y)
            
            guard self.activeMapping.motionEnabled, let generation, let attachment, let motionRegistration else { return }

            InGameInputSession.shared.performIfActive(generation: generation) {
                self.performIfInputAttached(generation: attachment, motionGeneration: motionRegistration) {
                    if let accel = state.accelerometer {
                        Ryujinx.setGamepadMotion(self.pointer, motionType: 1, axis: accel)
                    }
                    if let gyro = state.gyroscope {
                        Ryujinx.setGamepadMotion(self.pointer, motionType: 2, axis: gyro)
                    }
                }
            }
        }
    }
    
    override func rumble(data: RumbleData) {
        guard isActive else { return }
        sendRumble(data)
    }
    
    override func cleanup() {
        super.cleanup()
        inputQueue.async { [self] in withExtendedLifetime(self) {} }
    }
}
