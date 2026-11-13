//
//  LANFileSystemStore.swift
//  MeloNX
//
//  提供局域网文件管理需要的目录读取、创建、删除和移动操作。
//  所有路径只接受相对于 Documents 的路径，并逐级拒绝符号链接越界。
//

import CryptoKit
import Foundation
import Darwin

public nonisolated enum LANManagedFileKind: String, Codable, Sendable {
    case file
    case directory
}

public nonisolated struct LANManagedFileEntry: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: LANManagedFileKind
    public let size: Int64
    public let modifiedAt: Date
    public let isWritable: Bool
}

/// 删除或覆盖操作的短时确认凭据；凭据只保存在内存，服务重启后立即失效。
public nonisolated struct LANFileMutationConfirmation: Codable, Sendable {
    public let confirmationToken: String
    public let warning: String
    public let itemCount: Int64
    public let totalBytes: Int64
    public let expiresAt: Date
}

public nonisolated enum LANManagedFileConflictPolicy: String, Codable, Sendable {
    case ask
    case skip
    case replaceFile
    case mergeDirectory
    case replaceDirectory
}

public nonisolated enum LANFileSystemStoreError: LocalizedError, Sendable {
    case invalidPath
    case notFound
    case destinationExists
    case sourceEqualsDestination
    case destinationIsDirectory
    case sourceIsDirectory
    case invalidConflict
    case invalidConfirmation
    case targetChanged
    case cannotDeleteRoot
    case cannotMoveIntoSelf
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "文件路径无效"
        case .notFound: return "文件或目录不存在"
        case .destinationExists: return "目标已经存在"
        case .sourceEqualsDestination: return "源和目标不能相同"
        case .destinationIsDirectory: return "目标是目录"
        case .sourceIsDirectory: return "源是目录"
        case .invalidConflict: return "当前冲突策略不适用"
        case .invalidConfirmation: return "确认凭据无效或已过期"
        case .targetChanged: return "目标在确认后发生变化，请重新确认"
        case .cannotDeleteRoot: return "不能删除根目录"
        case .cannotMoveIntoSelf: return "不能移动到自身或子目录"
        case let .fileSystem(message): return message
        }
    }
}

