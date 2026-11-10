import Foundation

/// 游戏内设置会话的输入屏障。UI 在主线程切换状态，后台手柄回调通过锁读取。
/// 使用 performIfActive 的写入与挂起互斥，因此释放按键后不会再落入已排队的按下事件。
/// 所有可变状态仅在 lock 内访问，因此允许后台队列共享此对象；闭包只能执行原生输入写入。
nonisolated final class InGameInputSession: @unchecked Sendable {
    static let shared = InGameInputSession()
    private let lock = NSLock()
    private var suspended = false
    private var generation: UInt64 = 0

    var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended
    }

    func setSuspended(_ value: Bool) {
        lock.lock()
        if suspended != value { generation &+= 1 }
        suspended = value
        lock.unlock()
    }

    /// 异步回调在读取传感器时捕获代次；恢复后到达的旧队列帧不得覆盖新会话。
    var activeGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return suspended ? nil : generation
    }

    func performIfActive(generation expectedGeneration: UInt64? = nil, _ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { return }
        if let expectedGeneration, expectedGeneration != generation { return }
        action()
    }
}
