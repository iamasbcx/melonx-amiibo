import SwiftUI
import Combine

/// 手柄包的作用域设置。键名与宿主的输入设置一致：游戏值覆盖全局值，编辑只写当前范围。
final class ControllerPreferences: ObservableObject {
    let gameId: String
    private var changes: AnyCancellable?

    init(gameId: String?) {
        self.gameId = gameId == "0" ? "" : (gameId ?? "")
        changes = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func value<T>(_ key: String, default fallback: T) -> T {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key + gameId) as? T
            ?? defaults.object(forKey: key) as? T ?? fallback
    }

    private func set(_ value: Any, forKey key: String) {
        objectWillChange.send()
        UserDefaults.standard.set(value, forKey: key + gameId)
        if !gameId.isEmpty { UserDefaults.standard.set(true, forKey: gameId) }
    }

    var scale: Double {
        get {
            let raw = value("On-ScreenControllerScale", default: 1.0)
            return raw.isFinite ? min(3, max(0.1, raw)) : 1
        }
        set { set(newValue.isFinite ? min(3, max(0.1, newValue)) : 1, forKey: "On-ScreenControllerScale") }
    }

    var stickButton: Bool { value("stickButton", default: false) }
    var buttonSlide: Bool {
        get { value("buttonSlide", default: true) }
        set { set(newValue, forKey: "buttonSlide") }
    }

    var snapshot: ControllerAppearance {
        ControllerAppearance(scale: scale, buttonSlide: buttonSlide)
    }
}

/// 子控件共享同一快照，避免各自通过全局 AppStorage 绕过当前游戏设置。
struct ControllerAppearance {
    var scale: Double = 1
    var buttonSlide: Bool = true
}

private struct ControllerAppearanceKey: EnvironmentKey {
    static let defaultValue: ControllerAppearance? = nil
}

extension EnvironmentValues {
    var controllerAppearance: ControllerAppearance? {
        get { self[ControllerAppearanceKey.self] }
        set { self[ControllerAppearanceKey.self] = newValue }
    }
}
