//
//  MetalViewContainer.swift
//  MeloNX
//
//  Created by Stossy11 on 26/5/2026.
//

import SwiftUI

struct MetalViewContainer: View {
    
    var showView: Bool = true
    var airplay: Bool = false
    @State var isPortrait: Bool = false

    @ObservedObject var ryujinxController: RyujinxController
    @ObservedObject var statisticsHandler: StatisticsHandler
    @ObservedObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @ObservedObject var nativeSettingsManager: NativeSettingsManager
    
    var overlayAlignment: Alignment {
        nativeSettingsManager.performancePosition(PerformanceOverlayPosition.topRight).value.alignment
    }

    var body: some View {
        let aspectRatio = ryujinxController.currentSettings.aspectRatio
        let isStretched = aspectRatio == .stretched
        
        GeometryReader { geo in
            let aspectRatio = ryujinxController.currentSettings.aspectRatio
            let portrait = geo.size.height > geo.size.width
            let isStretched = aspectRatio == .stretched
            let size = targetSize(in: geo.size, aspectRatio: aspectRatio)
            let showPerformance = nativeSettingsManager.performacehud(false).bool && !airplay
            let showPerformanceBelow = showPerformance && portrait && !isStretched && nativeSettingsManager.overlayBelowScreen(true).bool

            ZStack {
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture {
                        menuViewHandler.triggerButton()
                    }

                VStack(spacing: 0) {
                    MetalViewRepresentable(showView: showView)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(true)

                    if portrait && !isStretched {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: overlayAlignment) {
                                if showPerformanceBelow { performanceOverlay }
                            }
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: portrait && !isStretched ? .top : .center
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: overlayAlignment) {
                if showPerformance && !showPerformanceBelow { performanceOverlay }
            }
            .onAppear { updateOrientation(portrait) }
            .onChange(of: geo.size) { _ in
                updateOrientation(portrait)
            }
            .onChange(of: portrait) { newValue in
                updateOrientation(newValue)
            }
        }
        .statusBarHidden(true)
        .ignoresSafeArea(.container, edges: isPortrait && !isStretched ? .horizontal : .all)
    }

    /// 上下两处入口共享同一尺寸；当前几何方向决定唯一显示位置，避免旋转时出现双份叠加。
    private var performanceOverlay: some View {
        PerformanceOverlayView(nativeSettings: nativeSettingsManager, statisticsHandler: statisticsHandler)
            .padding(4)
            .onTapGesture { menuViewHandler.triggerButton() }
    }

    private func updateOrientation(_ portrait: Bool) {
        isPortrait = portrait
    }
}

func targetSize(in containerSize: CGSize, aspectRatio: AspectRatio) -> CGSize {
    guard containerSize.width > 0, containerSize.height > 0 else {
        return .zero
    }

    let targetAspect: CGFloat

    switch aspectRatio {
    case .fixed4x3:   targetAspect = 4.0  / 3.0
    case .fixed16x9:  targetAspect = 16.0 / 9.0
    case .fixed16x10: targetAspect = 16.0 / 10.0
    case .fixed21x9:  targetAspect = 21.0 / 9.0
    case .fixed32x9:  targetAspect = 32.0 / 9.0
    default:  return containerSize
    }
    
    let containerAspect = containerSize.width / containerSize.height
    
    if containerAspect > targetAspect {
        return CGSize(width: containerSize.height * targetAspect, height: containerSize.height)
    } else {
        return CGSize(width: containerSize.width, height: containerSize.width / targetAspect)
    }
}

func isScreenAspectRatio(
    _ targetWidth: CGFloat,
    _ targetHeight: CGFloat,
    in size: CGSize,
    tolerance: CGFloat = 0.05
) -> Bool {
    let w = max(size.width, size.height)
    let h = min(size.width, size.height)
    return abs((w / h) - (targetWidth / targetHeight)) < tolerance
}
