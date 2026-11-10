//
//  EmulationView.swift
//  MeloNX
//
//  Created by Stossy11 on 23/4/2026.
//

import SwiftUI
import Melo_Controller
import Combine

struct EmulationView: View {
    var game: GameInfo

    /// 从游戏信息创建游戏内视图；其余状态由 SwiftUI 属性包装器初始化。
    init(game: GameInfo) {
        self.game = game
    }
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @StateObject var controllerManager: ControllerManager = .shared
    @StateObject var statisticsHandler: StatisticsHandler = .init()
    @StateObject private var nativeSettingsManager: NativeSettingsManager = .shared
    
    @State var isConnected = false
    @Environment(\.scenePhase) private var scenePhase

    /// 透明度只控制显示效果，读取旧配置时限制到有效范围，避免 alpha 过低让 UIKit 跳过输入视图。
    private var controllerOpacity: Double {
        let raw: Double = nativeSettingsManager
            .setting(forKey: "On-ScreenControllerOpacity", default: 1.0)
            .value
        guard raw.isFinite else { return 1.0 }
        return min(1.0, max(0.05, raw))
    }

    private var touchLookEnabled: Bool {
        nativeSettingsManager.setting(forKey: "TouchLookEnabled", default: false).value
    }

    private var touchLookSensitivity: CGFloat {
        let value = CGFloat(nativeSettingsManager.setting(forKey: "TouchLookSensitivity", default: 0.012).value)
        return value.isFinite ? min(0.05, max(0.001, value)) : 0.012
    }

    private var touchLookInvertX: Bool {
        nativeSettingsManager.setting(forKey: "TouchLookInvertX", default: false).value
    }

    private var touchLookInvertY: Bool {
        nativeSettingsManager.setting(forKey: "TouchLookInvertY", default: false).value
    }
    
    @ViewBuilder
    func emulationView(_ airplay: Bool = false) -> some View {
        if airplay { MetalViewRepresentable(showView: true, gameId: game.titleId).ignoresSafeArea().frame(maxWidth: .infinity, maxHeight: .infinity) } else {
            MetalViewContainer(showView: !isConnected, airplay: airplay, gameId: game.titleId, ryujinxController: ryujinxController, statisticsHandler: statisticsHandler, nativeSettingsManager: nativeSettingsManager)
                .overlay {
                    if controllerManager.hasVirtualController() && !airplay {
                        ControllerView(
                            controller: VirtualControllerManager.shared,
                            isEditing: false,
                            gameId: game.titleId,
                            gameName: game.titleName,
                            touchLookEnabled: touchLookEnabled,
                            touchLookSensitivity: touchLookSensitivity,
                            touchLookInvertX: touchLookInvertX,
                            touchLookInvertY: touchLookInvertY,
                            visualOpacity: controllerOpacity
                        )
                            .ignoresSafeArea(.all, edges: .vertical)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    var body: some View {
        Group {
            emulationView()
                .onAppear() {
                    // 轮询绑定整个游戏页面；Amiibo 选择 sheet 关闭后仍能自动提交。
                    AmiiboService.shared.start(titleId: game.titleId)
                    statisticsHandler.registerPush()
                    
                    self.isConnected = Air.shared.connected
                    Air.shared.connectionCallbacks.append { self.isConnected = $0 }
                    
                    Air.play(AnyView(emulationView(true)))
                }
                .onDisappear {
                    AmiiboService.shared.stop()
                }
                .onChange(of: scenePhase) { phase in
                    AmiiboService.shared.setApplicationActive(phase == .active)
                }
                .if(!statisticsHandler.started) { view in
                    view
                        .overlay {
                            LoadingOverlayView(game:  game, showLogs: false)
                                .onDisappear() {
                                    menuViewHandler.triggerButton()
                                }
                        }
                }
        }
    }
}
