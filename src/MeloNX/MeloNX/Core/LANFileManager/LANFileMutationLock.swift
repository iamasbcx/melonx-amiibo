import Foundation

/// 同步保护上传提交与文件管理写操作，避免两个 actor 同时检查并替换相同目标。
/// 持锁区间禁止 await；递归锁允许目录合并复用同一套路径验证。
nonisolated final class LANFileMutationLock: @unchecked Sendable {
    static let shared = LANFileMutationLock()
    private let lock = NSRecursiveLock()

    private init() {}

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
