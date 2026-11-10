// 输入配置的作用域契约：nil/空 ID 为全局，游戏逐字段覆盖全局。
// 设备选择按稳定设备名称及同名序号保存，不保存随进程改变的对象地址。
import Foundation

nonisolated enum InputConfigurationError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return NSLocalizedString("Input configuration could not be read. Reset the affected mapping before saving changes.", comment: "输入配置读取失败后的恢复提示") + "\n" + detail
        }
    }
}

enum ControllerInputProfile {
    static let selectionKey = "SelectedControllerProfiles"
    static let typeKeys = (0..<8).map { "ControllerTypePlayer\($0)" }

    static func normalizedGameId(_ gameId: String?) -> String? {
        guard let gameId, !gameId.isEmpty, gameId != "0" else { return nil }
        return gameId
    }

    private static func value(for key: String, gameId: String?, defaults: UserDefaults) -> Any? {
        if let gameId = normalizedGameId(gameId), let value = defaults.object(forKey: key + gameId) { return value }
        return defaults.object(forKey: key)
    }

    static func type(index: Int, gameId: String?, defaults: UserDefaults = .standard) -> ControllerType {
        guard typeKeys.indices.contains(index),
              let raw = value(for: typeKeys[index], gameId: gameId, defaults: defaults) as? Int,
              let type = ControllerType.allCases.first(where: { Int($0.rawValue) == raw }) else { return .proController }
        return type
    }

    static func setType(_ type: ControllerType, index: Int, gameId: String?, defaults: UserDefaults = .standard) {
        guard typeKeys.indices.contains(index), ControllerType.allCases.contains(type) else { return }
        defaults.set(Int(type.rawValue), forKey: typeKeys[index] + (normalizedGameId(gameId) ?? ""))
    }

    static func resetType(index: Int, gameId: String?, defaults: UserDefaults = .standard) {
        guard typeKeys.indices.contains(index) else { return }
        defaults.removeObject(forKey: typeKeys[index] + (normalizedGameId(gameId) ?? ""))
    }

    /// nil 表示尚未指定设备，空数组表示明确仅用键盘；两者不能混为一谈。
    static func selection(gameId: String?, defaults: UserDefaults = .standard) -> [String]? {
        value(for: selectionKey, gameId: gameId, defaults: defaults) as? [String]
    }

    static func setSelection(_ keys: [String], gameId: String?, defaults: UserDefaults = .standard) {
        defaults.set(keys, forKey: selectionKey + (normalizedGameId(gameId) ?? ""))
    }

    static func virtualControllerOff(gameId: String?, defaults: UserDefaults = .standard) -> Bool {
        value(for: "virtualControllerOffDefault", gameId: gameId, defaults: defaults) as? Bool ?? ProcessInfo.processInfo.isiOSAppOnMac
    }

    static func hasOverrides(gameId: String, defaults: UserDefaults = .standard) -> Bool {
        ([selectionKey] + typeKeys).contains { defaults.object(forKey: $0 + gameId) != nil }
    }

    static func resetOverrides(gameId: String, defaults: UserDefaults = .standard) {
        for key in [selectionKey] + typeKeys { defaults.removeObject(forKey: key + gameId) }
    }

    /// 启动核心使用的 Options 与设备 attach 使用相同来源，避免控制器类型分叉。
    static func applyTypes(to options: inout Options, gameId: String?, defaults: UserDefaults = .standard) {
        for index in 0..<8 { Options.updateControllerType(index: index, to: type(index: index, gameId: gameId, defaults: defaults), options: &options) }
    }
}
