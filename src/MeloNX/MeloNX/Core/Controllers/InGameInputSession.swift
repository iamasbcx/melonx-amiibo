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

    /// 开始新游戏必须更换代次，即使上一状态已经开放，也不能接收旧游戏排队帧。
    func beginGame() {
        lock.lock()
        generation &+= 1
        suspended = false
        lock.unlock()
    }

    /// 退出先关闭写入屏障，再由控制器管理器解绑；重复结束同样使旧令牌失效。
    func endGame() {
        lock.lock()
        generation &+= 1
        suspended = true
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

/// 单设备绑定生命周期，独立于设备对象生命周期。固定虚拟手柄解绑后可再次绑定。
/// 只在锁内维护代次；闭包仅执行 native 输入写入，不得等待主线程或回调本对象。
nonisolated final class InputAttachmentState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var attached = false
    private var motionGeneration: UInt64 = 0
    private var motionRegistered = false

    var activeGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return attached ? generation : nil
    }

    var activeMotionGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return attached && motionRegistered ? motionGeneration : nil
    }

    @discardableResult
    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        attached = true
        motionGeneration &+= 1
        motionRegistered = false
        return generation
    }

    func end() {
        lock.lock()
        generation &+= 1
        attached = false
        motionGeneration &+= 1
        motionRegistered = false
        lock.unlock()
    }

    /// 运动注册单独换代；关闭陀螺仪不必解绑按键，但旧传感器回调必须失效。
    func beginMotion(generation expectedGeneration: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard attached, generation == expectedGeneration else { return nil }
        motionGeneration &+= 1
        motionRegistered = true
        return motionGeneration
    }

    func endMotion() {
        lock.lock()
        motionGeneration &+= 1
        motionRegistered = false
        lock.unlock()
    }

    func performIfActive(generation expectedGeneration: UInt64, motionGeneration expectedMotionGeneration: UInt64? = nil, _ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard attached, generation == expectedGeneration else { return }
        if let expectedMotionGeneration {
            guard motionRegistered, motionGeneration == expectedMotionGeneration else { return }
        }
        action()
    }
}
