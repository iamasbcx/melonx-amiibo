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
    private let cancelRumble: () -> Void
    private let inputRevision = SteamInputRevision()
    // 差量状态只由主线程维护；GCController 的赋值和回调仍按原有 inputQueue 顺序执行。
    private var inputDelta = SteamInputDelta()
    private var buttonInputs: [(GCControllerButtonInput?, UInt32)] = []
    
    override var name: String { "Steam Controller" }
    
    init(peripheralID: UUID, setMotionEnabled: @escaping (Bool) -> Void, sendRumble: @escaping (RumbleData) -> Void, stopRumble: @escaping () -> Void) {
        self.peripheralID = peripheralID
        self.setMotionEnabled = setMotionEnabled
        self.sendRumble = sendRumble
        self.cancelRumble = stopRumble
        super.init(nativeController: GCController.withExtendedGamepad())
        if let pad = nativeController?.extendedGamepad {
            buttonInputs = [
                (pad.buttonA, 0x01), (pad.buttonB, 0x02), (pad.buttonX, 0x04), (pad.buttonY, 0x08),
                (pad.leftShoulder, 0x80000), (pad.rightShoulder, 0x200),
                (pad.leftThumbstickButton, 0x8000), (pad.rightThumbstickButton, 0x20),
                (pad.buttonMenu, 0x4000), (pad.buttonOptions, 0x40), (pad.buttonHome, 0x10000)
            ]
        }
        applyMapping(ControllerMappingStore.shared.runtimeMapping(for: self))
    }
    
    override func setupController() {
        applyMapping(ControllerMappingStore.shared.runtimeMapping(for: self))
        cool()
    }
    
    override func applyMapping(_ mapping: ControllerMapping) {
        super.applyMapping(mapping)
        inputRevision.advance()
        if let attachment = activeInputAttachment, mapping.motionEnabled, inputResourceActivity.activeGeneration != nil {
            if activeMotionRegistration == nil { _ = beginMotionRegistration(attachment: attachment) }
        } else {
            endMotionRegistration()
        }
        setMotionEnabled(activeInputAttachment != nil && mapping.motionEnabled && inputResourceActivity.activeGeneration != nil)
    }
    
    override func refreshMotion() {
        guard let attachment = activeInputAttachment else { return }
        endMotionRegistration()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeInputAttachment == attachment else { return }
            self.refreshMotionIfNeeded()
        }
    }

    override func refreshMotionIfNeeded() {
        guard let attachment = activeInputAttachment else { return }
        let enabled = activeMapping.motionEnabled && inputResourceActivity.activeGeneration != nil
        if enabled && activeMotionRegistration == nil { _ = beginMotionRegistration(attachment: attachment) }
        if !enabled {
            endMotionRegistration()
            performIfInputAttached(generation: attachment) { Ryujinx.suspendGamepadMotion(pointer) }
        }
        setMotionEnabled(enabled)
    }

    override func stopHaptics() {
        cancelRumble()
        super.stopHaptics()
    }

    override func stopInputSensors() {
        endMotionRegistration()
        setMotionEnabled(false)
        super.stopInputSensors()
    }
    
    override func beginCapture(_ onCapture: @escaping (CapturedInput) -> Void) {
        super.beginCapture(onCapture)
        inputRevision.advance()
    }

    /// BLE 按到达顺序进入主线程，完整保留按下和释放边沿；静止且无运动数据时不唤醒输入队列。
    /// 映射、会话或绑定变化必须重发状态，避免旧帧被拒绝后缓存仍将新会话首帧视为重复。
    func receive(_ state: SteamControllerState) {
        precondition(Thread.isMainThread)
        guard isActive else { return }
        let generation = InGameInputSession.shared.activeGeneration
        let attachment = activeInputAttachment
        let registration = activeMotionRegistration
        let revision = inputRevision.current
        let changes = inputDelta.update(state, epoch: .init(revision: revision, session: generation, attachment: attachment))
        let hasMotion = activeMapping.motionEnabled && generation != nil && attachment != nil && registration != nil &&
            (state.accelerometer != nil || state.gyroscope != nil)
        guard !changes.isEmpty || hasMotion else { return }
        inputQueue.async { [weak self] in
            guard let self, self.isActive, let pad = self.nativeController?.extendedGamepad,
                  InGameInputSession.shared.activeGeneration == generation,
                  self.activeInputAttachment == attachment, self.inputRevision.current == revision else { return }
            for (button, mask) in self.buttonInputs where changes.buttons & mask != 0 {
                button?.setValue(state.buttons & mask != 0 ? 1 : 0)
            }
            func pressed(_ mask: UInt32) -> Float { state.buttons & mask != 0 ? 1 : 0 }
            if changes.buttons & 0x3c00 != 0 {
                pad.dpad.setValueForXAxis(pressed(0x0800) - pressed(0x1000), yAxis: pressed(0x2000) - pressed(0x0400))
            }
            if changes.leftTrigger { pad.leftTrigger.setValue(state.leftTrigger) }
            if changes.rightTrigger { pad.rightTrigger.setValue(state.rightTrigger) }
            if changes.leftStick { pad.leftThumbstick.setValueForXAxis(state.stick.x, yAxis: state.stick.y) }
            if changes.rightStick { pad.rightThumbstick.setValueForXAxis(state.rightStick.x, yAxis: state.rightStick.y) }
            guard hasMotion, let generation, let attachment, let registration else { return }
            InGameInputSession.shared.performIfActive(generation: generation) {
                self.performIfInputAttached(generation: attachment, motionGeneration: registration) {
                    if let accel = state.accelerometer { Ryujinx.setGamepadMotion(self.pointer, motionType: 1, axis: accel) }
                    if let gyro = state.gyroscope { Ryujinx.setGamepadMotion(self.pointer, motionType: 2, axis: gyro) }
                }
            }
        }
    }

    override func rumble(data: RumbleData) {
        guard isActive, let attachment = activeInputAttachment,
              let generation = inputResourceActivity.activeGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeInputAttachment == attachment,
                  self.inputResourceActivity.activeGeneration == generation else { return }
            self.sendRumble(data)
        }
    }
    
    override func cleanup() {
        super.cleanup()
        inputQueue.async { [self] in withExtendedLifetime(self) {} }
    }
}
