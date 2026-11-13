import Foundation
import Combine
import SwiftUI
import UIKit

/// 局域网网页文件管理器的界面状态和服务生命周期协调器。
///
/// 服务对象由核心模块提供；本类型只负责主线程上的启动、停止、地址展示和场景切换。
/// 传输任务的断点数据由服务端写入临时目录，进入后台时不把未完成文件改名为正式文件。
@MainActor
final class LANFileManagerCoordinator: ObservableObject {
    static let shared = LANFileManagerCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var address: URL?
    @Published private(set) var errorMessage: String?
    @Published var isAddressSheetPresented = false

    private var server: LANFileServer?
    /// 服务运行期间持有一个 lease，保证请求体读取和响应发送期间不会自动熄屏。
    private var serviceLease: TransferActivityLease?
    private var shouldResumeAfterForeground = false

    private init() {}

    /// 启动局域网服务并返回可复制的浏览器地址。
    func startService(presentAddress: Bool = true) {
        guard !isRunning else {
            if presentAddress { isAddressSheetPresented = true }
            return
        }

        do {
            let server: LANFileServer
            if let existing = self.server {
                // 后台暂停只关闭 listener，复用对象可保留上传会话和端口。
                server = existing
            } else {
                server = try LANFileServer(rootURL: URL.documentsDirectory)
                self.server = server
            }
            let serverAddress = try server.start()
            self.address = serverAddress
            self.isRunning = true
            self.errorMessage = nil
            if serviceLease == nil {
                serviceLease = TransferActivityCoordinator.shared.acquire()
            }
            if presentAddress { self.isAddressSheetPresented = true }
        } catch {
            // 启动失败时保留已经创建的对象，便于下一次重试并复用原端口。
            self.address = nil
            self.isRunning = false
            self.errorMessage = error.localizedDescription
        }
    }

    /// 停止服务。停止不会主动删除可恢复的上传临时文件。
    func stopService() {
        server?.stop()
        TransferActivityCoordinator.shared.suspendForBackground()
        serviceLease = nil
        server = nil
        address = nil
        isRunning = false
        shouldResumeAfterForeground = false
    }

    /// 场景进入后台时暂停监听；iOS 不保证后台可以完成 10–40GB 传输。
    func handleSceneDidEnterBackground() {
        guard isRunning else { return }
        shouldResumeAfterForeground = true
        TransferActivityCoordinator.shared.suspendForBackground()
        server?.stop()
        serviceLease = nil
        address = nil
        isRunning = false
    }

    /// 场景回到前台后恢复用户此前主动开启的服务。
    func handleSceneDidBecomeActive() {
        guard shouldResumeAfterForeground else { return }
        shouldResumeAfterForeground = false
        startService(presentAddress: false)
    }

    func clearError() {
        errorMessage = nil
    }
}

/// 局域网服务的 IP 与端口展示页，同时提供复制地址和停止服务入口。
struct LANFileManagerAddressView: View {
    @ObservedObject var coordinator: LANFileManagerCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                if let address = coordinator.address?.absoluteString {
                    Text("请在同一 Wi-Fi 下的电脑或手机浏览器打开")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(address)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = address
                        } label: {
                            Label("复制地址", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            coordinator.stopService()
                            dismiss()
                        } label: {
                            Label("停止服务", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Label("服务已暂停或停止", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                    Button("启动服务") {
                        coordinator.startService()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("服务运行期间会保持屏幕常亮。请保持 MeloNX 前台；切到后台后服务暂停，回到前台可继续上传未完成分片。传输完成后请停止服务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("局域网网页文件管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
