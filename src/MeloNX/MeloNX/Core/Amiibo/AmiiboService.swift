//  离线 TXT 目录、用户自定义身份与 NativeAOT 状态的 UI 服务。
//  UI 发布在 MainActor；可能等待核心锁或磁盘的 C 调用在后台执行。
import Foundation
import Combine

public nonisolated struct AmiiboCoreState: Equatable, Sendable {
    public let sessionId: UInt32
    public let detectionEpoch: UInt32
    public let flags: UInt32
    public let lastResult: Int32
    public var isRunning: Bool { flags & 1 != 0 }
    public var isPaused: Bool { flags & 2 != 0 }
    public var isSearching: Bool { flags & 4 != 0 }
    public static let unavailable = AmiiboCoreState(sessionId: 0, detectionEpoch: 0, flags: 0, lastResult: 0)
}

private nonisolated struct AmiiboQueryResult: Sendable {
    let result: Int32
    let state: AmiiboCoreState
}

@MainActor
public final class AmiiboService: ObservableObject {
    public static let shared = AmiiboService()
    nonisolated private static let abiVersion: UInt32 = 1
    private static let recentIdsKey = "MeloNX.amiibo.recentIds"

    @Published public private(set) var entries: [AmiiboCatalogEntry] = []
    @Published public private(set) var state: AmiiboCoreState = .unavailable
    @Published public private(set) var recentIds: [String] = []
    @Published public private(set) var customIds = Set<String>()
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var catalogError: String?
    @Published public private(set) var activeTitleId: String?

    private var external: [AmiiboCatalogEntry] = []
    private var custom: [AmiiboCatalogEntry] = []
    private var pollTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?
    private var refreshInProgress = false

    public func reportImportFailure(_ error: Error) { lastMessage = error.localizedDescription }

    private var gameDirectory: URL? {
        guard let titleId = activeTitleId else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amiibo", isDirectory: true)
            .appendingPathComponent(titleId, isDirectory: true)
    }

