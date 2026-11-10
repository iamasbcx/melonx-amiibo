import Foundation

/// 常驻原生入口只持有此槽；替换时复制闭包引用，锁外调用，正在执行的旧闭包自然延长生命周期。
/// 槽本身不释放给 native 的地址；可变闭包仅由短锁保护，闭包必须满足跨线程捕获契约。
nonisolated final class CallbackHandlerSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Value) -> Void)?
    func replace(_ next: (@Sendable (Value) -> Void)?) {
        lock.lock()
        let previous = handler
        handler = next
        lock.unlock()
        // 捕获对象析构可能重入注册器，旧闭包必须在锁外释放。
        withExtendedLifetime(previous) {}
    }
    func invoke(_ value: Value) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(value)
    }
}

/// 仅主线程管理观察者，发送时复制列表，允许观察者在回调内撤销自身。
@MainActor final class RemovableObservers<Value> {
    private var handlers: [UUID: (Value) -> Void] = [:]
    var count: Int { handlers.count }
    func add(_ handler: @escaping (Value) -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }
    func remove(_ token: UUID) { handlers[token] = nil }
    func send(_ value: Value) {
        for handler in Array(handlers.values) { handler(value) }
    }
}

/// 应用级原生回调跨游戏复用；排队结果必须同时匹配活跃会话和捕获的代次。
nonisolated final class CallbackSessionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var active = false
    func begin() { lock.lock(); defer { lock.unlock() }; value &+= 1; active = true }
    func end() { lock.lock(); defer { lock.unlock() }; value &+= 1; active = false }
    func current() -> UInt64? { lock.lock(); defer { lock.unlock() }; return active ? value : nil }
    func accepts(_ expected: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return active && value == expected }
}
