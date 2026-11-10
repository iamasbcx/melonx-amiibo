import SwiftUI

/// 广泛扫描仅在这个配对页面显式发起；离开即停止，不影响已连接设备。
struct SteamControllerDiscoveryView: View {
    @ObservedObject private var discovery = SteamControllerBackend.shared.discovery
    @ObservedObject private var controllers = ControllerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(discovery.message)
                    if discovery.isDiscovering {
                        ProgressView("正在搜索")
                        Button("停止搜索") { SteamControllerBackend.shared.endPairing() }
                    } else {
                        Button("搜索 Steam 手柄") { SteamControllerBackend.shared.beginPairing() }
                    }
                } header: {
                    Text("蓝牙配对")
                } footer: {
                    Text("将手柄置于蓝牙配对模式，每次搜索持续 30 秒。已配对设备会自动尝试重连，不会持续扫描其他设备。")
                }
                Section("已连接") {
                    let connected = controllers.allControllers.compactMap { $0 as? SteamController }
                    if connected.isEmpty { Text("尚未连接 Steam 手柄").foregroundStyle(.secondary) }
                    ForEach(connected) { controller in Text(controller.name) }
                }
            }
            .navigationTitle("Steam 手柄配对")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onDisappear { SteamControllerBackend.shared.endPairing() }
    }
}
