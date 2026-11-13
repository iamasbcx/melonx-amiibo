import Foundation
import NanoHTTP

/// 局域网文件管理的 HTTP 入口。生命周期由主线程协调，网络请求在 NanoHTTP 连接线程执行。
/// 文件操作交给两个存储 actor；同步桥仅阻塞连接线程，不把大文件加载进内存。
nonisolated final class LANFileServer: @unchecked Sendable {
    private let fileStore: LANFileSystemStore
    private let uploadStore: LANUploadStore
    private let downloadTracker = LANDownloadTracker()
    private let incomingBodyDirectory: URL
    private let token = LANFileServer.makeToken()
    private let stateLock = NSLock()
    private var server: NanoHTTPServer?
    private var lastPort: UInt16 = 8080
    private var addressValue: URL?

    var address: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return addressValue
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return server?.operating == true
    }

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        uploadStore = try LANUploadStore(rootDirectory: rootURL, fileManager: fileManager)
        fileStore = try LANFileSystemStore(rootURL: rootURL, fileManager: fileManager)
        let requests = rootURL.appendingPathComponent(".melo-transfer-temp", isDirectory: true).appendingPathComponent("requests", isDirectory: true)
        if let attributes = try? fileManager.attributesOfItem(atPath: requests.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw LANFileServerError.invalidTemporaryDirectory
        }
        try fileManager.createDirectory(at: requests, withIntermediateDirectories: true)
        incomingBodyDirectory = requests.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: incomingBodyDirectory, withIntermediateDirectories: false)
        // 每个实例使用独立目录；这里只清理至少一天未修改的旧目录，避免触碰刚停止实例的收尾任务。
        for candidate in try fileManager.contentsOfDirectory(at: requests, includingPropertiesForKeys: [.contentModificationDateKey]) {
            guard candidate != incomingBodyDirectory,
                  let modified = try candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < Date().addingTimeInterval(-24 * 60 * 60) else { continue }
            try fileManager.removeItem(at: candidate)
        }
    }

    /// 同一对象重新启动时优先复用端口，使后台返回后浏览器仍能访问原始 origin。
    /// token 放在 URL fragment 中，不会随 HTTP 请求或 Referer 发送。
    @discardableResult
    func start() throws -> URL {
        stateLock.lock()
        if let server, server.operating, let addressValue {
            stateLock.unlock()
            return addressValue
        }
        let preferredPort = lastPort
        stateLock.unlock()

        try Self.waitForActor { [uploadStore] in _ = try await uploadStore.cleanupExpired() }
        let http = NanoHTTPServer()
        http.configuration.listenAddress = .allInterfaces
        http.configuration.originPolicy = .sameOrigin
        http.configuration.maxConnections = 4
        http.configuration.limits.maxBodyBytes = Int(LANUploadStore.maximumChunkSize)
        http.configuration.readTimeout = 60
        http.configuration.writeTimeout = 60
        http.configuration.requestBodyPolicy = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable("Service is unavailable") }
            if request.rawPath.hasPrefix("/api/") && request.rawPath != "/api/v1/auth" && !self.authorized(request) {
                throw NanoHTTPError.unauthorized("Missing or invalid session token")
            }
            return try self.bodyStorage(for: request)
        }
        http.errorHandler = { error, _ in Self.errorResponse(error) }
        http.middleware.append { [weak self] request, next in
            guard let self else { throw NanoHTTPError.serviceUnavailable("Service is unavailable") }
            if request.rawPath.hasPrefix("/api/"), request.rawPath != "/api/v1/auth", !self.authorized(request) {
                throw NanoHTTPError.unauthorized("Missing or invalid session token")
            }
            var response = try next(request)
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
            return response
        }
        registerRoutes(on: http)
        do { try http.start(preferredPort) }
        catch {
            guard preferredPort != 0 else { throw error }
            try http.start(0)
        }
        let port = try http.port()
        guard let ip = NanoNetworkInterface.localIP,
              let url = URL(string: "http://\(Self.urlHost(ip)):\(port)/#token=\(token)") else {
            http.stop()
            throw LANFileServerError.noLocalAddress
        }
        stateLock.lock()
        server = http
        lastPort = UInt16(port)
        addressValue = url
        stateLock.unlock()
        return url
    }

    /// 关闭 listener 和现有连接；上传临时文件保留，下次启动仍可查询已确认偏移。
    func stop() {
        downloadTracker.stop()
        stateLock.lock()
        let previous = server
        server = nil
        addressValue = nil
        stateLock.unlock()
        previous?.stop()
    }

    private func registerRoutes(on http: NanoHTTPServer) {
        http.get["/"] = { _ in .ok(.html(LANWebBundle.html)) }
        http.get["/app.js"] = { _ in .ok(.data(Data(LANWebBundle.javascript.utf8), contentType: "application/javascript; charset=utf-8")) }
        http.get["/app.css"] = { _ in .ok(.data(Data(LANWebBundle.css.utf8), contentType: "text/css; charset=utf-8")) }
        http.post["/api/v1/auth"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(AuthBody.self)
            guard body.token == self.token else { throw NanoHTTPError.unauthorized("Invalid session token") }
            return .ok(headers: ["Set-Cookie": "melo_session=\(self.token); Path=/; HttpOnly; SameSite=Strict"], .json(["authenticated": true]))
        }
        http.get["/api/v1/status"] = { [weak self] _ in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            return .ok(.json(["running": self.isRunning, "root": "Documents", "resumableUploads": true, "chunkSize": LANUploadStore.maximumChunkSize]))
        }
        http.get["/api/v1/transfers/downloads/:downloadID"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let downloadID = request.params["downloadID"] ?? ""
            guard UUID(uuidString: downloadID) != nil else { throw NanoHTTPError.badRequest("downloadID is invalid") }
            return Self.jsonResponse(self.downloadTracker.snapshot(downloadID: downloadID))
        }
        http.get["/api/v1/files/list"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let path = request.query("path") ?? ""
            let entries = try Self.waitForActor { [fileStore] in try await fileStore.list(relativePath: path) }
            return Self.jsonResponse(FileList(path: path, entries: entries))
        }
        http.get["/api/v1/files/stat"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let path = request.query("path") ?? ""
            let entry = try Self.waitForActor { [fileStore] in try await fileStore.stat(relativePath: path) }
            return Self.jsonResponse(entry)
        }
        http.post["/api/v1/files/mkdir"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(PathBody.self)
            try Self.waitForActor { [fileStore] in try await fileStore.makeDirectory(relativePath: body.path) }
            return .ok(.json(["created": true]))
        }
        http.post["/api/v1/files/delete/prepare"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(PathBody.self)
            let confirmation = try Self.waitForActor { [fileStore] in try await fileStore.prepareDelete(relativePath: body.path) }
            return Self.jsonResponse(confirmation)
        }
        http.delete["/api/v1/files/item"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(DeleteBody.self)
            try Self.waitForActor { [fileStore] in try await fileStore.delete(relativePath: body.path, confirmationToken: body.confirmationToken) }
            return .ok(.json(["deleted": true]))
        }
        http.post["/api/v1/files/move/prepare"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(MoveBody.self)
            let confirmation = try Self.waitForActor { [fileStore] in
                try await fileStore.prepareMove(sourcePath: body.sourcePath, destinationPath: body.destinationPath, conflict: body.conflict ?? .ask)
            }
            return Self.jsonResponse(confirmation)
        }
        http.post["/api/v1/files/move"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(MoveBody.self)
            try Self.waitForActor { [fileStore] in
                try await fileStore.move(sourcePath: body.sourcePath, destinationPath: body.destinationPath,
                                         conflict: body.conflict ?? .ask, confirmationToken: body.confirmationToken)
            }
            return .ok(.json(["moved": true]))
        }
        http.get["/api/v1/files/download"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            return try self.fileResponse(request, preview: false)
        }
        http.get["/api/v1/files/open"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            return try self.fileResponse(request, preview: true)
        }
        // NanoHTTP 自动把 HEAD 路由到 GET，并在发送阶段丢弃响应体，不会读取完整文件。
        http.post["/api/v1/transfers/uploads"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let body = try request.json(CreateUploadBody.self)
            let snapshot = try Self.waitForActor { [uploadStore] in
                try await uploadStore.createSession(destinationPath: body.path, totalBytes: body.size,
                                                     expectedSHA256: body.sha256, conflict: body.conflict ?? .ask,
                                                     clientFingerprint: body.clientFingerprint)
            }
            return Self.jsonResponse(snapshot)
        }
        http.get["/api/v1/transfers/uploads/:uploadID"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let (id, resumeToken) = try self.uploadCredentials(request)
            return Self.jsonResponse(try Self.waitForActor { [uploadStore] in try await uploadStore.session(uploadID: id, resumeToken: resumeToken) })
        }
        http.put["/api/v1/transfers/uploads/:uploadID"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            return try self.appendUpload(request)
        }
        http.post["/api/v1/transfers/uploads/:uploadID/complete"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let (id, resumeToken) = try self.uploadCredentials(request)
            return Self.jsonResponse(try Self.waitForActor { [uploadStore] in try await uploadStore.complete(uploadID: id, resumeToken: resumeToken) })
        }
        http.delete["/api/v1/transfers/uploads/:uploadID"] = { [weak self] request in
            guard let self else { throw NanoHTTPError.serviceUnavailable() }
            let (id, resumeToken) = try self.uploadCredentials(request)
            try Self.waitForActor { [uploadStore] in try await uploadStore.cancel(uploadID: id, resumeToken: resumeToken) }
            return .ok(.json(["cancelled": true]))
        }
    }

    private func fileResponse(_ request: NanoHTTPRequest, preview: Bool) throws -> NanoHTTPResponse {
        let path = request.query("path") ?? ""
        let lease: LANDownloadTracker.WriteLease?
        if request.method == "GET", let downloadID = request.query("downloadID") {
            guard UUID(uuidString: downloadID) != nil else { throw NanoHTTPError.badRequest("downloadID is invalid") }
            do {
                // 状态表容量满且全部条目都在发送时，不阻断实际下载；该 ID 查询会保持 waiting。
                lease = try downloadTracker.begin(downloadID: downloadID, path: path)
            } catch LANDownloadTracker.BeginError.pathMismatch {
                throw NanoHTTPError.conflict("downloadID is bound to another path")
            } catch LANDownloadTracker.BeginError.alreadySending {
                throw NanoHTTPError.conflict("downloadID is already sending")
            }
        } else {
            // HEAD 只查询元数据；不得将它当作下载开始或完成。
            lease = nil
        }
        let url = try Self.waitForActor { [fileStore] in try await fileStore.fileURL(relativePath: path) }
        // NanoFiles 打开后持有文件描述符，原路径被替换时不会把新旧内容拼接到同一响应。
        var response = try NanoFiles.share(file: url.path)(request)
        let safeInline = ["txt", "log", "json", "csv", "png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased())
        let disposition = preview && safeInline ? "inline" : "attachment"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let name = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowed) ?? "download"
        response.headers["Content-Disposition"] = "\(disposition); filename*=UTF-8''\(name)"
        if case .custom(let writer, let type) = response.body {
            let contentType = preview && safeInline ? (["txt", "log", "json", "csv"].contains(url.pathExtension.lowercased()) ? "text/plain; charset=utf-8" : type) : "application/octet-stream"
            if let lease, let header = response.headers["Content-Length"], let expectedLength = Int64(header), expectedLength >= 0 {
                let fullRange = response.headers["Content-Range"].flatMap(Self.parseRange)
                let isFullResponse = response.statusCode == 200 || (response.statusCode == 206 && fullRange.map { $0.start == 0 && $0.end == $0.total - 1 } == true)
                // 持有 lease 的响应若在写头失败时被丢弃，lease.deinit 会把任务标记为失败。
                response.body = .custom({ output in
                    do {
                        // 保留 NanoHTTP 的原生文件发送；其短写会抛错，避免重复缓冲大文件。
                        try writer(output)
                        if isFullResponse {
                            lease.markSent()
                        } else {
                            // 部分 Range 正文发送成功不代表整个文件已发送，目录队列必须暂停。
                            lease.markFailed("只发送了部分范围，请在浏览器确认下载")
                        }
                    } catch {
                        lease.markFailed("文件读取或连接发送失败")
                        throw error
                    }
                }, contentType: contentType)
            } else {
                lease?.markFailed("下载响应缺少有效长度")
                response.body = .custom(writer, contentType: contentType)
            }
        } else {
            // 404/416/304 不发送完整文件正文，不能推进下载队列。
            lease?.markFailed("服务器未返回可下载的文件正文")
        }
        return response
    }

    private func appendUpload(_ request: NanoHTTPRequest) throws -> NanoHTTPResponse {
        defer { request.disposeBodyFile() }
        let (id, resumeToken) = try uploadCredentials(request)
        guard let header = request.header("content-range"), let range = Self.parseRange(header),
              range.end - range.start + 1 == request.bodyLength,
              let bodyURL = request.bodyFileURL else {
            throw NanoHTTPError.badRequest("Content-Range is invalid or does not match body length")
        }
        let byteCount = request.bodyLength
        let snapshot = try Self.waitForActor { [uploadStore] in
            let current = try await uploadStore.session(uploadID: id, resumeToken: resumeToken)
            guard current.totalBytes == range.total else { throw NanoHTTPError.conflict("Content-Range total does not match upload session") }
            return try await uploadStore.appendChunkFile(uploadID: id, resumeToken: resumeToken, offset: range.start,
                                                         fileURL: bodyURL, byteCount: byteCount)
        }
        return Self.jsonResponse(snapshot)
    }

    private func uploadCredentials(_ request: NanoHTTPRequest) throws -> (UUID, String) {
        guard let id = UUID(uuidString: request.params["uploadID"] ?? ""), let value = request.header("x-resume-token"), !value.isEmpty else {
            throw NanoHTTPError.badRequest("uploadID and X-Resume-Token are required")
        }
        return (id, value)
    }

    /// 在接收正文前验证分片身份、长度和偏移。其他 API 最多接收 1 MiB JSON，不能借大分片上限耗尽内存。
    private func bodyStorage(for request: NanoHTTPRequest) throws -> NanoHTTPRequestBodyStorage {
        let prefix = "/api/v1/transfers/uploads/"
        guard request.method == "PUT", request.rawPath.hasPrefix(prefix) else { return .memory(maxBytes: 1024 * 1024) }
        guard let id = UUID(uuidString: String(request.rawPath.dropFirst(prefix.count))),
              let resumeToken = request.header("x-resume-token"), let header = request.header("content-range"),
              let range = Self.parseRange(header), let lengthText = request.header("content-length"),
              let length = Int64(lengthText), length > 0, length <= LANUploadStore.maximumChunkSize,
              length == range.end - range.start + 1 else {
            throw NanoHTTPError.badRequest("Invalid upload headers or chunk length")
        }
        do {
            let snapshot = try Self.waitForActor { [uploadStore] in try await uploadStore.session(uploadID: id, resumeToken: resumeToken) }
            guard snapshot.totalBytes == range.total, snapshot.nextOffset == range.start, snapshot.isResumable else {
                throw NanoHTTPError.conflict("Upload offset or total changed; query the session again")
            }
        } catch {
            throw NanoHTTPError(status: Self.errorResponse(error).statusCode, message: "Upload session does not accept this chunk")
        }
        let capacity = try incomingBodyDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < length + 16 * 1024 * 1024 {
            throw NanoHTTPError(status: 507, message: "Insufficient storage for incoming chunk")
        }
        return .file(directory: incomingBodyDirectory, maxBytes: Int(LANUploadStore.maximumChunkSize))
    }

    private func authorized(_ request: NanoHTTPRequest) -> Bool {
        if request.header("authorization") == "Bearer " + token { return true }
        return request.header("cookie")?.split(separator: ";").contains {
            $0.trimmingCharacters(in: .whitespaces) == "melo_session=" + token
        } == true
    }

    private nonisolated struct AuthBody: Decodable, Sendable { let token: String }
    private nonisolated struct PathBody: Decodable, Sendable { let path: String }
    private nonisolated struct DeleteBody: Decodable, Sendable { let path: String; let confirmationToken: String }
    private nonisolated struct MoveBody: Decodable, Sendable {
        let sourcePath: String
        let destinationPath: String
        let conflict: LANManagedFileConflictPolicy?
        let confirmationToken: String?
    }
    private nonisolated struct CreateUploadBody: Decodable, Sendable {
        let path: String
        let size: Int64
        let sha256: String?
        let conflict: LANUploadConflictPolicy?
        let clientFingerprint: String?
    }
    private nonisolated struct FileList: Encodable { let path: String; let entries: [LANManagedFileEntry] }
    private nonisolated struct ByteRange: Sendable { let start: Int64; let end: Int64; let total: Int64 }

    private static func parseRange(_ header: String) -> ByteRange? {
        guard header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(parts[1]),
              start >= 0, end >= start, end < total else { return nil }
        return ByteRange(start: start, end: end, total: total)
    }

    private static func makeToken() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    private static func urlHost(_ value: String) -> String { value.contains(":") ? "[\(value.replacingOccurrences(of: "%", with: "%25"))]" : value }

    private static func jsonResponse<T: Encodable>(_ value: T) -> NanoHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do { return try .json(value, encoder: encoder) }
        catch { return .internalServerError("Response encoding failed") }
    }

    /// detached task 不继承 MainActor；结果由独立锁保护，信号量只等待单个存储操作。
    private static func waitForActor<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let result = LANBlockingResult<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.set(.success(try await operation())) }
            catch { result.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get().get()
    }

    private static func errorResponse(_ error: Error) -> NanoHTTPResponse {
        let status: Int
        if let http = error as? NanoHTTPError { status = http.status }
        else if let upload = error as? LANUploadStoreError {
            switch upload {
            case .invalidResumeToken: status = 401
            case .sessionNotFound: status = 404
            case .offsetMismatch, .destinationConflict, .destinationChanged, .incomplete, .sessionNotResumable: status = 409
            case .invalidPath: status = 403
            case .uploadTooLarge, .invalidSize, .invalidChunkSize: status = 413
            case .insufficientStorage: status = 507
            default: status = 400
            }
        } else if let file = error as? LANFileSystemStoreError {
            switch file {
            case .invalidPath, .cannotDeleteRoot, .cannotMoveIntoSelf: status = 403
            case .notFound: status = 404
            case .destinationExists, .sourceEqualsDestination, .destinationIsDirectory, .sourceIsDirectory, .invalidConflict, .invalidConfirmation, .targetChanged: status = 409
            case .fileSystem: status = 500
            }
        } else { status = 500 }
        let message = error is NanoHTTPError || error is LANUploadStoreError || error is LANFileSystemStoreError
            ? error.localizedDescription : "文件操作失败，请检查存储空间和文件权限"
        return NanoHTTPResponse(statusCode: status, body: .json(["error": message]))
    }
}

nonisolated private final class LANBlockingResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<T, Error> { lock.lock(); defer { lock.unlock() }; return value! }
}

nonisolated private enum LANFileServerError: LocalizedError {
    case noLocalAddress
    case invalidTemporaryDirectory
    var errorDescription: String? {
        switch self {
        case .noLocalAddress: return "未找到局域网地址，请连接 Wi-Fi 并允许 MeloNX 访问本地网络"
        case .invalidTemporaryDirectory: return "传输临时目录不可用"
        }
    }
}
