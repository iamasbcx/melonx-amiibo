import Foundation

/// 记录服务端文件响应的发送状态。
///
/// 状态只表示 HTTP writer 是否完成发送，不表示浏览器已经把文件写入本地磁盘。
/// 每次请求都有递增 generation；旧连接即使晚于重试连接结束，也不能覆盖新状态。
nonisolated final class LANDownloadTracker: @unchecked Sendable {
    nonisolated enum State: String, Codable, Sendable {
        case waiting
        case sending
        case sent
        case failed
    }

    nonisolated struct Snapshot: Codable, Sendable {
        let downloadID: String
        let state: State
        let path: String?
        let error: String?
    }

    nonisolated enum BeginError: Error, Sendable {
        case pathMismatch
        case alreadySending
    }

    private nonisolated struct Entry {
        var path: String
        var state: State
        var generation: UInt64
        var updatedAt: Date
        var error: String?
    }

    nonisolated final class WriteLease: @unchecked Sendable {
        private weak var tracker: LANDownloadTracker?
        private let downloadID: String
        private let generation: UInt64
        private let lock = NSLock()
        private var finished = false

        fileprivate init(tracker: LANDownloadTracker, downloadID: String, generation: UInt64) {
            self.tracker = tracker
            self.downloadID = downloadID
            self.generation = generation
        }

        func markSent() {
            guard finishOnce() else { return }
            tracker?.finish(downloadID: downloadID, generation: generation, state: .sent, error: nil)
        }

        func markFailed(_ error: String = "连接发送失败") {
            guard finishOnce() else { return }
            tracker?.finish(downloadID: downloadID, generation: generation, state: .failed, error: error)
        }

        private func finishOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }

        deinit {
            markFailed("响应未完成")
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private let maximumEntries: Int
    private let retention: TimeInterval

    init(maximumEntries: Int = 256, retention: TimeInterval = 10 * 60) {
        self.maximumEntries = max(8, maximumEntries)
        self.retention = max(60, retention)
    }

    /// 登记一次 GET 发送。相同 ID 只能用于同一路径，Range 重试会生成新 generation。
    func begin(downloadID: String, path: String) throws -> WriteLease? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(now: Date())
        if let old = entries[downloadID], old.path != path { throw BeginError.pathMismatch }
        if entries[downloadID]?.state == .sending { throw BeginError.alreadySending }
        if entries[downloadID] == nil {
            guard makeRoomLocked() else { return nil }
        }
        generation &+= 1
        entries[downloadID] = Entry(path: path, state: .sending, generation: generation, updatedAt: Date(), error: nil)
        return WriteLease(tracker: self, downloadID: downloadID, generation: generation)
    }

    func snapshot(downloadID: String) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(now: Date())
        guard let entry = entries[downloadID] else {
            return Snapshot(downloadID: downloadID, state: .waiting, path: nil, error: nil)
        }
        return Snapshot(downloadID: downloadID, state: entry.state, path: entry.path, error: entry.error)
    }

    /// 停止 listener 时让当前发送失败；generation 保证旧连接退出不会覆盖后续新请求。
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        for id in entries.keys {
            guard entries[id]?.state == .sending else { continue }
            entries[id]?.state = .failed
            entries[id]?.generation = generation
            entries[id]?.updatedAt = Date()
            entries[id]?.error = "服务已停止"
        }
    }

    private func finish(downloadID: String, generation: UInt64, state: State, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[downloadID], entry.generation == generation, entry.state == .sending else { return }
        entry.state = state
        entry.error = error
        entry.updatedAt = Date()
        entries[downloadID] = entry
    }

    private func makeRoomLocked() -> Bool {
        guard entries.count >= maximumEntries else { return true }
        guard let candidate = entries.filter({ $0.value.state != .sending }).min(by: { $0.value.updatedAt < $1.value.updatedAt }) else {
            return false
        }
        entries.removeValue(forKey: candidate.key)
        return true
    }

    private func purgeExpiredLocked(now: Date) {
        entries = entries.filter { _, entry in
            entry.state == .sending || now.timeIntervalSince(entry.updatedAt) <= retention
        }
    }
}
