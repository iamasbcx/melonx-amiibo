//
//  LoadingOverlayView.swift
//  MeloNX
//
//  Created by Stossy11 on 07/11/2025.
//

import SwiftUI
import Foundation
import Combine

/// 应用级加载进度只注册一次；页面的出现和消失不再留下原生回调持有的旧模型。
@MainActor
final class LoadingOverlayViewModel: ObservableObject {
    static let shared = LoadingOverlayViewModel()
    @Published var isLoading = true
    @Published var isAnimating = false
    @Published private(set) var progress = LoadingProgressSnapshot.empty
    var isShaderOrPTC: Bool { progress.visible && !progress.type.isEmpty }
    var loadingType: String { progress.type }
    var currentProgress: Int { progress.current }
    var totalProgress: Int { progress.total }
    private let session = CallbackSessionEpoch()
    private var registered = false

    func beginSession() {
        session.begin()
        progress = .empty
        isLoading = true
        guard !registered else { return }
        registered = true
        let session = session
        CallbackManager.register(name: "ProgressWithPTCorShaderCache") { @Sendable [weak self, session] packet in
            guard let token = session.current(), let pointer = packet.ptr,
                  packet.len > 0, packet.len <= 1024 else { return }
            let data = Data(bytesNoCopy: pointer, count: Int(packet.len), deallocator: .none)
            guard let next = LoadingProgressSnapshot.decode(data) else { return }
            DispatchQueue.main.async { [weak self, session] in
                guard let self, session.accepts(token) else { return }
                if self.progress != next { self.progress = next }
            }
        }
    }

    func endSession() {
        session.end()
        isAnimating = false
        progress = .empty
    }
}

struct LoadingOverlayView: View {
    let game: GameInfo?
    let showLogs: Bool
    
    @ObservedObject private var vm = LoadingOverlayViewModel.shared
    @State private var contentVisible = false
    
    private let clumpWidth: CGFloat = 80
    
    var body: some View {
        if vm.isLoading {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                
                GeometryReader { geo in
                    loadingContent(geo: geo)
                }
            }
            .opacity(contentVisible ? 1 : 0)
            .onAppear {
                vm.isAnimating = true
                withAnimation(.easeIn(duration: 0.3)) {
                    contentVisible = true
                }
            }
        }
    }
    
    @ViewBuilder
    private func loadingContent(geo: GeometryProxy) -> some View {
        HStack(spacing: geo.size.width * 0.04) {
            if let icon = game?.icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: min(geo.size.width * 0.22, 220),
                        height: min(geo.size.width * 0.22, 220)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 12)
            }
            
            VStack(alignment: .leading, spacing: geo.size.height * 0.018) {
                Text(String(localized: "Loading \(game?.titleName ?? String(localized: "Game"))"))
                    .font(.system(
                        size: min(geo.size.width * 0.038, 28),
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(.white)
                
                LoadingProgressBar(
                    screenGeometry: geo,
                    isAnimating: $vm.isAnimating,
                    isShaderOrPTC: .constant(vm.isShaderOrPTC),
                    currentProgress: .constant(vm.currentProgress),
                    totalProgress: .constant(vm.totalProgress),
                    clumpWidth: clumpWidth
                )
                
                if vm.isShaderOrPTC {
                    progressLabel(geo: geo)
                }
            }
        }
        .padding(.horizontal, geo.size.width * 0.06)
        .padding(.vertical, geo.size.height * 0.05)
        .position(
            x: geo.size.width / 2,
            y: geo.size.height / 2
        )
    }
    
    private func progressLabel(geo: GeometryProxy) -> some View {
        HStack(spacing: 4) {
            Text(vm.loadingType + ": ")
                .fontWeight(.medium)
            Text("\(vm.currentProgress)")
                .monospacedDigit()
            Text("/")
                .opacity(0.5)
            Text("\(vm.totalProgress)")
                .monospacedDigit()
        }
        .font(.system(size: min(geo.size.width * 0.025, 13)))
        .foregroundStyle(.white.opacity(0.55))
    }
}
