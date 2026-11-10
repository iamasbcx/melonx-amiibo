// 设备选择只编辑指定范围；运行中由外层暂停会话在关闭整个输入页时统一应用。
import SwiftUI

struct ScopedControllerSelectionView: View {
    let gameId: String?
    @ObservedObject private var controllerManager = ControllerManager.shared
    @StateObject private var settings: NativeSettingsManager
    @State private var showingKeyboard = false
    @State private var showingSteamPairing = false

    init(gameId: String?) {
        let normalizedGameId = ControllerInputProfile.normalizedGameId(gameId)
        self.gameId = normalizedGameId
        self._settings = StateObject(wrappedValue: NativeSettingsManager(normalizedGameId, normalizedGameId != nil))
    }

    private var selected: [String] { controllerManager.selectedControllerIds(gameId: gameId) }

    var body: some View {
        Section {
            if selected.isEmpty {
                Text("未选择手柄，将使用键盘").foregroundColor(.secondary)
            }
            ForEach(Array(selected.enumerated()), id: \.offset) { index, id in
                ControllerRow(index: index, controllerId: id, gameId: gameId, controllerManager: controllerManager)
            }
            let available = controllerManager.allControllers.filter { !selected.contains($0.id) }
            if !available.isEmpty {
                Menu {
                    ForEach(available) { controller in
                        Button(controller.name) { controllerManager.selectController(controller, gameId: gameId) }
                    }
                } label: {
                    Label("添加手柄", systemImage: "plus.circle.fill")
                }
            }
            Button("Map Keyboard") { showingKeyboard = true }
                .sheet(isPresented: $showingKeyboard) { KeyboardConfigView(gameId: gameId) }
            Button("配对 Steam 手柄") { showingSteamPairing = true }
                .sheet(isPresented: $showingSteamPairing) { SteamControllerDiscoveryView() }
        } header: {
            Text("手柄选择")
        } footer: {
            Text("Controller selection, player types, mappings, and keyboard bindings use the selected editing scope.")
        }
    }
}
