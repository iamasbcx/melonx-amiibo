import Foundation

/// 在 macOS CI 上执行真实临时目录读写，覆盖上传中断和破坏性文件操作的关键契约。
@main
struct StoreChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LANStoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MeloNX-LAN-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let store = try LANUploadStore(rootDirectory: root)
        let bytes = Data("hello world".utf8)
        let task = try await store.createSession(destinationPath: "roms/中文.nsp", totalBytes: Int64(bytes.count), clientFingerprint: "sample")
        let first = try await store.appendChunk(uploadID: task.uploadID, resumeToken: task.resumeToken, offset: 0, data: bytes.prefix(5))
        try require(first.nextOffset == 5, "分片确认偏移错误")
        try require(!manager.fileExists(atPath: root.appendingPathComponent("roms/中文.nsp").path), "半成品泄露为正式文件")

        // 模拟写入成功但进度元数据尚未提交时崩溃；恢复必须截断额外尾部。
        let part = root.appendingPathComponent(".melo-transfer-temp/\(task.uploadID.uuidString)/payload.melo-upload.part")
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("uncommitted".utf8))
        try handle.close()
        let restarted = try LANUploadStore(rootDirectory: root)
        let resumed = try await restarted.session(uploadID: task.uploadID, resumeToken: task.resumeToken)
        let recoveredData = try Data(contentsOf: part)
        try require(resumed.nextOffset == 5 && recoveredData.count == 5, "中断尾部未截断")
        let incoming = root.appendingPathComponent("request.melo-request.part")
        try bytes.dropFirst(5).write(to: incoming)
        _ = try await restarted.appendChunkFile(uploadID: task.uploadID, resumeToken: task.resumeToken, offset: 5,
                                                fileURL: incoming, byteCount: Int64(bytes.count - 5))
        let completed = try await restarted.complete(uploadID: task.uploadID, resumeToken: task.resumeToken)
        try require(completed.state == .completed, "未返回完成状态")
        let repeated = try await restarted.complete(uploadID: task.uploadID, resumeToken: task.resumeToken)
        try require(repeated.state == .completed, "重复 complete 不幂等")
        try require(try Data(contentsOf: root.appendingPathComponent("roms/中文.nsp")) == bytes, "提交内容不一致")

        do {
            _ = try await store.createSession(destinationPath: "roms/中文.nsp", totalBytes: 1)
            try require(false, "未拒绝同名冲突")
        } catch LANUploadStoreError.destinationConflict {}
        for path in ["../escape", "/absolute", ".melo-transfer-temp/x", "a/../b", "a\\b"] {
            do {
                _ = try await store.createSession(destinationPath: path, totalBytes: 0)
                try require(false, "未拒绝危险路径：\(path)")
            } catch LANUploadStoreError.invalidPath {}
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("missing"))
        do {
            _ = try await store.createSession(destinationPath: "link/file", totalBytes: 0)
            try require(false, "未拒绝悬空符号链接")
        } catch LANUploadStoreError.invalidPath {}

        let replacement = try await store.createSession(destinationPath: "roms/中文.nsp", totalBytes: 0, conflict: .replace)
        try Data("changed".utf8).write(to: root.appendingPathComponent("roms/中文.nsp"), options: .atomic)
        do {
            _ = try await store.complete(uploadID: replacement.uploadID, resumeToken: replacement.resumeToken)
            try require(false, "未阻止覆盖上传期间变化的目标")
        } catch LANUploadStoreError.destinationChanged {}
        try await store.cancel(uploadID: replacement.uploadID, resumeToken: replacement.resumeToken)
        try require(try Data(contentsOf: root.appendingPathComponent("roms/中文.nsp")) == Data("changed".utf8), "取消破坏了正式文件")

        let fs = try LANFileSystemStore(rootURL: root)
        try await fs.makeDirectory(relativePath: "new")
        let list = try await fs.list()
        try require(!list.contains(where: { $0.name.hasPrefix(".melo-") }), "内部临时目录可见")
        do {
            try await fs.delete(relativePath: "new")
            try require(false, "删除未要求确认")
        } catch LANFileSystemStoreError.invalidConfirmation {}
        let confirmation = try await fs.prepareDelete(relativePath: "new")
        try await fs.delete(relativePath: "new", confirmationToken: confirmation.confirmationToken)
        try require(!manager.fileExists(atPath: root.appendingPathComponent("new").path), "目录删除失败")

        try await fs.makeDirectory(relativePath: "source")
        try await fs.makeDirectory(relativePath: "target")
        try Data("new".utf8).write(to: root.appendingPathComponent("source/same"))
        try Data("old".utf8).write(to: root.appendingPathComponent("target/same"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("target/keep"))
        let move = try await fs.prepareMove(sourcePath: "source", destinationPath: "target", conflict: .mergeDirectory)
        do {
            try await fs.move(sourcePath: "source", destinationPath: "target", conflict: .replaceDirectory,
                              confirmationToken: move.confirmationToken)
            try require(false, "确认凭据允许升级为整体替换")
        } catch LANFileSystemStoreError.invalidConfirmation {}
        let merge = try await fs.prepareMove(sourcePath: "source", destinationPath: "target", conflict: .mergeDirectory)
        try await fs.move(sourcePath: "source", destinationPath: "target", conflict: .mergeDirectory,
                          confirmationToken: merge.confirmationToken)
        try require(try Data(contentsOf: root.appendingPathComponent("target/same")) == Data("new".utf8), "目录合并未覆盖同名文件")
        try require(try Data(contentsOf: root.appendingPathComponent("target/keep")) == Data("keep".utf8), "目录合并破坏目标其他文件")
        try require(!manager.fileExists(atPath: root.appendingPathComponent("source").path), "目录合并残留原目录")
        let staleDelete = try await fs.prepareDelete(relativePath: "target")
        try Data("changed".utf8).write(to: root.appendingPathComponent("target/keep"))
        do {
            try await fs.delete(relativePath: "target", confirmationToken: staleDelete.confirmationToken)
            try require(false, "删除确认没有检测子文件变化")
        } catch LANFileSystemStoreError.targetChanged {}
        print("LAN 存储检查通过：续传、尾部恢复、磁盘分片、幂等提交、路径、删除确认与目录合并")
    }
}
