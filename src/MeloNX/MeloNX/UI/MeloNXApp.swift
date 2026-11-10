//
//  MeloNXApp.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import SwiftUI
import SDL3
import AVFoundation
import GameController

func configureAudioSession() {
    do {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playback,
            options: .mixWithOthers
        )
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    } catch {
        print("Audio session error: \(error.localizedDescription)")
    }
}

var environment: [EnvironmentVariable] = [
    //EnvironmentVariable(string: "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", value: "0"),
    EnvironmentVariable(string: "MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", value: "32"),
   //  EnvironmentVariable(string: "MVK_CONFIG_SHADER_COMPRESSION_ALGORITHM", value: "1"),
]

func initEnvironmentVariables() {
    if let device = MTLCreateSystemDefaultDevice() {
        environment.append(contentsOf: [
            .init(string: "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", value: device.argumentBuffersSupport.rawValue >= MTLArgumentBuffersTier.tier2.rawValue ? "1" : "0")
        ])
        
        if #available(iOS 17, macOS 14, *) {
            environment.append(contentsOf: [
                .init(string: "MVK_SUPPORTS_EXT_DYN_STATE", value: device.supportsFamily(.apple4) ? "1" : "0")
            ])
        } else {
            environment.append(contentsOf: [
                .init(string: "MVK_SUPPORTS_EXT_DYN_STATE", value: "0")
            ])
        }
    }
    
    if #available(iOS 19, *) {
        environment.append(contentsOf: [
            .init(string: "HAS_TXM", value: ProcessInfo.processInfo.hasTXM && !ProcessInfo.processInfo.isiOSAppOnMac ? "1" : "0"),
            .init(string: "DUAL_MAPPED_JIT", value: !ProcessInfo.processInfo.isiOSAppOnMac ? "1" : "0")
        ])
    } else {
        environment.append(contentsOf: [
            .init(string: "HAS_TXM", value: "0"),
            .init(string: "DUAL_MAPPED_JIT", value: "0")
        ])
    }
    
    for env in environment { env.set() }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SDL_SetMainReady()
        SDL_SetiOSEventPump(true)
        SDL_Init(SDL_INIT_EVENTS)
        JIT26BreakpointHandler()
        initEnvironmentVariables()
        Ryujinx.initialize()
        CrashHandlerInstaller.install()
        ThemeManager.shared.applyUIKitAppearance()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        configureAudioSession()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        report_memory_pressure(0)
    }
}

class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MainViewController()
        self.window = window
        window.makeKeyAndVisible()
        open(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(URLContexts)
    }

    private func open(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            AppEnvironment.handleDeepLink(context.url, ryujinxController: .shared)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        ControllerManager.shared.setApplicationActive(true)
        let controller = RyujinxController.shared
        guard !controller.isStopping else { return }
        if controller.isRunning.isRunning() {
            if !controller.wasManuallyPaused { controller.isPaused = false }
        } else {
            _ = controller.attemptToMapDualMapping()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        ControllerManager.shared.setApplicationActive(false)
        pauseEmulation()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        ControllerManager.shared.setApplicationActive(false)
        RyujinxController.shared.flushPendingSettingsSaves()
        pauseEmulation()
    }

    /// 使用界面方向完成更新事件，避免 UIDevice 的 faceUp/unknown 或外接显示器覆盖手机方向。
    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
                     interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
                     traitCollection previousTraitCollection: UITraitCollection) {
        guard windowScene.session.role == .windowApplication else { return }
        ControllerManager.shared.refreshInputResources(interfaceOrientation: windowScene.interfaceOrientation)
    }

    private func pauseEmulation() {
        let controller = RyujinxController.shared
        if controller.isRunning.isRunning(), !controller.isStopping, !controller.wasManuallyPaused {
            controller.isPaused = true
        }
    }
}


class MainViewController: GCEventViewController {
    private let host = UIHostingController<AnyView>(rootView: AnyView(
        AppRootView()
            .environmentObject(RyujinxController.shared)
            .environmentObject(ThemeManager.shared)
            .withAppTheme()
    ))

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("Use init()")
    }
    
    override var childForStatusBarStyle: UIViewController? { host }
    override var childForStatusBarHidden: UIViewController? { host }
    override var childForHomeIndicatorAutoHidden: UIViewController? { host }
    override var childViewControllerForPointerLock: UIViewController? { host }

    override func viewDidLoad() {
        super.viewDidLoad()

        controllerUserInteractionEnabled = false

        addChild(host)

        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        view.addSubview(host.view)
        host.didMove(toParent: self)

        // 外接显示器由 Info.plist 的场景配置注册，连接时进入 ExternalDisplaySceneDelegate。
        // 构建固定使用 Xcode 26.2，不引用该 SDK 尚未提供的场景附件 API。
    }
}

private struct AppRootView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @AppStorage("hasSetupFinished") private var hasSetupFinished = false
    @AppStorage("lastAppversion") private var lastAppversion = Data()

    var body: some View {
        ContentView()
            .onAppear {
                var previousVersion: Float = 0
                if lastAppversion.count == MemoryLayout<Float>.size {
                    _ = withUnsafeMutableBytes(of: &previousVersion) { lastAppversion.copyBytes(to: $0) }
                }
                let currentVersion = Float(Bundle.main.versionNumber) ?? .zero
                if previousVersion < currentVersion {
                    var value = currentVersion
                    lastAppversion = Data(bytes: &value, count: MemoryLayout<Float>.size)
                    hasSetupFinished = false
                }
            }
            .sheet(isPresented: .constant(!hasSetupFinished)) {
                SetupView {
                    hasSetupFinished = true
                    ryujinxController.loadGames()
                }
                .interactiveDismissDisabled()
                .withAppTheme()
            }
    }
}
