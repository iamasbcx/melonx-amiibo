//
//  RyujinxController.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import SwiftUI
import Combine

extension URL {
    @available(iOS, introduced: 14.0, deprecated: 16.0, message: "Use URL.documentsDirectory on iOS 16 and above")
    static var documentsDirectory: URL {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentDirectory
    }
    
    static var configFolderURL: URL {
        documentsDirectory.appendingPathComponent("config")
    }
    
    static func perGameConfigURL(_ titleId: String) -> URL {
        return configFolderURL.appendingPathComponent(titleId + "_config.json")
    }
    
    static var configURL: URL {
        documentsDirectory.appendingPathComponent("config.json")
    }
    
    static var romsURL: URL {
        documentsDirectory.appendingPathComponent("roms")
    }
    
    static var keyboardConfigURL: URL {
        documentsDirectory.appendingPathComponent("keyboardConfig.json")
    }
    
    static var keysFolderURL: URL {
        documentsDirectory.appendingPathComponent("system")
    }
    
    static var modsFolderURL: URL {
        documentsDirectory.appendingPathComponent("mods")
    }
    
    static func modFolderURL(for game: GameInfo) -> URL {
        modsFolderURL.appendingPathComponent("contents").appendingPathComponent(game.titleId)
    }
    
    static var logsFolderURL: URL {
        documentsDirectory.appendingPathComponent("logs")
    }
    
    static var controllerMappingsURL: URL {
        documentsDirectory.appendingPathComponent("controllerMappings.json")
    }
    
    static func cacheFolderURL(for game: GameInfo) -> URL {
        let fileManager = FileManager.default
        let gamesFolder = documentsDirectory.appendingPathComponent("games")
        
        return gamesFolder.appendingPathComponent(game.titleId).appendingPathComponent("cache")
    }
}

extension UIDevice {
    var supportsBCTextureCompression: Bool {
        if #available(iOS 16.4, *), let device = MTLCreateSystemDefaultDevice() {
           return device.supportsBCTextureCompression
        }
        
        return false
    }
}

public enum StartedState {
    case none
    case entitlement
    case extendedEntitlement
    case noJIT
    case usersList
}

public enum RunningState {
    case started(game: GameInfo, state: StartedState = .none)
    case stopped
    case crashed(result: String)
    
    func hasStarted() -> Bool {
        if case .started(_, let state) = self {
            return state != .noJIT
        }
        return false
    }
    
    func isRunning() -> Bool {
        if case .started(_, let state) = self {
            return state == .none
        }
        return false
    }
    
    func isEntitlement() -> Bool {
        if case .started(_, let state) = self {
            return state == .entitlement
        }
        return false
    }
    
    func hasCrashed() -> Bool {
        if case .crashed = self {
            return true
        }
        return false
    }
}



public final class RyujinxController: ObservableObject {
    public static var shared: RyujinxController = .init()
    
    private init() {}
    
    @Published public var isRunning: RunningState = .stopped
    @Published public var games: [GameInfo] = []
    @Published var settings: Options = .init(inputPath: "")
    
    @Published var perSettings: [String: Options] = [:]
    
    private var hasLoadedConfig = false
    private var configSaveWorkItem: DispatchWorkItem?
    private var perGameSaveWorkItems: [String: DispatchWorkItem] = [:]
    private let settingsSaveDelay: TimeInterval = 0.35
    
    var currentSettings: Options {
        get {
            if case .started(let game, _) = isRunning {
                return perSettings[game.titleId] ?? settings
            }
            
            return settings
        } set {
            self.objectWillChange.send()
            if case .started(let game, _) = isRunning, perSettings[game.titleId]  != nil {
                perSettings[game.titleId] = newValue
            }
            
            settings = newValue
        }
    }

    var lastGameLaunched: String? {
        get {
            UserDefaults.standard.string(forKey: "lastGameLaunched")
        } set {
            if let cool = newValue { UserDefaults.standard.set(cool, forKey: "lastGameLaunched"); return }
            UserDefaults.standard.removeObject(forKey: "lastGameLaunched")
        }
    }
    
    @Published var _isPaused: Bool = false
    
    @Published var wasManuallyPaused: Bool = false

    /// 标记底层模拟线程正在退出。退出请求发出后保持游戏视图，直到 mainRyu 真正返回，避免提前销毁 Metal 视图。
    @Published private(set) var isStopping: Bool = false
    
