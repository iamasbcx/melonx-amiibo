import CryptoKit
import Foundation
import Darwin

public nonisolated enum LANUploadConflictPolicy: String, Codable, Sendable {
    case ask, skip, replace
}

/// 上传协议快照。nextOffset 只包含已经同步到磁盘且元数据提交成功的字节。
public nonisolated struct LANUploadSessionSnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case uploading, paused, verifying, completed, cancelled, expired, failed, skipped
    }
    public let uploadID: UUID
    public let resumeToken: String
    public let destinationPath: String
    public let totalBytes: Int64
    public var nextOffset: Int64
    public let expectedSHA256: String?
    public let clientFingerprint: String?
    public let conflict: LANUploadConflictPolicy
    public let createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date
    public var state: State
    public var isResumable: Bool { state == .uploading || state == .paused }
}

/// 验证目标未被其他操作替换；inode 也用于恢复“rename 已成功、收据尚未写入”的窗口。
private nonisolated struct LANUploadFileVersion: Codable, Sendable, Equatable {
    let inode: UInt64
    let device: UInt64
    let size: Int64
    let modified: Date
}

private nonisolated struct LANUploadSessionRecord: Codable, Sendable {
    var snapshot: LANUploadSessionSnapshot
    let destinationVersion: LANUploadFileVersion?
    var committingVersion: LANUploadFileVersion?
}

public nonisolated enum LANUploadStoreError: LocalizedError, Sendable {
    case invalidPath, invalidSize, invalidSHA256, invalidChunkSize
    case sessionNotFound, sessionNotResumable, invalidResumeToken
    case offsetMismatch(expected: Int64, actual: Int64)
    case uploadTooLarge, destinationIsDirectory, destinationConflict, destinationChanged
    case checksumMismatch, insufficientStorage
    case incomplete(expected: Int64, actual: Int64)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "文件路径无效"
        case .invalidSize: return "文件大小无效（最大 256 GiB）"
        case .invalidSHA256: return "SHA-256 格式无效"
        case .invalidChunkSize: return "分片大小无效"
        case .sessionNotFound: return "上传会话不存在或已过期"
        case .sessionNotResumable: return "上传会话当前不可继续"
        case .invalidResumeToken: return "恢复凭据无效"
        case let .offsetMismatch(expected, actual): return "分片偏移不匹配，服务端期望 \(expected)，收到 \(actual)"
        case .uploadTooLarge: return "分片超过声明的文件大小"
        case .destinationIsDirectory: return "目标路径是目录"
        case .destinationConflict: return "目标文件已经存在"
        case .destinationChanged: return "上传期间目标文件已变化，请重新确认覆盖"
        case .checksumMismatch: return "SHA-256 校验失败"
        case .insufficientStorage: return "可用空间不足，请释放空间后重试"
        case let .incomplete(expected, actual): return "上传未完成，期望 \(expected) 字节，实际 \(actual) 字节"
        case let .fileSystem(message): return message
        }
    }
}

