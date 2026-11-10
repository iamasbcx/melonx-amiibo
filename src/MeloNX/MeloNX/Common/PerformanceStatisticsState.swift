import Foundation

/// 统计包仍为 33 字节；FIFO 位于非对齐偏移 17，必须使用非对齐读取。
nonisolated struct PerformanceStatisticsSnapshot: Equatable, Sendable {
    let fps: Double
    let frameTime: Double
    let started: Bool
    let fifo: Double
    static let zero = Self(fps: 0, frameTime: 0, started: false, fifo: 0)

    static func read(_ pointer: UnsafeRawPointer, length: Int) -> Self? {
        guard length >= 33 else { return nil }
        func finite(_ offset: Int) -> Double {
            let value = pointer.loadUnaligned(fromByteOffset: offset, as: Double.self)
            return value.isFinite ? max(0, value) : 0
        }
        return Self(fps: finite(0), frameTime: finite(8),
                    started: pointer.load(fromByteOffset: 16, as: UInt8.self) != 0,
                    fifo: finite(17))
    }
}

/// native 回调线程只读取令牌，主线程切换会话；锁内不调用外部代码。
nonisolated final class PerformanceStatisticsSession: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    func begin() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        active = true
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        active = false
    }
    func current() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return active ? generation : nil
    }
    func accepts(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && generation == token
    }
}
