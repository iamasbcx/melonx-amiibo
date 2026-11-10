//
//  InGameConfigView.swift
//  MeloNX
//
//  Created by Stossy11 on 7/7/2026.
//

import SwiftUI
import Melo_Controller
import Combine

/// 菜单仅发送请求，弹层由不随横竖屏分支卸载的 EmulationView 持有。
struct InGameSettingsRequest: Equatable {
    enum Destination: Equatable { case input, layout }
    let destination: Destination
    let scope: InputSettingsScope
}

class InGameConfigView_MenuView: ObservableObject {
    @Published var hideTask: Task<Void, Never>? = nil
    @Published var showButton: Bool = false
    @Published var settingsRequest: InGameSettingsRequest?

    static var shared: InGameConfigView_MenuView = .init()

    func triggerButton() {
        hideTask?.cancel()

        showButton = true

        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            if !Task.isCancelled {
                showButton = false
            }
        }
    }
}

struct InGameConfigView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject var controllerManager: ControllerManager = .shared
    @StateObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @State var rotationlock: Bool = false
    @State private var showAmiiboSelection: Bool = false



    var body: some View {
        Menu {
            menuButton
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding()
        // 闲置时淡化但保持可点；关闭原生触屏或扩大滑动区域都不能使设置入口消失。
        .opacity(menuViewHandler.showButton ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.6), value: menuViewHandler.showButton)
        .sheet(isPresented: $showAmiiboSelection) {
            AmiiboSelectionView()
        }
    }


    @ViewBuilder
    private var menuButton: some View {
        Button {
            ryujinxController.isPaused.toggle()
            ryujinxController.wasManuallyPaused = ryujinxController.isPaused
        } label: {
            Label {
                Text(ryujinxController.isPaused ? String(localized: "Play") : String(localized: "Pause"))
            } icon: {
                Image(systemName: ryujinxController.isPaused ? "play.circle" : "pause.circle")
            }
        }

        Button {
            menuViewHandler.settingsRequest = InGameSettingsRequest(destination: .input, scope: availableScopes.first ?? .global)
        } label: {
            Label {
                Text(LocalizedStringKey("Configure Controllers"))
            } icon: {
                Image(systemName: "gamecontroller")
            }
        }

        settingsMenu("Input Settings", icon: "slider.horizontal.3", destination: .input)
        settingsMenu("Edit Virtual Controller Layout", icon: "formfitting.gamecontroller", destination: .layout)

        // 目录只提供虚拟身份；打开菜单时继续运行游戏，避免阻塞来宾读取请求。
        Button {
            if case .started(let game, _) = ryujinxController.isRunning {
                AmiiboService.shared.start(titleId: game.titleId)
                AmiiboService.shared.refreshCatalog()
            }
            showAmiiboSelection = true
        } label: {
            Label(LocalizedStringKey("虚拟 amiibo"), systemImage: "person.crop.circle.badge.checkmark")
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            Button {
                rotationlock.toggle()
                if rotationlock {
                    OrientationManager.lockCurrentOrientation(UIDevice.current.orientation)
                } else {
                    OrientationManager.lockOrientation(.all, rotateTo: UIDevice.current.orientation)
                }
            } label: {
                Label {
                    Text(LocalizedStringKey("Rotation Lock"))
                } icon: {
                    Image(systemName: rotationlock ? "lock" : "lock.open")
                }
            }
        }


        Button(role: .destructive) {
            ryujinxController.stopGame()
        } label: {
            Label {
                Text(LocalizedStringKey(ryujinxController.isStopping ? "Exiting..." : "Exit Game"))
            } icon: {
                Image(systemName: ryujinxController.isStopping ? "hourglass" : "x.circle")
            }
        }
        .disabled(ryujinxController.isStopping)

    }

    private var availableScopes: [InputSettingsScope] {
        if case .started(let game, _) = ryujinxController.isRunning,
           ControllerInputProfile.normalizedGameId(game.titleId) != nil {
            return InputSettingsScope.allCases
        }
        return [.global]
    }

    private func settingsMenu(_ title: String, icon: String, destination: InGameSettingsRequest.Destination) -> some View {
        Menu {
            ForEach(availableScopes) { scope in
                Button(LocalizedStringKey(scope.title)) {
                    menuViewHandler.settingsRequest = InGameSettingsRequest(destination: destination, scope: scope)
                }
            }
        } label: {
            Label(LocalizedStringKey(title), systemImage: icon)
        }
        .disabled(ryujinxController.isStopping)
    }

}
