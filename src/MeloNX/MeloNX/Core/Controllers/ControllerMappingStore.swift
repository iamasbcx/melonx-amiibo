// 管理手柄映射的全局默认与游戏覆盖；读写通过串行队列同步，输入线程只读取缓存。
import Foundation
import Combine

final class ControllerMappingStore: ObservableObject {
    static let shared = ControllerMappingStore()
    @Published private(set) var revision = 0
    private let queue = DispatchQueue(label: "com.stossy11.melonx.controllermappings")
    private var profiles: [String: [String: ControllerMapping]] = [:]
    private var loadErrors: [String: String] = [:]
    private var activeGameId: String?

    private init() {}

    /// 只改变运行时读取范围，不修改任何持久化配置；应在绑定设备前调用。
    func activate(gameId: String?) {
        queue.sync {
            activeGameId = ControllerInputProfile.normalizedGameId(gameId)
            _ = profile(gameId: nil)
            if let activeGameId { _ = profile(gameId: activeGameId) }
        }
    }

    func runtimeMapping(for controller: BaseController) -> ControllerMapping {
        queue.sync { resolvedMapping(for: controller, gameId: activeGameId) }
    }

    /// gameId 为 nil 表示只读全局；游戏未覆盖当前设备时回退全局。
    func mapping(for controller: BaseController, gameId: String?) -> ControllerMapping {
        queue.sync { resolvedMapping(for: controller, gameId: ControllerInputProfile.normalizedGameId(gameId)) }
    }

    func hasOverrides(gameId: String) -> Bool {
        queue.sync { !profile(gameId: gameId).isEmpty }
    }

    func readError(gameId: String?) -> String? {
        queue.sync {
            readFailure(gameId: ControllerInputProfile.normalizedGameId(gameId)).map {
                InputConfigurationError.unreadable($0).localizedDescription
            }
        }
    }

    func setMapping(_ mapping: ControllerMapping, for controller: BaseController, gameId: String?) throws {
        try update(gameId: gameId) { $0[Self.key(for: controller)] = mapping }
    }

    func resetMapping(for controller: BaseController, gameId: String?) throws {
        try update(gameId: gameId, allowReset: true) { $0.removeValue(forKey: Self.key(for: controller)) }
    }

    func resetOverrides(gameId: String) throws {
        try update(gameId: gameId, allowReset: true) { $0.removeAll() }
    }

    static func key(for controller: BaseController) -> String {
        controller.virtual ? "virtual" : controller.name
    }
    private static func url(gameId: String?) -> URL {
        guard let gameId else { return .controllerMappingsURL }
        return URL.configFolderURL.appendingPathComponent(gameId).appendingPathComponent("controllerMappings.json")
    }

    /// 下列缓存方法仅可在 queue 内调用，避免设备回调与设置保存竞争。
    private func profile(gameId: String?) -> [String: ControllerMapping] {
        let key = gameId ?? "global"
        if let cached = profiles[key] { return cached }
        let url = Self.url(gameId: gameId)
        var value: [String: ControllerMapping] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                value = try JSONDecoder().decode([String: ControllerMapping].self, from: Data(contentsOf: url))
            } catch {
                NSLog("Controller mapping read failed (%@): %@", key, error.localizedDescription)
                loadErrors[key] = "controllerMappings.json (\(key)): \(error.localizedDescription)"
            }
        }
        profiles[key] = value
        return value
    }

    private func resolvedMapping(for controller: BaseController, gameId: String?) -> ControllerMapping {
        let key = Self.key(for: controller)
        if let gameId, let value = profile(gameId: gameId)[key] { return value }
        return profile(gameId: nil)[key] ?? .standard()
    }

    private func readFailure(gameId: String?) -> String? {
        _ = profile(gameId: nil)
        if let gameId { _ = profile(gameId: gameId) }
        let errors = [gameId.flatMap { loadErrors[$0] }, loadErrors["global"]].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// 先原子写盘，再替换缓存；失败时保留原有效值，并由界面显示错误。
    private func update(gameId: String?, allowReset: Bool = false, mutate: (inout [String: ControllerMapping]) -> Void) throws {
        let gameId = ControllerInputProfile.normalizedGameId(gameId)
        try queue.sync {
            if !allowReset, let failure = readFailure(gameId: gameId) {
                throw InputConfigurationError.unreadable(failure)
            }
            var value = profile(gameId: gameId)
            mutate(&value)
            let url = Self.url(gameId: gameId)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            profiles[gameId ?? "global"] = value
            loadErrors.removeValue(forKey: gameId ?? "global")
        }
        DispatchQueue.main.async { self.revision += 1 }
    }
}

