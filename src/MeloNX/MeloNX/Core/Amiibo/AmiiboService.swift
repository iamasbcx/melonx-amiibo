import Foundation
import Combine

/// NativeAOT 核心返回的 amiibo 检测快照。结构字段必须与 AmiiboBridge.h 保持一致。
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

/// 虚拟 amiibo 的目录、状态轮询和提交协调器。
///
/// 所有公开方法均在 MainActor 执行。NativeAOT 调用在 detached task 中进行，
/// 完成时必须再次校验 generation、Title ID、session 和检测轮次，防止旧游戏请求污染新游戏。
@MainActor
public final class AmiiboService: ObservableObject {
    public static let shared = AmiiboService()

    nonisolated private static let abiVersion: UInt32 = 1
    private static let recentIdsKey = "MeloNX.amiibo.recentIds"
    private static let selectedIdsKey = "MeloNX.amiibo.selectedIds"
    private static let automaticUseKey = "MeloNX.amiibo.automaticUse"
    private static let autoBusyRetryLimit = 3
    private static let autoBusyRetryDelay: UInt64 = 150_000_000

    @Published public private(set) var entries: [AmiiboCatalogEntry] = []
    @Published public private(set) var state: AmiiboCoreState = .unavailable
    @Published public private(set) var recentIds: [String] = []
    @Published public private(set) var customIds = Set<String>()
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var catalogError: String?
    @Published public private(set) var activeTitleId: String?
    @Published public private(set) var selectedId: String?
    @Published public private(set) var automaticUseEnabled = false

    public var selectedEntry: AmiiboCatalogEntry? {
        guard let selectedId else { return nil }
        return entries.first { $0.id == selectedId }
    }