    var isPaused: Bool {
        get {
            return _isPaused
        } set {
            _isPaused = newValue
            Ryujinx.togglePauseEmulation(_isPaused)
        }
    }
    
    private static var hasScript: Bool = false
    private var controllerManager: ControllerManager = .shared
    private var emulationThreadActive = false
    
    @Published var firmwareInstallState: FirmwareInstallState = .idle
    
    var firmwareVersion: String {
        return Ryujinx.installedFirmwareVersion
    }
    
    var firmwareInstalled: Bool {
        !Ryujinx.installedFirmwareVersion.isEmpty
    }
    
    var isJITEnabled: Bool {
        jitEnabled()
    }
    
    var hasIncreasedMemoryLimitEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit")
    }
    
    var hasExtendedVirtualAddressingEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing")
    }
    
    
    
    func startGame(_ game: GameInfo) {
        guard !emulationThreadActive, !isRunning.hasStarted(), !isStopping else { return }
        
        loadConfig()
        
        if !hasIncreasedMemoryLimitEntitlement {
            isRunning = .started(game: game, state: .entitlement)
            lastGameLaunched = nil
            return
        }
        
        if !hasExtendedVirtualAddressingEntitlement && AppEnvironment.shared.requiresExtendedVirtualAddressing() {
            isRunning = .started(game: game, state: .extendedEntitlement)
            lastGameLaunched = nil
            return
        }
        
        // extendedEntitlement
        
        if !isJITEnabled {
            isRunning = .started(game: game, state: .noJIT)
            return
        }
        
        lastGameLaunched = nil
        
        controllerManager.activateInputProfile(gameId: game.titleId)
        let config = pullKeyboardConfig(gameId: game.titleId)
        Ryujinx.setKeyboardConfig(config)
        let inputReadErrors = [
            ControllerMappingStore.shared.readError(gameId: game.titleId),
            keyboardConfigReadError(gameId: game.titleId)
        ].compactMap { $0 }
        if !inputReadErrors.isEmpty {
            AppAlerts.showAlert(title: "Input Settings Error", message: inputReadErrors.joined(separator: "\n\n"), actions: [
                (title: "OK", style: .default, handler: nil)
            ])
        }

        // 始终以当前游戏读取并逐项回退到全局；游戏内首次创建覆盖也无需替换正在观察的对象。
        let inputGameId = ControllerInputProfile.normalizedGameId(game.titleId)
        NativeSettingsManager.setShared(inputGameId, pullOriginal: inputGameId != nil)

        loadWithoutSave(game.titleId)
        
        var settings = perSettings[game.titleId] ?? settings
        ControllerInputProfile.applyTypes(to: &settings, gameId: game.titleId)
        
        let preferredNetworkInterfaceId = settings.multiplayerLanInterfaceId == "0" ? self.settings.multiplayerLanInterfaceId : settings.multiplayerLanInterfaceId
        
        settings.resolveMultiplayerLanInterface(preferredInterfaceId: preferredNetworkInterfaceId)
        
        settings.inputPath = game.fileURL.path
        settings.backendThreading = .on
        
        isRunning = .started(game: game)
        _isPaused = false
        wasManuallyPaused = false
        emulationThreadActive = true

        // 先进入运行态，再绑定控制器，避免刷新回调与游戏启动之间出现 attach 竞态。
        // 绑定完成后，虚拟手柄输入才能稳定送入当前游戏。
        InGameInputSession.shared.beginGame()
        controllerManager.attachAllControllers()
        
        let nativeSettingsManager = NativeSettingsManager.shared
        
        if !(nativeSettingsManager.writeStdout.value as Bool) {
            redirectStdIOToFile()
        }
        
        let expandedRAM = settings.expandRAM
        
        Thread.detachNewThread {
            RamDonor.prepare(bytes: expandedRAM ? 6 * 1024 * 1024 * 1024 : 4 * 1024 * 1024 * 1024)
            
            
            let response = Ryujinx.mainRyu(settings)
            
            RamDonor.teardown()
            
            DispatchQueue.main.async {
                self.emulationThreadActive = false
                
                if self.isStopping {
                    self.finishStopping()
                } else if response != 0 {
                    self.restoreGlobalInputProfile()
                    self.isRunning = .crashed(result: "Code: \(response)")
                } else {
                    self.restoreGlobalInputProfile()
                    self.isRunning = .stopped
                }
            }
        }
    }

    /// 请求退出当前游戏。Native stop 在后台执行，避免阻塞 SwiftUI 主线程；界面资源在 mainRyu 返回后统一释放。
    @MainActor
    func stopGame() {
        guard !isStopping else { return }

        // 只有 native 入口仍在运行时才发送停止请求；若线程已经返回，仅需完成 UI 收尾，
        // 避免在上一局结束后把停止标记误留给下一局启动。
        guard emulationThreadActive else {
            finishStopping()
            return
        }

        isStopping = true
        _isPaused = false
        wasManuallyPaused = false
        // 先停止向 native 输入层提交事件，给窗口和渲染线程留下完整的释放窗口。
        InGameInputSession.shared.endGame()
        controllerManager.detachAllControllers()
        AmiiboService.shared.stop()

        DispatchQueue.global(qos: .userInitiated).async {
            Ryujinx.stopEmulation()
        }
    }

    /// 仅在主线程调用；此时 native 模拟线程已返回，可以安全销毁 Metal 视图并解绑输入。
    @MainActor
    private func finishStopping() {
        dispatchPrecondition(condition: .onQueue(.main))
        Ryujinx.emulationView = nil
        _isPaused = false
        wasManuallyPaused = false
        isStopping = false
        isRunning = .stopped
        restoreGlobalInputProfile()
    }

    /// 模拟线程结束后恢复菜单使用的全局范围，不向已经退出的核心重新绑定设备。
    @MainActor
    private func restoreGlobalInputProfile() {
        InGameInputSession.shared.endGame()
        controllerManager.detachAllControllers()
        controllerManager.activateInputProfile(gameId: nil)
        NativeSettingsManager.setShared()
        controllerManager.refreshControllersList()
    }
    
    
    func redirectStdIOToFile() {
        let fileManager = FileManager.default
        
        let logsDir = URL.logsFolderURL
        
        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        
        cleanupOldLogs(in: logsDir, keep: 5)
        
        let fileName = "MeloNX-Log-\(Date()).log"
        let logURL = logsDir.appendingPathComponent(fileName)
        
        fileManager.createFile(atPath: logURL.path, contents: nil)
        
        let fd = open(logURL.path, O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        
        close(fd)
    }
    
    func cleanupOldLogs(in directory: URL, keep: Int) {
        let fileManager = FileManager.default
        
        guard var files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        
        files = files.compactMap({ $0.lastPathComponent.hasPrefix("MeloNX-Log-") ? $0 : nil })
        
        let sortedFiles = files.sorted {
            let date1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let date2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return date1 > date2
        }
        
        let filesToDelete = sortedFiles.dropFirst(keep)
        
        for file in filesToDelete {
            try? fileManager.removeItem(at: file)
        }
    }
    
    func loadConfig() {
        guard !hasLoadedConfig else { return }
        hasLoadedConfig = true
        
        guard FileManager.default.fileExists(atPath: URL.configURL.path) else {
            settings.resolveMultiplayerLanInterface()
            saveConfig()
            return
        }
        
        do {
            var loadedSettings = try Options.loadFromJSON(at: .configURL)
            loadedSettings.resolveMultiplayerLanInterface()
            settings = loadedSettings
        } catch {
            let backupURL = backupInvalidConfig(at: .configURL)
            settings = .init(inputPath: "")
            settings.resolveMultiplayerLanInterface()
            
            if backupURL != nil {
                saveConfig()
            }
            
            showSettingsError(title: "Failed to Load Settings", error: error, backupURL: backupURL, backupWasAttempted: true)
        }
    }
    
    func scheduleConfigSave() {
        configSaveWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveConfig()
        }
        
        configSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settingsSaveDelay, execute: workItem)
    }
    
    func saveConfig() {
        configSaveWorkItem?.cancel()
        configSaveWorkItem = nil
        
        do {
            try settings.saveAsJSON(to: .configURL)
        } catch {
            showSettingsError(title: "Failed to Save Settings", error: error)
        }
    }
    
    func loadPerGameConfig(_ titleId: String) {
        let url = URL.perGameConfigURL(titleId)
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            perSettings.removeValue(forKey: titleId)
            return
        }
        
        do {
            perSettings[titleId] = try Options.loadFromJSON(at: url)
        } catch {
            let backupURL = backupInvalidConfig(at: url)
            
            if backupURL != nil {
                try? FileManager.default.removeItem(at: url)
            }
            
            perSettings.removeValue(forKey: titleId)
            showSettingsError(title: "Failed to Load Game Settings", error: error, backupURL: backupURL, backupWasAttempted: true)
        }
    }
    
    func loadWithoutSave(_ titleId: String) {
        loadPerGameConfig(titleId)
    }
    
    func schedulePerGameConfigSave(_ titleId: String) {
        perGameSaveWorkItems[titleId]?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.savePerGameConfig(titleId)
        }
        
        perGameSaveWorkItems[titleId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settingsSaveDelay, execute: workItem)
    }
    
    func savePerGameConfig(_ titleId: String) {
        perGameSaveWorkItems[titleId]?.cancel()
        perGameSaveWorkItems.removeValue(forKey: titleId)
        
        guard let gameSettings = perSettings[titleId] else { return }
        
        do {
            try gameSettings.saveAsJSON(to: .perGameConfigURL(titleId))
        } catch {
            showSettingsError(title: "Failed to Save Game Settings", error: error)
        }
    }
    
    @discardableResult
    func removePerGameConfig(_ titleId: String) -> Bool {
        perGameSaveWorkItems[titleId]?.cancel()
        perGameSaveWorkItems.removeValue(forKey: titleId)
        
        let url = URL.perGameConfigURL(titleId)
        
        do {
            if let inputGameId = ControllerInputProfile.normalizedGameId(titleId) {
                try ControllerMappingStore.shared.resetOverrides(gameId: inputGameId)
                try resetKeyboardConfig(gameId: inputGameId)
                ControllerInputProfile.resetOverrides(gameId: inputGameId)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            
            perSettings.removeValue(forKey: titleId)
            
            return true
        } catch {
            showSettingsError(title: "Failed to Remove Game Settings", error: error)
            
            return false
        }
    }
    
    func hasPerGameConfig(_ titleId: String) -> Bool {
        if perSettings[titleId] != nil ||
            FileManager.default.fileExists(atPath: URL.perGameConfigURL(titleId).path) ||
            NativeSettingsManager.exists(titleId) { return true }
        guard let inputGameId = ControllerInputProfile.normalizedGameId(titleId) else { return false }
        return ControllerInputProfile.hasOverrides(gameId: inputGameId) ||
            ControllerMappingStore.shared.hasOverrides(gameId: inputGameId) ||
            hasKeyboardConfigOverride(gameId: inputGameId)
    }
    
    func flushPendingSettingsSaves() {
        if configSaveWorkItem != nil {
            saveConfig()
        }
        
        for titleId in Array(perGameSaveWorkItems.keys) {
            savePerGameConfig(titleId)
        }
    }
    
    private func backupInvalidConfig(at url: URL) -> URL? {
        let backupName = "\(url.deletingPathExtension().lastPathComponent).invalid-\(UUID().uuidString).json"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupName)
        
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            
            return backupURL
        } catch {
            return nil
        }
    }
    
    private func showSettingsError(title: String, error: Error, backupURL: URL? = nil, backupWasAttempted: Bool = false) {
        var message = error.localizedDescription
        
        if let backupURL {
            message += "\n\nThe previous file was backed up as \(backupURL.lastPathComponent)."
        } else if backupWasAttempted {
            message += "\n\nA backup could not be created, so the previous file was left unchanged."
        }
        
        AppAlerts.showSyncAlert(title: title, message: message, hasCancel: false)
    }
    
    
    func loadGamesArray() -> [GameInfo] {
        let fileManager = FileManager.default
        var romDirectories: [URL] = [.romsURL]
        
        let romFolderManager = ROMFolderManager.shared
        romFolderManager.loadBookmarks()
        
        for bookmarkData in romFolderManager.bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale, fileManager.fileExists(atPath: url.path) {
                    _ = romFolderManager.addFolder(url: url)
                }
                
                if url.startAccessingSecurityScopedResource() {
                    romDirectories.append(url)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        var games: [GameInfo] = []
        for romsDirectory in romDirectories {
            guard let enumerator = fileManager.enumerator(at: romsDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard GameFileType.isSupported(fileExtension: fileURL.pathExtension) else { continue }
                
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    let fileExtension = fileURL.pathExtension as NSString
                    games.append(Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: fileURL))
                } catch {
                    print("Failed to read file at \(fileURL): \(error)")
                }
            }
        }
        
        return games
    }
    
    
    func loadGames() {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        var romDirectories: [URL] = [documentsDirectory.appendingPathComponent("roms")]
        
        let romFolderManager = ROMFolderManager.shared
        romFolderManager.loadBookmarks()
        
        for bookmarkData in romFolderManager.bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale, fileManager.fileExists(atPath: url.path) {
                    _ = romFolderManager.addFolder(url: url)
                }
                
                if url.startAccessingSecurityScopedResource() {
                    romDirectories.append(url)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        let defaultRomsDirectory = documentsDirectory.appendingPathComponent("roms")
        if !fileManager.fileExists(atPath: defaultRomsDirectory.path) {
            do {
                try fileManager.createDirectory(at: defaultRomsDirectory, withIntermediateDirectories: true)
            } catch {
                print("Failed to create roms directory: \(error)")
            }
        }
        
        var games: [GameInfo] = []
        for romsDirectory in romDirectories {
            guard let enumerator = fileManager.enumerator(at: romsDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard GameFileType.isSupported(fileExtension: fileURL.pathExtension) else { continue }
                
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    let fileExtension = fileURL.pathExtension as NSString
                    games.append(Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: fileURL))
                } catch {
                    print("Failed to read file at \(fileURL): \(error)")
                }
            }
        }
        
        self.games = games
        
        sortGames(true)
    }
    
    func sortGames(_ isCalled: Bool = false) {
        let nativeSettingsManager: NativeSettingsManager = .shared
        switch nativeSettingsManager.gameSort(GameSort.none).value {
        case .alphabetical:
            games = games.sorted { $0.titleName < $1.titleName }
        case .newest:
            games = games.sorted { (game, gam2) -> Bool in
                let date1 = (try? game.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let date2 = (try? gam2.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
            }
        case .none:
            if !isCalled { loadGames() }
        }
    }
    
    
    func clearShaderCacheWithConfirmation(_ game: GameInfo? = nil) {
        AppAlerts.showAlert(title: "Shader Cache Deletion.", message: "Are you sure you want to delete \(game?.titleName ?+ "'s", default: "all") shader cache?", actions: [
            (title: "Cancel", style: .cancel, handler: nil),
            (title: "Delete", style: .destructive, handler: {
                self.clearShaderCache(game, withConfirmation: true)
            })
        ])
    }
    
    func clearShaderCache(_ game: GameInfo? = nil, withConfirmation: Bool = false) {
        let fileManager = FileManager.default
        
        guard let game else {
            let games = loadGamesArray()
            
            for game in games {
                print("Clear Shader Cache: \(URL.cacheFolderURL(for: game).path), exists: \(fileManager.fileExists(atPath: URL.cacheFolderURL(for: game).path))")
                try? fileManager.removeItem(at: .cacheFolderURL(for: game))
            }
            
            if withConfirmation {
                AppAlerts.showAlert(title: "Shader Cache Deleted.", message: "All cached shaders have been deleted.", actions: [
                    (title: "OK", style: .default, handler: nil)
                ])
            }
            
            return
        }
        
        do {
            if fileManager.fileExists(atPath: URL.cacheFolderURL(for: game).path) {
                try fileManager.removeItem(at: .cacheFolderURL(for: game))
            }
            
            if withConfirmation {
                AppAlerts.showAlert(title: "Shader Cache Deleted.", message: "Shader Cache for \(game.titleName) have been deleted.", actions: [
                    (title: "OK", style: .default, handler: nil)
                ])
            }
        } catch {
            if withConfirmation {
                AppAlerts.showAlert(title: "Failed to Delete Shader Cache.", message: "Failed to delete cached shaders for \(game.titleName).", actions: [
                    (title: "OK", style: .default, handler: nil)
                ])
            }
        }
    }
    
    static func attemptToMapDualMapping() -> Bool {
        if hasScript { return true }
        
        hasScript = Ryujinx.initDualMapping()
        
        return hasScript
    }
    
    func attemptToMapDualMapping() -> Bool {
        return Self.attemptToMapDualMapping()
    }
}