/// 串行拥有上传文件句柄。网络层分片后调用，内存占用与游戏总大小无关。
/// 临时文件和收据均位于 Documents 同卷；只有 complete 才会产生正式文件名。
public actor LANUploadStore {
    public static let minimumChunkSize: Int64 = 8 * 1024 * 1024
    /// 每个 HTTP 请求最多 500 MiB；接收与合并均使用磁盘临时文件及 1 MiB 缓冲。
    public static let maximumChunkSize: Int64 = 500 * 1024 * 1024
    public static let maximumFileSize: Int64 = 256 * 1024 * 1024 * 1024
    public static let defaultRetention: TimeInterval = 72 * 60 * 60

    private let rootDirectory: URL
    private let temporaryRoot: URL
    private let fileManager: FileManager
    private let retention: TimeInterval

    public init(rootDirectory: URL, fileManager: FileManager = .default,
                retention: TimeInterval = LANUploadStore.defaultRetention) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.temporaryRoot = self.rootDirectory.appendingPathComponent(".melo-transfer-temp", isDirectory: true)
        self.fileManager = fileManager
        self.retention = retention
        try fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        if (try? fileManager.attributesOfItem(atPath: self.temporaryRoot.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
            throw LANUploadStoreError.invalidPath
        }
        try fileManager.createDirectory(at: self.temporaryRoot, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    /// 创建前预检同名冲突与空间。覆盖也需要完整临时空间，不能把旧文件大小计为空闲空间。
    public func createSession(destinationPath: String, totalBytes: Int64, expectedSHA256: String? = nil,
                              conflict: LANUploadConflictPolicy = .ask, clientFingerprint: String? = nil,
                              resumeToken: String? = nil) throws -> LANUploadSessionSnapshot {
        try LANFileMutationLock.shared.withLock {
            try createLocked(destinationPath: destinationPath, totalBytes: totalBytes, expectedSHA256: expectedSHA256,
                             conflict: conflict, clientFingerprint: clientFingerprint, resumeToken: resumeToken)
        }
    }

    private func createLocked(destinationPath: String, totalBytes: Int64, expectedSHA256: String?,
                              conflict: LANUploadConflictPolicy, clientFingerprint: String?,
                              resumeToken: String?) throws -> LANUploadSessionSnapshot {
        guard totalBytes >= 0, totalBytes <= Self.maximumFileSize else { throw LANUploadStoreError.invalidSize }
        if let hash = expectedSHA256, !Self.isSHA256(hash) { throw LANUploadStoreError.invalidSHA256 }
        guard (clientFingerprint?.utf8.count ?? 0) <= 8192 else { throw LANUploadStoreError.invalidSize }
        let destination = try resolveUserPath(destinationPath)
        let version = try fileVersion(destination)
        if version != nil && conflict != .replace { throw LANUploadStoreError.destinationConflict }
        // 请求临时片与累计上传文件在合并时会短暂共存，预留额外一片空间。
        try checkFreeSpace(totalBytes + min(totalBytes, Self.maximumChunkSize))
        let now = Date()
        let snapshot = LANUploadSessionSnapshot(
            uploadID: UUID(), resumeToken: resumeToken ?? Self.randomToken(), destinationPath: destinationPath,
            totalBytes: totalBytes, nextOffset: 0, expectedSHA256: expectedSHA256?.lowercased(),
            clientFingerprint: clientFingerprint, conflict: conflict, createdAt: now, updatedAt: now,
            expiresAt: now.addingTimeInterval(retention), state: .uploading)
        let directory = sessionDirectory(snapshot.uploadID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        do {
            guard fileManager.createFile(atPath: partURL(snapshot.uploadID).path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw LANUploadStoreError.fileSystem("无法创建上传临时文件")
            }
            try persist(LANUploadSessionRecord(snapshot: snapshot, destinationVersion: version))
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return snapshot
    }

    public func session(uploadID: UUID, resumeToken: String) throws -> LANUploadSessionSnapshot {
        try LANFileMutationLock.shared.withLock { try loadRecord(uploadID, token: resumeToken).snapshot }
    }

    /// 顺序写入一片。响应丢失时客户端重新 GET nextOffset，不能盲目重发。
    @discardableResult
    public func appendChunk(uploadID: UUID, resumeToken: String, offset: Int64, data: Data) throws -> LANUploadSessionSnapshot {
        try LANFileMutationLock.shared.withLock {
            try appendDataLocked(uploadID: uploadID, resumeToken: resumeToken, offset: offset, data: data)
        }
    }

    private func appendDataLocked(uploadID: UUID, resumeToken: String, offset: Int64, data: Data) throws -> LANUploadSessionSnapshot {
        guard !data.isEmpty, Int64(data.count) <= Self.maximumChunkSize else { throw LANUploadStoreError.invalidChunkSize }
        var record = try loadRecord(uploadID, token: resumeToken)
        guard record.snapshot.isResumable else { throw LANUploadStoreError.sessionNotResumable }
        guard offset == record.snapshot.nextOffset else {
            throw LANUploadStoreError.offsetMismatch(expected: record.snapshot.nextOffset, actual: offset)
        }
        guard Int64(data.count) <= record.snapshot.totalBytes - offset else { throw LANUploadStoreError.uploadTooLarge }
        try checkFreeSpace(Int64(data.count))
        let handle = try FileHandle(forWritingTo: partURL(uploadID))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        record.snapshot.nextOffset += Int64(data.count)
        record.snapshot.state = record.snapshot.nextOffset == record.snapshot.totalBytes ? .paused : .uploading
        refresh(&record)
        try persist(record)
        return record.snapshot
    }

    /// 网络层拥有 fileURL 的临时文件及清理责任；本方法只顺序读取，不接管该文件。
    /// 完整 HTTP 分片才会调用此接口；500 MiB 中途断线时重传当前片，已确认的片不受影响。
    public func appendChunkFile(uploadID: UUID, resumeToken: String, offset: Int64,
                                fileURL: URL, byteCount: Int64) throws -> LANUploadSessionSnapshot {
        try LANFileMutationLock.shared.withLock {
            try appendFileLocked(uploadID: uploadID, resumeToken: resumeToken, offset: offset, fileURL: fileURL, byteCount: byteCount)
        }
    }

    private func appendFileLocked(uploadID: UUID, resumeToken: String, offset: Int64,
                                  fileURL: URL, byteCount: Int64) throws -> LANUploadSessionSnapshot {
        guard byteCount > 0, byteCount <= Self.maximumChunkSize else { throw LANUploadStoreError.invalidChunkSize }
        var record = try loadRecord(uploadID, token: resumeToken)
        guard record.snapshot.isResumable else { throw LANUploadStoreError.sessionNotResumable }
        guard offset == record.snapshot.nextOffset else {
            throw LANUploadStoreError.offsetMismatch(expected: record.snapshot.nextOffset, actual: offset)
        }
        guard byteCount <= record.snapshot.totalBytes - offset else { throw LANUploadStoreError.uploadTooLarge }
        guard try fileVersion(fileURL)?.size == byteCount else { throw LANUploadStoreError.invalidChunkSize }
        try checkFreeSpace(byteCount)
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partURL(uploadID))
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(offset))
        var remaining = byteCount
        while remaining > 0 {
            guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else {
                throw LANUploadStoreError.fileSystem("上传分片临时文件不完整")
            }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        try output.synchronize()
        record.snapshot.nextOffset += byteCount
        record.snapshot.state = record.snapshot.nextOffset == record.snapshot.totalBytes ? .paused : .uploading
        refresh(&record)
        try persist(record)
        return record.snapshot
    }

    /// 校验大小及可选的整文件 SHA-256，再通过同卷 rename 原子提交；完成收据可重复查询。
    public func complete(uploadID: UUID, resumeToken: String) throws -> LANUploadSessionSnapshot {
        try LANFileMutationLock.shared.withLock { try completeLocked(uploadID: uploadID, resumeToken: resumeToken) }
    }

    private func completeLocked(uploadID: UUID, resumeToken: String) throws -> LANUploadSessionSnapshot {
        var record = try loadRecord(uploadID, token: resumeToken)
        if record.snapshot.state == .completed { return record.snapshot }
        guard record.snapshot.isResumable else { throw LANUploadStoreError.sessionNotResumable }
        guard record.snapshot.nextOffset == record.snapshot.totalBytes else {
            throw LANUploadStoreError.incomplete(expected: record.snapshot.totalBytes, actual: record.snapshot.nextOffset)
        }
        let part = partURL(uploadID)
        if let hash = record.snapshot.expectedSHA256, try Self.sha256(part) != hash {
            throw LANUploadStoreError.checksumMismatch
        }
        let destination = try resolveUserPath(record.snapshot.destinationPath)
        guard try fileVersion(destination) == record.destinationVersion else { throw LANUploadStoreError.destinationChanged }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 先记下临时文件身份，再 rename。重启时可判定提交是否已经发生，无需重读 40 GiB。
        record.committingVersion = try fileVersion(part)
        record.snapshot.state = .verifying
        refresh(&record)
        try persist(record)
        let result = part.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else {
            record.snapshot.state = .paused
            try persist(record)
            throw LANUploadStoreError.fileSystem("提交上传文件失败，临时文件已保留")
        }
        record.snapshot.state = .completed
        refresh(&record)
        try persist(record)
        return record.snapshot
    }

    /// 仅删除任务临时文件；即使会话已完成也不会删除正式目标。
    public func cancel(uploadID: UUID, resumeToken: String) throws {
        try LANFileMutationLock.shared.withLock {
            _ = try loadRecord(uploadID, token: resumeToken)
            try fileManager.removeItem(at: sessionDirectory(uploadID))
        }
    }

    @discardableResult
    public func cleanupExpired(now: Date = Date()) throws -> Int {
        try LANFileMutationLock.shared.withLock { try cleanupLocked(now: now) }
    }

    private func cleanupLocked(now: Date) throws -> Int {
        let entries = try fileManager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: [.contentModificationDateKey])
        var removed = 0
        for directory in entries {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let metadata = directory.appendingPathComponent("session.melo-upload.json")
            let expiry: Date
            if let data = try? Data(contentsOf: metadata),
               let record = try? JSONDecoder().decode(LANUploadSessionRecord.self, from: data) {
                expiry = record.snapshot.expiresAt
            } else {
                let modified = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                expiry = modified.addingTimeInterval(retention)
            }
            if now >= expiry { try fileManager.removeItem(at: directory); removed += 1 }
        }
        return removed
    }

    private func loadRecord(_ id: UUID, token: String) throws -> LANUploadSessionRecord {
        guard let data = try? Data(contentsOf: metadataURL(id)) else { throw LANUploadStoreError.sessionNotFound }
        var record: LANUploadSessionRecord
        do { record = try JSONDecoder().decode(LANUploadSessionRecord.self, from: data) }
        catch { throw LANUploadStoreError.fileSystem("上传会话元数据无效，请重新上传") }
        guard record.snapshot.uploadID == id, record.snapshot.resumeToken == token else { throw LANUploadStoreError.invalidResumeToken }
        guard Date() < record.snapshot.expiresAt else { throw LANUploadStoreError.sessionNotFound }
        if record.snapshot.state == .verifying {
            if fileManager.fileExists(atPath: partURL(id).path) {
                record.snapshot.state = .paused
            } else {
                let destination = try resolveUserPath(record.snapshot.destinationPath)
                guard let expected = record.committingVersion, try fileVersion(destination) == expected else {
                    throw LANUploadStoreError.fileSystem("无法确认上次提交结果，请检查目标文件")
                }
                record.snapshot.state = .completed
            }
            try persist(record)
        }
        if record.snapshot.isResumable {
            guard let actual = try fileVersion(partURL(id))?.size else { throw LANUploadStoreError.sessionNotFound }
            guard actual >= record.snapshot.nextOffset else {
                throw LANUploadStoreError.fileSystem("上传临时文件损坏，请重新上传")
            }
            if actual > record.snapshot.nextOffset {
                // 分片已写盘、元数据未提交的尾部不得当成成功，只重传这一片。
                let handle = try FileHandle(forWritingTo: partURL(id))
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(record.snapshot.nextOffset))
                try handle.synchronize()
            }
        }
        return record
    }

    private func persist(_ record: LANUploadSessionRecord) throws {
        try JSONEncoder().encode(record).write(to: metadataURL(record.snapshot.uploadID), options: .atomic)
        let handle = try FileHandle(forWritingTo: metadataURL(record.snapshot.uploadID))
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func refresh(_ record: inout LANUploadSessionRecord) {
        record.snapshot.updatedAt = Date()
        record.snapshot.expiresAt = record.snapshot.updatedAt.addingTimeInterval(retention)
    }

    private func sessionDirectory(_ id: UUID) -> URL { temporaryRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func partURL(_ id: UUID) -> URL { sessionDirectory(id).appendingPathComponent("payload.melo-upload.part") }
    private func metadataURL(_ id: UUID) -> URL { sessionDirectory(id).appendingPathComponent("session.melo-upload.json") }

    private func resolveUserPath(_ value: String) throws -> URL {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 4096, parts.count <= 64,
              !value.contains("\0"), !value.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".melo-") && $0.utf8.count <= 255 }) else {
            throw LANUploadStoreError.invalidPath
        }
        var result = rootDirectory
        for part in parts {
            result.appendPathComponent(String(part))
            // attributesOfItem 使用 lstat，可识别指向不存在目标的悬空符号链接。
            if let attrs = try? fileManager.attributesOfItem(atPath: result.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw LANUploadStoreError.invalidPath }
        }
        return result
    }

    private func fileVersion(_ url: URL) throws -> LANUploadFileVersion? {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try fileManager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where (error.domain == NSCocoaErrorDomain &&
                                         (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)) ||
                                         (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw LANUploadStoreError.destinationIsDirectory }
        return LANUploadFileVersion(inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            device: (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: attrs[.modificationDate] as? Date ?? .distantPast)
    }

    private func checkFreeSpace(_ bytes: Int64) throws {
        let attrs = try fileManager.attributesOfFileSystem(forPath: rootDirectory.path)
        guard let available = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw LANUploadStoreError.fileSystem("无法读取可用存储空间")
        }
        guard bytes <= max(0, available - 16 * 1024 * 1024) else { throw LANUploadStoreError.insufficientStorage }
    }

    private static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