    private var external: [AmiiboCatalogEntry] = []
    private var custom: [AmiiboCatalogEntry] = []
    private var pollTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?
    private var autoRetryTask: Task<Void, Never>?
    private var refreshInProgress = false
    private var generation: UInt64 = 0
    private var pollGeneration: UInt64 = 0
    private var abiValidated = false
    private var applicationIsActive = true
    private var selectionMenuVisible = true
    private var automaticRoundKey: String?
    private var automaticBusyRetries = 0
    private var submissionToken: String?

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentIdsKey) ?? []
        recentIds = stored.reduce(into: []) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

    deinit {
        pollTask?.cancel()
        submitTask?.cancel()
        autoRetryTask?.cancel()
    }

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

    /// 同一游戏重复出现时保留会话；轮询关闭不表示游戏已经结束。
    public func start(titleId: String) {
        let normalized = Self.normalizeTitleId(titleId)
        if AmiiboCatalogParser.validId(normalized), activeTitleId == normalized {
            updatePolling()
            return
        }
        stopInternal(clearSelection: true)
        guard AmiiboCatalogParser.validId(normalized) else {
            activeTitleId = nil
            entries = []
            external = []
            custom = []
            customIds = []
            selectedId = nil
            automaticUseEnabled = false
            catalogError = "无法确定当前游戏的 16 位 Title ID。"
            return
        }

        generation &+= 1
        activeTitleId = normalized
        state = .unavailable
        external = []
        custom = []
        entries = []
        customIds = []
        catalogError = nil
        lastMessage = nil
        applicationIsActive = true
        // 游戏页面启动时没有打开选择菜单，已保存的自动选择可以直接工作。
        selectionMenuVisible = false
        automaticRoundKey = nil
        automaticBusyRetries = 0
        selectedId = storedSelectedId(for: normalized)
        automaticUseEnabled = storedAutomaticUse(for: normalized)
        loadCatalogs()
        // 目录加载后再校验保存的 ID，避免偏好指向已删除的项目。
        clearInvalidSelectionIfNeeded()

        updatePolling()
    }

    /// 统一游戏 Title ID 的输入形式；只接受最终 16 位十六进制 ID。
    nonisolated private static func normalizeTitleId(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("0x") {
            value = String(value.dropFirst(2))
        }
        return value.uppercased()
    }

    /// 结束游戏会话并清理内存中的选择、检测轮次和异步任务；按游戏偏好仍保存在 UserDefaults。
    public func stop() {
        stopInternal(clearSelection: true)
        activeTitleId = nil
        entries = []
        external = []
        custom = []
        customIds = []
        state = .unavailable
        catalogError = nil
    }

    /// 菜单和自动使用共享一个轮询任务；关闭需求时立即取消，不保留空转定时器。
    private func updatePolling(refreshImmediately: Bool = false) {
        let needed = AmiiboPollingPolicy.needsPolling(hasSession: activeTitleId != nil,
            applicationActive: applicationIsActive, menuVisible: selectionMenuVisible,
            automaticUse: automaticUseEnabled)
        guard needed else {
            pollGeneration &+= 1
            pollTask?.cancel()
            pollTask = nil
            return
        }
        if pollTask != nil {
            guard refreshImmediately else { return }
            pollTask?.cancel()
            pollTask = nil
        }
        pollGeneration &+= 1
        let token = pollGeneration
        let session = generation
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == session, self.pollGeneration == token else { return }
                await self.refreshState()
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
        }
    }

    public func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        updatePolling()
        if !active && autoRetryTask != nil {
            // 后台期间不保留延迟重试，并清除待重试本轮标记；回到前台后由当前快照重新协调。
            autoRetryTask?.cancel()
            autoRetryTask = nil
            automaticRoundKey = nil
            automaticBusyRetries = 0
        }
    }

    public func setSelectionMenuVisible(_ visible: Bool) {
        let opening = visible && !selectionMenuVisible
        selectionMenuVisible = visible
        updatePolling(refreshImmediately: opening)
        if visible {
            // 菜单打开期间暂停延迟重试；关闭菜单后从当前检测轮次重新协调。
            let hadRetry = autoRetryTask != nil
            autoRetryTask?.cancel()
            autoRetryTask = nil
            if hadRetry {
                automaticRoundKey = nil
                automaticBusyRetries = 0
            }
        } else {
            coordinateAutomaticUse()
        }
    }

    /// 选择目录中的身份。选择本身不会绕过游戏的 amiibo 等待状态。
    public func select(id: String) {
        let normalized = id.uppercased()
        guard AmiiboCatalogParser.validId(normalized), entries.contains(where: { $0.id == normalized }) else {
            lastMessage = "请选择当前目录中的有效 amiibo。"
            return
        }
        selectedId = normalized
        if let activeTitleId { storeSelectedId(normalized, for: activeTitleId) }
        autoRetryTask?.cancel()
        autoRetryTask = nil
        // 用户明确切换角色时允许当前读取轮次重新提交；同一角色仍由轮次令牌去重。
        automaticRoundKey = nil
        automaticBusyRetries = 0
        coordinateAutomaticUse()
    }

    public func setAutomaticUseEnabled(_ enabled: Bool) {
        guard !enabled || (selectedEntry != nil && catalogError == nil) else {
            automaticUseEnabled = false
            updatePolling()
            if let activeTitleId { storeAutomaticUse(false, for: activeTitleId) }
            lastMessage = "请先选择一个有效的 Amiibo，再开启自动使用。"
            return
        }
        automaticUseEnabled = enabled
        updatePolling(refreshImmediately: enabled)
        if let activeTitleId { storeAutomaticUse(enabled, for: activeTitleId) }
        if !enabled {
            autoRetryTask?.cancel()
            autoRetryTask = nil
        }
    }

    public func reportImportFailure(_ error: Error) {
        lastMessage = error.localizedDescription
    }

    private var gameDirectory: URL? {
        guard let titleId = activeTitleId else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amiibo", isDirectory: true)
            .appendingPathComponent(titleId, isDirectory: true)
    }

    private var externalURL: URL? { gameDirectory?.appendingPathComponent("amiibo.txt") }
    private var customURL: URL? { gameDirectory?.appendingPathComponent("custom.txt") }

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
            clearInvalidSelectionIfNeeded()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    public func openCatalogDirectory() {
        guard let directory = gameDirectory else {
            lastMessage = "无法确定当前游戏的目录。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !directory.openInFiles() {
                lastMessage = "无法打开文件 App。请在 MeloNX/Amiibo/\(activeTitleId ?? "")/ 放入 amiibo.txt 后刷新。"
            }
        } catch { lastMessage = error.localizedDescription }
    }

    /// 轮询核心状态；快照返回后立即协调一次自动提交。
    public func refreshState() async {
        guard !refreshInProgress else { return }
        guard let title = activeTitleId else { return }
        let expectedGeneration = generation
        refreshInProgress = true
        defer { refreshInProgress = false }
        let checkABI = !abiValidated
        let snapshot = await Task.detached(priority: .utility) { Self.readNativeState(checkABI: checkABI) }.value
        guard !Task.isCancelled,
              generation == expectedGeneration,
              activeTitleId == title else { return }
        if snapshot.result == 0 {
            abiValidated = true
            let previous = state
            if state != snapshot.state { state = snapshot.state }
            if previous.sessionId != state.sessionId || previous.detectionEpoch != state.detectionEpoch {
                automaticRoundKey = nil
                automaticBusyRetries = 0
                autoRetryTask?.cancel()
                autoRetryTask = nil
            }
            coordinateAutomaticUse()
        } else if snapshot.result != 9 {
            abiValidated = false
            if state != .unavailable { state = .unavailable }
            let nextMessage = message(for: snapshot.result)
            if lastMessage != nextMessage { lastMessage = nextMessage }
        }
    }

    nonisolated private static func readNativeState(checkABI: Bool) -> AmiiboQueryResult {
        if checkABI {
            var version: UInt32 = 0
            var capabilities: UInt32 = 0
            guard mlx_amiibo_get_abi(&version, &capabilities) == 0,
                  version == abiVersion, capabilities & 1 != 0 else {
                return AmiiboQueryResult(result: 1, state: .unavailable)
            }
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

    private var automaticRoundToken: String? {
        guard state.sessionId != 0, state.detectionEpoch != 0 else { return nil }
        return "\(state.sessionId):\(state.detectionEpoch)"
    }

    private func coordinateAutomaticUse() {
        guard automaticUseEnabled,
              !selectionMenuVisible,
              applicationIsActive,
              catalogError == nil,
              let entry = selectedEntry,
              let round = automaticRoundToken,
              state.isRunning,
              !state.isPaused,
              state.isSearching,
              !isSubmitting,
              automaticRoundKey != round else { return }
        automaticRoundKey = round
        automaticBusyRetries = 0
        submit(entry, automatic: true)
    }

    private func scheduleAutomaticRetry(entry: AmiiboCatalogEntry, generation expectedGeneration: UInt64,
                                        title: String, session: UInt32, epoch: UInt32) {
        guard automaticUseEnabled, !selectionMenuVisible, applicationIsActive else {
            // 菜单打开或应用在后台时不创建悬空重试任务；清除轮次后由恢复时的快照重新协调。
            automaticRoundKey = nil
            automaticBusyRetries = 0
            return
        }
        guard automaticBusyRetries < Self.autoBusyRetryLimit else {
            automaticUseEnabled = false
            updatePolling()
            storeAutomaticUse(false, for: title)
            lastMessage = "核心持续忙碌，已暂停自动使用；可手动重试。"
            return
        }
        automaticBusyRetries += 1
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoBusyRetryDelay)
            // 被新的重试任务替换时，旧任务不能清除新任务句柄。
            guard !Task.isCancelled, let self else { return }
            self.autoRetryTask = nil
            guard
                  self.generation == expectedGeneration,
                  self.activeTitleId == title,
                  self.state.sessionId == session,
                  self.state.detectionEpoch == epoch,
                  self.state.isSearching,
                  self.automaticUseEnabled,
                  !self.selectionMenuVisible,
                  self.applicationIsActive,
                  !self.isSubmitting else { return }
            self.submit(entry, automatic: true)
        }
    }

    /// 手动按钮和自动协调器共用提交路径；手动提交不受菜单可见性限制。
    public func use(_ entry: AmiiboCatalogEntry) {
        submit(entry, automatic: false)
    }

    private func submit(_ entry: AmiiboCatalogEntry, automatic: Bool) {
        guard !isSubmitting else { return }
        guard AmiiboCatalogParser.validId(entry.id), let id = entry.id.data(using: .ascii) else {
            lastMessage = "amiibo ID 必须是 16 位 ASCII 十六进制字符。"
            if automatic { disableAutomaticUse(for: activeTitleId) }
            return
        }
        guard state.isRunning, !state.isPaused, state.isSearching else {
            lastMessage = message(for: state.isPaused ? 5 : 6)
            if automatic {
                // 读取窗口可能在快照与提交之间短暂变化；等待下一次快照，不关闭用户的自动设置。
                automaticRoundKey = nil
            }
            return
        }
        guard let title = activeTitleId else { return }
        let expectedGeneration = generation
        let session = state.sessionId
        let epoch = state.detectionEpoch
        let token = "\(expectedGeneration):\(title):\(session):\(epoch)"
        isSubmitting = true
        submissionToken = token
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
            guard self.submissionToken == token else { return }
            self.submissionToken = nil
            self.isSubmitting = false
            guard self.generation == expectedGeneration,
                  self.activeTitleId == title,
                  self.state.sessionId == session,
                  self.state.detectionEpoch == epoch else { return }
            if result == 0 {
                self.recordRecent(entry.id)
                self.lastMessage = "已提交“\(entry.name)”虚拟身份；实际效果由游戏决定。"
                await self.refreshState()
            } else if automatic && result == 9 {
                self.lastMessage = "核心正在准备 amiibo，稍后自动重试。"
                self.scheduleAutomaticRetry(entry: entry, generation: expectedGeneration,
                                            title: title, session: session, epoch: epoch)
            } else if automatic && (result == 6 || result == 7 || result == 8) {
                // 读取窗口或检测轮次可能在快照与提交之间变化；保留自动模式，
                // 等待核心报告新的检测轮次后再提交。
                self.lastMessage = self.message(for: result)
                await self.refreshState()
            } else {
                self.lastMessage = self.message(for: result)
                if automatic { self.disableAutomaticUse(for: title) }
                await self.refreshState()
            }
        }
    }

    private func disableAutomaticUse(for title: String?) {
        automaticUseEnabled = false
        updatePolling()
        if let title { storeAutomaticUse(false, for: title) }
    }

    private func recordRecent(_ id: String) {
        recentIds.removeAll { $0 == id }
        recentIds.insert(id, at: 0)
        recentIds = Array(recentIds.prefix(8))
        UserDefaults.standard.set(recentIds, forKey: Self.recentIdsKey)
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
            clearInvalidSelectionIfNeeded()
            lastMessage = "已导入 \(imported.count) 个项目；相同 ID 使用外部目录名称。"
        } catch { lastMessage = error.localizedDescription }
    }

    public func addCustom(name: String, id: String) throws {
        guard let destination = customURL else {
            throw AmiiboCatalogParseError(line: 0, reason: "请从正在运行的游戏内打开 amiibo 菜单。")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AmiiboCatalogParser.validName(name, maxLength: 60) else {
            throw AmiiboCatalogParseError(line: 0, reason: "名称须为 1–60 个字符，且不含方括号或控制字符。")
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
            clearInvalidSelectionIfNeeded()
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
        clearInvalidSelectionIfNeeded()
    }

    /// 目录变化后清理失效选择；自动模式没有身份可提交时必须关闭并持久化。
    private func clearInvalidSelectionIfNeeded() {
        guard let selectedId else {
            if automaticUseEnabled {
                disableAutomaticUse(for: activeTitleId)
            }
            return
        }
        guard !entries.contains(where: { $0.id == selectedId }) else { return }
        self.selectedId = nil
        if automaticUseEnabled {
            disableAutomaticUse(for: activeTitleId)
        }
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

    private func stopInternal(clearSelection: Bool) {
        generation &+= 1
        pollGeneration &+= 1
        abiValidated = false
        pollTask?.cancel(); pollTask = nil
        submitTask?.cancel(); submitTask = nil
        autoRetryTask?.cancel(); autoRetryTask = nil
        // get_state 在 detached task 中无法立即取消；保留标记，待旧调用返回时由 defer 清除，
        // 防止新旧游戏同时进入 NativeAOT 核心。
        isSubmitting = false
        submissionToken = nil
        state = .unavailable
        automaticRoundKey = nil
        automaticBusyRetries = 0
        if clearSelection {
            selectedId = nil
            automaticUseEnabled = false
        }
    }

    private func storedSelectedId(for title: String) -> String? {
        guard let values = UserDefaults.standard.object(forKey: Self.selectedIdsKey) as? [String: String] else { return nil }
        return values[title]?.uppercased()
    }

    private func storeSelectedId(_ id: String, for title: String) {
        var values = (UserDefaults.standard.object(forKey: Self.selectedIdsKey) as? [String: String]) ?? [:]
        values[title] = id
        UserDefaults.standard.set(values, forKey: Self.selectedIdsKey)
    }

    private func storedAutomaticUse(for title: String) -> Bool {
        guard let values = UserDefaults.standard.object(forKey: Self.automaticUseKey) as? [String: Bool] else { return false }
        return values[title] ?? false
    }

    private func storeAutomaticUse(_ enabled: Bool, for title: String) {
        var values = (UserDefaults.standard.object(forKey: Self.automaticUseKey) as? [String: Bool]) ?? [:]
        values[title] = enabled
        UserDefaults.standard.set(values, forKey: Self.automaticUseKey)
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