    private var externalURL: URL? { gameDirectory?.appendingPathComponent("amiibo.txt") }
    private var customURL: URL? { gameDirectory?.appendingPathComponent("custom.txt") }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentIdsKey) ?? []
        for id in stored where !recentIds.contains(id) { recentIds.append(id) }
    }

    deinit { pollTask?.cancel(); submitTask?.cancel() }

    public var orderedEntries: [AmiiboCatalogEntry] {
        let recent = Dictionary(uniqueKeysWithValues: recentIds.enumerated().map { ($1, $0) })
        return entries.sorted { left, right in
            switch (recent[left.id], recent[right.id]) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    public func start(titleId: String) {
        stopPolling()
        let normalized = titleId.uppercased()
        guard AmiiboCatalogParser.validId(normalized) else {
            activeTitleId = nil
            entries = []
            external = []
            custom = []
            customIds = []
            catalogError = "无法确定当前游戏的 16 位 Title ID。"
            return
        }
        activeTitleId = normalized
        state = .unavailable
        external = []
        custom = []
        entries = []
        customIds = []
        loadCatalogs()
        lastMessage = nil
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshState()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    public func stopPolling() { pollTask?.cancel(); pollTask = nil }

    public func refreshCatalog() {
        guard let externalURL, let customURL else { return }
        do {
            let nextExternal = try readCatalog(at: externalURL)
            let nextCustom = try readCatalog(at: customURL)
            external = nextExternal
            custom = nextCustom
            mergeCatalogs()
            catalogError = nil
            lastMessage = "已刷新当前游戏目录。"
        } catch { catalogError = error.localizedDescription }
    }

    public func openCatalogDirectory() {
        guard let directory = gameDirectory else {
            lastMessage = "无法确定当前游戏的目录。"; return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !directory.openInFiles() {
                lastMessage = "无法打开文件 App。请在 MeloNX/Amiibo/\(activeTitleId ?? "")/ 放入 amiibo.txt 后刷新。"
            }
        } catch { lastMessage = error.localizedDescription }
    }

    /// 轮询串行等待后台快照，绝不让 MainActor 阻塞在 NativeAOT 的生命周期锁。
    public func refreshState() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        let snapshot = await Task.detached(priority: .utility) { Self.readNativeState() }.value
        guard !Task.isCancelled else { return }
        if snapshot.result == 0 { state = snapshot.state }
        else if snapshot.result != 9 {
            state = .unavailable
            lastMessage = message(for: snapshot.result)
        }
    }

    nonisolated private static func readNativeState() -> AmiiboQueryResult {
        var version: UInt32 = 0
        var capabilities: UInt32 = 0
        guard mlx_amiibo_get_abi(&version, &capabilities) == 0,
              version == abiVersion, capabilities & 1 != 0 else {
            return AmiiboQueryResult(result: 1, state: .unavailable)
        }
        var native = MlxAmiiboState()
        let result = mlx_amiibo_get_state(&native, UInt32(MemoryLayout<MlxAmiiboState>.size))
        guard result == 0 else { return AmiiboQueryResult(result: result, state: .unavailable) }
        guard native.abi_version == abiVersion,
              native.struct_size == UInt32(MemoryLayout<MlxAmiiboState>.size) else {
            return AmiiboQueryResult(result: 1, state: .unavailable)
        }
        return AmiiboQueryResult(result: 0, state: AmiiboCoreState(
            sessionId: native.session_id, detectionEpoch: native.detection_epoch,
            flags: native.flags & 7, lastResult: native.last_result))
    }

    public func use(_ entry: AmiiboCatalogEntry) {
        guard !isSubmitting else { lastMessage = "正在提交，请稍候。"; return }
        guard AmiiboCatalogParser.validId(entry.id), let id = entry.id.data(using: .ascii) else {
            lastMessage = "amiibo ID 必须是 16 位 ASCII 十六进制字符。"; return
        }
        let session = state.sessionId
        let epoch = state.detectionEpoch
        isSubmitting = true
        lastMessage = nil
        let background = Task.detached(priority: .userInitiated) {
            var request = MlxAmiiboScanRequest()
            request.abi_version = Self.abiVersion
            request.struct_size = UInt32(MemoryLayout<MlxAmiiboScanRequest>.size)
            request.session_id = session
            request.detection_epoch = epoch
            id.withUnsafeBytes { source in
                withUnsafeMutableBytes(of: &request) { destination in
                    destination.baseAddress!.advanced(by: 16).copyMemory(from: source.baseAddress!, byteCount: 16)
                }
            }
            return mlx_amiibo_scan(&request, UInt32(MemoryLayout<MlxAmiiboScanRequest>.size))
        }
        submitTask = Task { @MainActor [weak self] in
            let result = await background.value
            guard let self else { return }
            self.isSubmitting = false
            guard self.state.sessionId == session else {
                self.lastMessage = "游戏会话已变化，旧请求结果不再应用到当前目录。"
                return
            }
            if result == 0 {
                self.recentIds.removeAll { $0 == entry.id }
                self.recentIds.insert(entry.id, at: 0)
                self.recentIds = Array(self.recentIds.prefix(8))
                UserDefaults.standard.set(self.recentIds, forKey: Self.recentIdsKey)
                self.lastMessage = "已提交“\(entry.name)”虚拟身份；实际效果由游戏决定。"
            } else { self.lastMessage = self.message(for: result) }
            await self.refreshState()
        }
    }

    public func importCatalog(from url: URL) {
        guard let destination = externalURL else {
            lastMessage = "请从正在运行的游戏内打开 amiibo 菜单。"
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? 0) <= AmiiboCatalogParser.maxBytes else {
                throw AmiiboCatalogParseError(line: 0, reason: "目录超过 1 MiB。")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let imported = try AmiiboCatalogParser.parse(data)
            try replaceLocalCatalog(data, destination: destination)
            external = imported
            mergeCatalogs()
            catalogError = nil
            lastMessage = "已导入 \(imported.count) 个项目；相同 ID 使用外部目录名称。"
        } catch { lastMessage = error.localizedDescription }
    }

    public func addCustom(name: String, id: String) throws {
        guard let destination = customURL else {
            throw AmiiboCatalogParseError(line: 0, reason: "请从正在运行的游戏内打开 amiibo 菜单。")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AmiiboCatalogParser.validName(name, maxLength: 60) else {
            throw AmiiboCatalogParseError(line: 0, reason: "名称须为 1～60 个字符，且不含方括号或控制字符。")
        }
        guard AmiiboCatalogParser.validId(id) else {
            throw AmiiboCatalogParseError(line: 0, reason: "ID 必须是 16 位 ASCII 十六进制字符。")
        }
        let entry = AmiiboCatalogEntry(id: id.uppercased(), name: name)
        var updated = custom.filter { $0.id != entry.id }
        updated.append(entry)
        let data = try AmiiboCatalogParser.encode(updated)
        try replaceLocalCatalog(data, destination: destination)
        custom = updated
        mergeCatalogs()
        catalogError = nil
        lastMessage = "已添加自定义虚拟身份“\(name)”。"
    }

    public func removeCustom(id: String) {
        guard let destination = customURL else { return }
        do {
            let updated = custom.filter { $0.id != id }
            if updated.isEmpty {
                try backupExisting(destination)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            } else { try replaceLocalCatalog(AmiiboCatalogParser.encode(updated), destination: destination) }
            custom = updated
            mergeCatalogs()
        } catch { lastMessage = error.localizedDescription }
    }

    private func loadCatalogs() {
        guard let externalURL, let customURL, let directory = gameDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let nextExternal = try readCatalog(at: externalURL)
            let nextCustom = try readCatalog(at: customURL)
            external = nextExternal
            custom = nextCustom
            mergeCatalogs()
            catalogError = nil
        } catch { catalogError = error.localizedDescription }
    }

    private func readCatalog(at url: URL) throws -> [AmiiboCatalogEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= AmiiboCatalogParser.maxBytes else {
            throw AmiiboCatalogParseError(line: 0, reason: "目录超过 1 MiB。")
        }
        return try AmiiboCatalogParser.parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func mergeCatalogs() {
        var indexed: [String: AmiiboCatalogEntry] = [:]
        for entry in external { indexed[entry.id] = entry }
        for entry in custom { indexed[entry.id] = entry }
        entries = Array(indexed.values)
        customIds = Set(custom.map(\.id))
        recentIds = recentIds.filter { indexed[$0] != nil }
    }

    private func replaceLocalCatalog(_ data: Data, destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backupExisting(destination)
        try data.write(to: destination, options: .atomic)
    }

    private func backupExisting(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("备份", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()) + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(url.lastPathComponent))
    }

    private func message(for result: Int32) -> String {
        switch result {
        case 1: return "核心 ABI 版本不匹配。"
        case 2: return "请求参数无效。"
        case 3: return "核心状态缓冲区太小。"
        case 4: return "游戏尚未运行。"
        case 5: return "游戏已暂停，请先继续游戏。"
        case 6: return "游戏当前没有等待 amiibo，请先在游戏内开启读取。"
        case 7: return "模拟器会话已变化，请重新打开菜单。"
        case 8: return "游戏的 amiibo 检测阶段已变化，请重新打开菜单。"
        case 9: return "核心正忙，请稍后重试。"
        default: return "虚拟 amiibo 操作失败（错误码 \(result)）。"
        }
    }
}