/// Documents 根目录的串行文件系统访问层。
public actor LANFileSystemStore {
    private nonisolated enum NodeKind: Equatable { case file, directory, symbolicLink, unsupported }
    private nonisolated struct NodeInfo {
        let kind: NodeKind
        let bytes: Int64
        let fingerprint: String
    }
    private nonisolated struct FileSnapshot {
        var count: Int64 = 0
        var bytes: Int64 = 0
        var fingerprint = ""
    }
    private let rootURL: URL
    private let fileManager: FileManager
    private nonisolated enum ConfirmationAction { case delete, move }
    private nonisolated struct PendingConfirmation {
        let action: ConfirmationAction
        let sourcePath: String
        let destinationPath: String?
        let sourceFingerprint: String
        let destinationFingerprint: String?
        let conflict: LANManagedFileConflictPolicy?
        let expiresAt: Date
    }
    private var confirmations: [String: PendingConfirmation] = [:]

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true, attributes: nil)
    }

    public func list(relativePath: String = "") throws -> [LANManagedFileEntry] {
        let directory = try resolve(relativePath, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LANFileSystemStoreError.notFound
        }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isWritableKey], options: [])
        return try urls.compactMap { url in
            if url.lastPathComponent.hasPrefix(".melo-") { return nil }
            guard let info = try nodeInfo(url), info.kind == .file || info.kind == .directory else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isWritableKey])
            let kind: LANManagedFileKind = values.isDirectory == true ? .directory : .file
            let entryPath = self.relativePath(for: url)
            return LANManagedFileEntry(
                name: url.lastPathComponent,
                path: entryPath,
                kind: kind,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                isWritable: values.isWritable ?? false
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(relativePath: String) throws -> LANManagedFileEntry {
        let url = try resolve(relativePath, allowRoot: false)
        guard fileManager.fileExists(atPath: url.path) else { throw LANFileSystemStoreError.notFound }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isWritableKey])
        let kind: LANManagedFileKind = values.isDirectory == true ? .directory : .file
        return LANManagedFileEntry(
            name: url.lastPathComponent,
            path: self.relativePath(for: url),
            kind: kind,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast,
            isWritable: values.isWritable ?? false
        )
    }

    public func fileURL(relativePath: String) throws -> URL {
        let url = try resolve(relativePath, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LANFileSystemStoreError.notFound
        }
        guard !isDirectory.boolValue else { throw LANFileSystemStoreError.destinationIsDirectory }
        return url
    }

    public func makeDirectory(relativePath: String) throws {
        do {
            try LANFileMutationLock.shared.withLock {
                let url = try resolve(relativePath, allowRoot: false)
                if try nodeInfo(url) != nil { throw LANFileSystemStoreError.destinationExists }
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
            }
        }
        catch let error as LANFileSystemStoreError { throw error }
        catch { throw LANFileSystemStoreError.fileSystem("创建目录失败，请检查可用空间与目录权限") }
    }

    /// 生成删除确认信息并统计递归项目数量；根目录永远拒绝。
    public func prepareDelete(relativePath: String) throws -> LANFileMutationConfirmation {
        return try LANFileMutationLock.shared.withLock {
            let url = try resolve(relativePath, allowRoot: false)
            guard fileManager.fileExists(atPath: url.path) else { throw LANFileSystemStoreError.notFound }
            let summary = try snapshot(of: url)
            let token = Self.makeToken()
            let expires = Date().addingTimeInterval(300)
            confirmations[token] = PendingConfirmation(action: .delete, sourcePath: relativePath,
                                                        destinationPath: nil, sourceFingerprint: summary.fingerprint,
                                                        destinationFingerprint: nil, conflict: nil, expiresAt: expires)
            return LANFileMutationConfirmation(confirmationToken: token, warning: "删除后无法恢复，请确认目标路径和内容", itemCount: summary.count, totalBytes: summary.bytes, expiresAt: expires)
        }
    }

    /// 删除操作必须使用刚刚生成且尚未过期的确认凭据。
    public func delete(relativePath: String, confirmationToken: String? = nil) throws {
        do {
            try LANFileMutationLock.shared.withLock {
                let url = try resolve(relativePath, allowRoot: false)
                guard fileManager.fileExists(atPath: url.path) else { throw LANFileSystemStoreError.notFound }
                try consumeConfirmation(confirmationToken, action: .delete, sourcePath: relativePath, destinationPath: nil, sourceURL: url, destinationURL: nil)
                try fileManager.removeItem(at: url)
            }
        }
        catch let error as LANFileSystemStoreError { throw error }
        catch { throw LANFileSystemStoreError.fileSystem("删除失败，请检查目录权限后重试") }
    }

    /// 预检移动/覆盖，返回一次性确认凭据和覆盖提示。
    public func prepareMove(sourcePath: String, destinationPath: String, conflict: LANManagedFileConflictPolicy = .ask) throws -> LANFileMutationConfirmation {
        return try LANFileMutationLock.shared.withLock {
            let source = try resolve(sourcePath, allowRoot: false)
            let destination = try resolve(destinationPath, allowRoot: false)
            guard fileManager.fileExists(atPath: source.path) else { throw LANFileSystemStoreError.notFound }
            guard source != destination else { throw LANFileSystemStoreError.sourceEqualsDestination }
            if destination.path.hasPrefix(source.path + "/") || source.path.hasPrefix(destination.path + "/") { throw LANFileSystemStoreError.cannotMoveIntoSelf }
            let destinationExists = fileManager.fileExists(atPath: destination.path)
            // ask 是网页选择覆盖/合并策略之前的预检结果。
            if destinationExists && conflict == .ask { throw LANFileSystemStoreError.destinationExists }
            try validateMove(source: source, destination: destination, conflict: conflict)
            let summary = try snapshot(of: source)
            let token = Self.makeToken()
            let expires = Date().addingTimeInterval(300)
            confirmations[token] = PendingConfirmation(action: .move, sourcePath: sourcePath, destinationPath: destinationPath,
                                                        sourceFingerprint: summary.fingerprint, destinationFingerprint: destinationExists ? try snapshot(of: destination).fingerprint : nil, conflict: conflict, expiresAt: expires)
            return LANFileMutationConfirmation(confirmationToken: token,
                                                warning: destinationExists ? "目标已存在；合并保留其他项目并覆盖同名文件，整目录替换会删除原目录内容" : "确认移动文件或文件夹",
                                                itemCount: summary.count, totalBytes: summary.bytes, expiresAt: expires)
        }
    }

    /// 在同一卷内优先原子移动；覆盖目录只允许显式选择合并或整目录替换。
    public func move(sourcePath: String, destinationPath: String, conflict: LANManagedFileConflictPolicy = .ask, confirmationToken: String? = nil) throws {
        try LANFileMutationLock.shared.withLock {
            let source = try resolve(sourcePath, allowRoot: false)
            let destination = try resolve(destinationPath, allowRoot: false)
            guard fileManager.fileExists(atPath: source.path) else { throw LANFileSystemStoreError.notFound }
            guard source != destination else { throw LANFileSystemStoreError.sourceEqualsDestination }
            if destination.path.hasPrefix(source.path + "/") || source.path.hasPrefix(destination.path + "/") { throw LANFileSystemStoreError.cannotMoveIntoSelf }
            var sourceDirectory: ObjCBool = false
            var destinationDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: source.path, isDirectory: &sourceDirectory)
            let destinationExists = fileManager.fileExists(atPath: destination.path, isDirectory: &destinationDirectory)
            try validateMove(source: source, destination: destination, conflict: conflict)
            if destinationExists || confirmationToken != nil {
                try consumeConfirmation(confirmationToken, action: .move, sourcePath: sourcePath, destinationPath: destinationPath, sourceURL: source, destinationURL: destinationExists ? destination : nil, conflict: conflict)
            }
            try moveResolved(source: source, destination: destination, sourceDirectory: sourceDirectory.boolValue,
                             destinationExists: destinationExists, destinationDirectory: destinationDirectory.boolValue, conflict: conflict)
        }
    }

    private func moveResolved(source: URL, destination: URL, sourceDirectory: Bool, destinationExists: Bool, destinationDirectory: Bool, conflict: LANManagedFileConflictPolicy) throws {
        if !destinationExists {
            do { try fileManager.moveItem(at: source, to: destination) }
            catch { throw LANFileSystemStoreError.fileSystem("移动失败，请确认目标父目录存在且可写") }
            return
        }
        if conflict == .skip { return }
        if !sourceDirectory {
            guard !destinationDirectory else { throw LANFileSystemStoreError.destinationIsDirectory }
            switch conflict {
            case .ask: throw LANFileSystemStoreError.destinationExists
            case .skip: return
            case .replaceFile:
                do { _ = try fileManager.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: .usingNewMetadataOnly) }
                catch { throw LANFileSystemStoreError.fileSystem("替换文件失败，请检查目录权限后重试") }
            default: throw LANFileSystemStoreError.invalidConflict
            }
            return
        }
        guard destinationDirectory else { throw LANFileSystemStoreError.destinationIsDirectory }
        switch conflict {
        case .ask: throw LANFileSystemStoreError.destinationExists
        case .skip: return
        case .replaceDirectory:
            let backup = destination.deletingLastPathComponent().appendingPathComponent(".melo-move-backup-\(UUID().uuidString)")
            do {
                try fileManager.moveItem(at: destination, to: backup)
                do {
                    try fileManager.moveItem(at: source, to: destination)
                } catch {
                    do { try fileManager.moveItem(at: backup, to: destination) }
                    catch { throw LANFileSystemStoreError.fileSystem("替换目录失败且恢复未完成，请保留恢复目录 \(backup.lastPathComponent)") }
                    throw LANFileSystemStoreError.fileSystem("替换目录失败，原目标已恢复")
                }
                do { try fileManager.removeItem(at: backup) }
                catch { throw LANFileSystemStoreError.fileSystem("替换目录已完成，但清理备份失败：\(backup.lastPathComponent)") }
            } catch let error as LANFileSystemStoreError { throw error }
            catch { throw LANFileSystemStoreError.fileSystem("替换目录失败，请检查目录权限后重试") }
        case .mergeDirectory:
            try mergeDirectories(source: source, destination: destination)
        default: throw LANFileSystemStoreError.invalidConflict
        }
    }

    private func resolve(_ value: String, allowRoot: Bool) throws -> URL {
        guard !value.isEmpty || allowRoot,
              !value.hasPrefix("/"),
              !value.contains("\0"), !value.contains("\\") else { throw LANFileSystemStoreError.invalidPath }
        let components = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard allowRoot || !components.isEmpty,
              !components.contains("."), !components.contains(".."),
              !components.contains(where: { $0.hasPrefix(".melo-") }) else { throw LANFileSystemStoreError.invalidPath }
        var result = rootURL
        for component in components {
            result.appendPathComponent(component)
            if let info = try nodeInfo(result), info.kind == .symbolicLink || info.kind == .unsupported {
                throw LANFileSystemStoreError.invalidPath
            }
        }
        let standardized = result.standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard standardized.path == rootURL.path || standardized.path.hasPrefix(prefix) else { throw LANFileSystemStoreError.invalidPath }
        return standardized
    }

    private nonisolated struct MergeOperation {
        let source: URL
        let destination: URL
        let replacesFile: Bool
    }

    /// 合并先生成完整计划，再执行同卷重命名；同名文件先保留备份，正常错误路径可回滚。
    /// 这不是跨多文件的磁盘事务；App 被强制终止时可能保留 .melo-move-backup-* 恢复目录。
    private func mergeDirectories(source: URL, destination: URL) throws {
        var operations: [MergeOperation] = []
        var emptyDirectories: [URL] = []
        try planMerge(source: source, destination: destination, operations: &operations, emptyDirectories: &emptyDirectories)
        let backupRoot = rootURL.appendingPathComponent(".melo-move-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // 恢复清单只包含 Documents 相对路径，不泄露沙盒绝对路径；进程中断后用于人工核对。
        let manifest = operations.enumerated().map { index, operation in
            ["source": relativePath(for: operation.source), "destination": relativePath(for: operation.destination),
             "backup": operation.replacesFile ? String(index) : ""]
        }
        try JSONEncoder().encode(manifest).write(to: backupRoot.appendingPathComponent("recovery.json"), options: .atomic)
        var moved: [MergeOperation] = []
        var backups: [(target: URL, backup: URL)] = []
        var removedDirectories: [URL] = []
        do {
            for (index, operation) in operations.enumerated() {
                if operation.replacesFile {
                    let backup = backupRoot.appendingPathComponent(String(index))
                    try fileManager.moveItem(at: operation.destination, to: backup)
                    backups.append((target: operation.destination, backup: backup))
                }
                try fileManager.moveItem(at: operation.source, to: operation.destination)
                moved.append(operation)
            }
            // 子目录优先清理，源目录最后清理；记录已经移除的空目录用于正常错误回滚。
            for directory in emptyDirectories {
                try fileManager.removeItem(at: directory)
                removedDirectories.append(directory)
            }
        } catch {
            var failures = 0
            for directory in removedDirectories.reversed() {
                do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
                catch { failures += 1 }
            }
            for operation in moved.reversed() {
                do { try fileManager.moveItem(at: operation.destination, to: operation.source) }
                catch { failures += 1 }
            }
            for item in backups.reversed() {
                do { try fileManager.moveItem(at: item.backup, to: item.target) }
                catch { failures += 1 }
            }
            if failures == 0 {
                do { try fileManager.removeItem(at: backupRoot) }
                catch { failures += 1 }
            }
            let details = failures == 0 ? "已恢复原文件" : "回滚未完全成功，请保留恢复目录 \(backupRoot.lastPathComponent)"
            throw LANFileSystemStoreError.fileSystem("合并目录失败；\(details)")
        }
        do { try fileManager.removeItem(at: backupRoot) }
        catch { throw LANFileSystemStoreError.fileSystem("合并已完成，但恢复目录清理失败：\(backupRoot.lastPathComponent)") }
    }

    private func planMerge(source: URL, destination: URL, operations: inout [MergeOperation], emptyDirectories: inout [URL]) throws {
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            guard let sourceInfo = try nodeInfo(child), sourceInfo.kind == .file || sourceInfo.kind == .directory,
                  !child.lastPathComponent.hasPrefix(".melo-") else { throw LANFileSystemStoreError.invalidPath }
            if let targetInfo = try nodeInfo(target) {
                guard sourceInfo.kind == targetInfo.kind else { throw LANFileSystemStoreError.invalidConflict }
                if sourceInfo.kind == .directory {
                    try planMerge(source: child, destination: target, operations: &operations, emptyDirectories: &emptyDirectories)
                } else {
                    operations.append(MergeOperation(source: child, destination: target, replacesFile: true))
                }
            } else {
                operations.append(MergeOperation(source: child, destination: target, replacesFile: false))
            }
        }
        emptyDirectories.append(source)
    }

    private func relativePath(for url: URL) -> String {
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }

    /// 使用 lstat 读取链接本身，悬空符号链接也能被识别；仅 ENOENT/ENOTDIR 视为不存在。
    private func nodeInfo(_ url: URL) throws -> NodeInfo? {
        // 当前 actor 同时提供 stat(relativePath:) 方法；显式限定 Darwin，避免方法名遮住 C 结构体。
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let kind: NodeKind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .unsupported
        }
        let fingerprint = "\(info.st_dev)|\(info.st_ino)|\(info.st_mode)|\(info.st_size)|\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return NodeInfo(kind: kind, bytes: Int64(info.st_size), fingerprint: fingerprint)
    }

    /// 确认绑定整棵目录的元数据；文件内容变化会通过 size、mtime/ctime 纳秒或 inode 被识别。
    /// 不读取游戏文件内容，40 GiB 文件不会因确认弹窗被额外全量扫描。
    private func snapshot(of url: URL) throws -> FileSnapshot {
        var snapshot = FileSnapshot()
        var digest = SHA256()
        try accumulateSnapshot(url, relative: "", result: &snapshot, digest: &digest)
        snapshot.fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return snapshot
    }

    private func accumulateSnapshot(_ url: URL, relative: String, result: inout FileSnapshot, digest: inout SHA256) throws {
        guard let info = try nodeInfo(url) else { throw LANFileSystemStoreError.notFound }
        guard info.kind == .file || info.kind == .directory else { throw LANFileSystemStoreError.invalidPath }
        guard !url.lastPathComponent.hasPrefix(".melo-") else { throw LANFileSystemStoreError.invalidPath }
        let (count, countOverflow) = result.count.addingReportingOverflow(1)
        let (bytes, byteOverflow) = result.bytes.addingReportingOverflow(info.kind == .file ? max(0, info.bytes) : 0)
        guard !countOverflow, !byteOverflow else { throw LANFileSystemStoreError.fileSystem("目录统计超过可表示范围") }
        result.count = count
        result.bytes = bytes
        digest.update(data: Data("\(relative.utf8.count):\(relative)|\(info.fingerprint)\n".utf8))
        if info.kind == .directory {
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                try accumulateSnapshot(child, relative: childRelative, result: &result, digest: &digest)
            }
        }
    }

    private func validateMove(source: URL, destination: URL, conflict: LANManagedFileConflictPolicy) throws {
        guard let sourceInfo = try nodeInfo(source) else { throw LANFileSystemStoreError.notFound }
        guard let destinationInfo = try nodeInfo(destination) else { return }
        if conflict == .skip { return }
        if conflict == .ask { throw LANFileSystemStoreError.destinationExists }
        guard sourceInfo.kind == destinationInfo.kind else { throw LANFileSystemStoreError.invalidConflict }
        if sourceInfo.kind == .file {
            guard conflict == .replaceFile else { throw LANFileSystemStoreError.invalidConflict }
        } else {
            guard sourceInfo.kind == .directory, conflict == .mergeDirectory || conflict == .replaceDirectory else {
                throw LANFileSystemStoreError.invalidConflict
            }
        }
    }

    private func consumeConfirmation(_ token: String?, action: ConfirmationAction, sourcePath: String, destinationPath: String?, sourceURL: URL, destinationURL: URL?, conflict: LANManagedFileConflictPolicy? = nil) throws {
        confirmations = confirmations.filter { $0.value.expiresAt > Date() }
        guard let token, let pending = confirmations.removeValue(forKey: token), pending.action == action,
              pending.sourcePath == sourcePath, pending.destinationPath == destinationPath,
              pending.conflict == conflict, pending.expiresAt > Date() else {
            throw LANFileSystemStoreError.invalidConfirmation
        }
        let currentDestination = try destinationURL.map { try snapshot(of: $0).fingerprint }
        guard pending.sourceFingerprint == (try snapshot(of: sourceURL).fingerprint), pending.destinationFingerprint == currentDestination else {
            throw LANFileSystemStoreError.targetChanged
        }
    }

    private static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
