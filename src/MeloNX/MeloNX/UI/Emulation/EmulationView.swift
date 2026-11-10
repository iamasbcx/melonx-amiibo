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
    @State private var inputScope: InputSettingsScope?
    @State private var layoutScope: InputSettingsScope?
    @State private var pendingLayoutScope: InputSettingsScope?
    @State private var editingInput = false
    @State private var pausedBeforeEditing = false
    @State private var manuallyPausedBeforeEditing = false
    @State private var layoutRevision = 0
    @State private var didConfigurePresentation = false
    @Environment(\.scenePhase) private var scenePhase

    /// 未知标题（空值或 0）统一使用全局，避免布局和输入配置写入不同范围。
    private var inputGameId: String? { ControllerInputProfile.normalizedGameId(game.titleId) }

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
        CGFloat(TouchLookSensitivityConfiguration.coefficient(from: nativeSettingsManager))
    }

    private var touchLookInvertX: Bool {
        nativeSettingsManager.setting(forKey: "TouchLookInvertX", default: false).value
    }

    private var touchLookInvertY: Bool {
        nativeSettingsManager.setting(forKey: "TouchLookInvertY", default: false).value
    }
    
    @ViewBuilder
    func emulationView(_ airplay: Bool = false) -> some View {
        if airplay { MetalViewRepresentable(showView: true).ignoresSafeArea().frame(maxWidth: .infinity, maxHeight: .infinity) } else {
            MetalViewContainer(showView: !isConnected, airplay: airplay, ryujinxController: ryujinxController, statisticsHandler: statisticsHandler, nativeSettingsManager: nativeSettingsManager)
                .overlay {
                    if controllerManager.hasVirtualController() && !airplay && !editingInput {
                        ControllerView(
                            controller: VirtualControllerManager.shared,
                            isEditing: false,
                            gameId: inputGameId,
                            gameName: game.titleName,
                            touchLookEnabled: touchLookEnabled,
                            touchLookSensitivity: touchLookSensitivity,
                            touchLookInvertX: touchLookInvertX,
                            touchLookInvertY: touchLookInvertY,
                            visualOpacity: controllerOpacity,
                            onTouchLookBegan: menuViewHandler.triggerButton
                        )
                            .id(layoutRevision)
                            .ignoresSafeArea(.all, edges: .vertical)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 菜单位于输入层之上且遵守安全区，全屏滑动区域不能遮住齿轮。
                .overlay(alignment: .topLeading) {
                    if nativeSettingsManager.showScreenShotButton(true).bool && !editingInput {
                        InGameConfigView()
                    }
                }
        }
    }
    
    var body: some View {
        Group {
            emulationView()
                .onAppear() {
                    // 轮询绑定整个游戏页面；Amiibo 选择 sheet 关闭后仍能自动提交。
                    AmiiboService.shared.start(titleId: game.titleId)
                    self.isConnected = Air.shared.connected
                    // 全屏编辑返回会再次出现；不要重复注册回调或重建外接屏渲染视图。
                    if !didConfigurePresentation {
                        didConfigurePresentation = true
                        statisticsHandler.registerPush()
                        Air.shared.connectionCallbacks.append { self.isConnected = $0 }
                        Air.play(AnyView(emulationView(true)))
                    }
                }
                .onDisappear {
                    AmiiboService.shared.stop()
                    // 全屏编辑器呈现也可能触发消失；只有实际退出游戏时才清理会话。
                    if !isCurrentGameRunning { finishInputEditing(resume: false) }
                }
                .onChange(of: scenePhase) { phase in
                    AmiiboService.shared.setApplicationActive(phase == .active)
                    if phase == .active && editingInput && isCurrentGameRunning {
                        ryujinxController.isPaused = true
                    }
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
        // 等待 @Published 的实际状态提交后再消费，避免在 willSet 发布期间重入 setter。
        .onChange(of: menuViewHandler.settingsRequest) { request in
            guard let request else { return }
            menuViewHandler.settingsRequest = nil
            guard isCurrentGameRunning, !editingInput else { return }
            beginInputEditing()
            switch request.destination {
            case .input: inputScope = request.scope
            case .layout: layoutScope = request.scope
            }
        }
        .sheet(item: $inputScope, onDismiss: inputSettingsDismissed) { scope in
            InputControlsSettingsView(game: game, scope: scope) { selectedScope in
                pendingLayoutScope = selectedScope
                inputScope = nil
            }
        }
        .fullScreenCover(item: $layoutScope, onDismiss: { finishInputEditing() }) { scope in
            ControllerView(
                controller: VirtualControllerManager.shared,
                isEditing: true,
                gameId: scope == .currentGame ? inputGameId : nil,
                gameName: scope == .currentGame && inputGameId != nil ? game.titleName : nil
            )
            .interactiveDismissDisabled(true)
        }
        .onChange(of: ryujinxController.isStopping) { stopping in
            if stopping {
                pendingLayoutScope = nil
                inputScope = nil
                layoutScope = nil
                finishInputEditing(resume: false)
            }
        }
    }

    private var isCurrentGameRunning: Bool {
        guard !ryujinxController.isStopping,
              case .started(let activeGame, _) = ryujinxController.isRunning else { return false }
        return activeGame.titleId == game.titleId
    }

    private func beginInputEditing() {
        pausedBeforeEditing = ryujinxController.isPaused
        manuallyPausedBeforeEditing = ryujinxController.wasManuallyPaused
        InGameInputSession.shared.setSuspended(true)
        controllerManager.allControllers.forEach { $0.releaseInputs() }
        (Ryujinx.emulationView as? MetalView)?.resetTouchTracking()
        editingInput = true
        // App 的前后台处理尊重手动暂停；编辑期间借用此标记，结束时恢复原值。
        ryujinxController.wasManuallyPaused = true
        ryujinxController.isPaused = true
    }

    private func inputSettingsDismissed() {
        if let nextScope = pendingLayoutScope, isCurrentGameRunning {
            pendingLayoutScope = nil
            layoutScope = nextScope
        } else {
            pendingLayoutScope = nil
            finishInputEditing()
        }
    }

    private func finishInputEditing(resume: Bool = true) {
        guard editingInput else { return }
        controllerManager.allControllers.forEach { $0.releaseInputs() }
        if resume && isCurrentGameRunning {
            controllerManager.applyInputProfile(gameId: inputGameId)
        }
        if let metalView = Ryujinx.emulationView as? MetalView {
            metalView.resetTouchTracking()
        }
        // 运行态视图重新加载横/竖屏布局，不能继续使用打开编辑器前的缓存。
        layoutRevision += 1
        editingInput = false
        guard resume, isCurrentGameRunning else { return }
        InGameInputSession.shared.setSuspended(false)
        ryujinxController.wasManuallyPaused = manuallyPausedBeforeEditing
        ryujinxController.isPaused = pausedBeforeEditing || scenePhase != .active
    }
}
