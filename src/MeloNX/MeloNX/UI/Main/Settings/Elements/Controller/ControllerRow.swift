//
//  ControllerRow.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI

struct ControllerRow: View {
    let index: Int
    let controllerId: String
    let gameId: String?
    @ObservedObject var controllerManager: ControllerManager
    @EnvironmentObject var ryujinxController: RyujinxController

    @State private var showingMapping = false

    private var controller: BaseController? {
        controllerManager.controllerAndIndexForString(controllerId)?.0
    }

    private var controllerIndex: Int? {
        controllerManager.controllerAndIndexForString(controllerId)?.1
    }

    var body: some View {
        guard let controller else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundColor(.accentColor)

                    Text("玩家 \(index + 1)：\(controller.name)")
                        .lineLimit(1)

                    Spacer()

                    Button {
                        showingMapping = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Controller Settings")

                    Button {
                        controllerManager.deselectController(controller, gameId: gameId)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)

            }
            .sheet(isPresented: $showingMapping) {
                ControllerMappingView(controller: controller, playerIndex: index, gameId: gameId)
                    .environmentObject(ryujinxController)
            }
            .contextMenu {
                // 类型与映射共享明确的编辑作用域，不依赖当前运行游戏。
                Button {
                    showingMapping = true
                } label: {
                    Label("Controller Settings", systemImage: "slider.horizontal.3")
                }
            }
        )
    }
}
