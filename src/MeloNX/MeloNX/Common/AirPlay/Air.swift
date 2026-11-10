import SwiftUI
import UIKit
import Foundation

class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        Air.shared.attach(window)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let window { Air.shared.detach(window) }
        window = nil
    }
}

@MainActor public class Air {
    static let shared = Air()
    
    public private(set) var connected = false {
        didSet {
            guard oldValue != connected else { return }
            connectionObservers.send(connected)
        }
    }
    private let connectionObservers = RemovableObservers<Bool>()
    private(set) var airWindow: UIWindow?
    var airScreen: UIScreen? { airWindow?.windowScene?.screen }
    private var hostingController: UIHostingController<AnyView>?
    
    func attach(_ window: UIWindow) {
        if let previousWindow = airWindow, previousWindow !== window {
            previousWindow.isHidden = true
            previousWindow.rootViewController = nil
        }
        airWindow = window
        window.windowScene?.screen.overscanCompensation = .none
        presentContent()
    }
    
    func detach(_ window: UIWindow) {
        guard airWindow === window else { return }
        window.isHidden = true
        window.rootViewController = nil
        airWindow = nil
        connected = false
    }
    
    private func presentContent() {
        guard let window = airWindow, let hostingController else { return }
        window.rootViewController = hostingController
        // The primary scene keeps keyboard and controller focus.
        window.isHidden = false
        connected = true
    }
    
    public static func play(_ view: AnyView) {
        let air = Air.shared
        let content = AnyView(view.environmentObject(ThemeManager.shared).withAppTheme())
        if let hostingController = air.hostingController {
            hostingController.rootView = content
        } else {
            air.hostingController = UIHostingController(rootView: content)
        }
        air.presentContent()
    }
    
    public static func stop() {
        let air = Air.shared
        air.airWindow?.isHidden = true
        air.airWindow?.rootViewController = nil
        air.hostingController = nil
        air.connected = false
    }
    
    /// 页面必须在消失时撤销令牌；不会跨游戏保留 SwiftUI 状态和游戏信息。
    public static func connection(_ callback: @escaping (Bool) -> Void) -> UUID {
        let token = shared.connectionObservers.add(callback)
        callback(shared.connected)
        return token
    }

    public static func removeConnection(_ token: UUID) { shared.connectionObservers.remove(token) }
}
