import Foundation

/// 主线程按到达顺序比较每份报告，不合并事件；快速按下和释放会分别产生两次变化。
nonisolated struct SteamInputDelta {
    nonisolated struct Epoch: Equatable, Sendable {
        let revision: UInt64
        let session: UInt64?
        let attachment: UInt64?
    }
    nonisolated struct Changes: Sendable {
        let buttons: UInt32
        let leftTrigger: Bool
        let rightTrigger: Bool
        let leftStick: Bool
        let rightStick: Bool
        var isEmpty: Bool { buttons == 0 && !leftTrigger && !rightTrigger && !leftStick && !rightStick }
    }
    private var previous: SteamControllerState?
    private var epoch: Epoch?
    init() {}
    mutating func update(_ state: SteamControllerState, epoch nextEpoch: Epoch) -> Changes {
        let old = epoch == nextEpoch ? previous : nil
        previous = state
        epoch = nextEpoch
        return Changes(buttons: old.map { $0.buttons ^ state.buttons } ?? UInt32.max,
            leftTrigger: old?.leftTrigger != state.leftTrigger, rightTrigger: old?.rightTrigger != state.rightTrigger,
            leftStick: old?.stick != state.stick, rightStick: old?.rightStick != state.rightStick)
    }
}

/// 映射切换可能来自设备管理队列；只交换代次，增量状态仍只由主线程拥有。
nonisolated final class SteamInputRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() { lock.lock(); value &+= 1; lock.unlock() }
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}
