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
                            .if(nativeSettingsManager.showScreenShotButton(true).bool) { view in
                                view
                                    .overlay(alignment: .topLeading) {
                                        InGameConfigView()
                                    }
                            }
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
            .overlay(alignment: .topLeading) {
                GeometryReader { buttonContainer in
                    if !airplay && fastForwardEnabled && fastForwardButtonVisible {
                        FastForwardButton(
                            ryujinxController: ryujinxController,
                            nativeSettingsManager: nativeSettingsManager
                        )
                        .position(
                            fastForwardButtonPoint(
                                in: buttonContainer.size,
                                portrait: portrait
                            )
                        )
                    }
                }
            }
            .onAppear { updateOrientation(portrait) }
            .onChange(of: geo.size) { _ in
                updateOrientation(portrait)
            }
            .onChange(of: portrait) { newValue in
                updateOrientation(newValue)
            }
        }
        // 横屏时齿轮相对整个渲染容器定位到左上边框；竖屏时由游戏画面下方的区域承载。
        .if(!(isPortrait && !isStretched) && nativeSettingsManager.showScreenShotButton(true).bool) { view in
            view
                .overlay(alignment: .topLeading) {
                    InGameConfigView()
                }
        }
        .statusBarHidden(true)
        .ignoresSafeArea(.container, edges: isPortrait && !isStretched ? .horizontal : .all)
    }

    /// 上下两处入口共享同一尺寸；当前几何方向决定唯一显示位置，避免旋转时出现双份叠加。
    private var performanceOverlay: some View {
        PerformanceOverlayView(nativeSettings: nativeSettingsManager, metrics: statisticsHandler.metrics,
                               samplingEnabled: !ryujinxController.isPaused && !ryujinxController.isStopping)
            .padding(4)
            .onTapGesture { menuViewHandler.triggerButton() }
    }

    private func updateOrientation(_ portrait: Bool) {
        isPortrait = portrait
    }

    private var fastForwardEnabled: Bool {
        nativeSettingsManager.setting(forKey: "FastForwardEnabled", default: true).value
    }

    private var fastForwardButtonVisible: Bool {
        nativeSettingsManager.setting(forKey: "FastForwardButtonVisible", default: true).value
    }

    /// 根据当前方向读取归一化坐标，并以按钮中心点放置悬浮按钮。
    /// 旧版四角配置只作为没有坐标时的回退，避免升级后按钮消失。
    private func fastForwardButtonPoint(in size: CGSize, portrait: Bool) -> CGPoint {
        let legacyPosition = nativeSettingsManager.setting(
            forKey: "FastForwardButtonPosition",
            default: "topTrailing"
        ).value
        let fallback = FastForwardButtonPosition.normalized(for: legacyPosition)
        let suffix = portrait ? "Portrait" : "Landscape"
        let storedX: Double = nativeSettingsManager.setting(
            forKey: "FastForwardButton\(suffix)X",
            default: Double(fallback.x)
        ).value
        let storedY: Double = nativeSettingsManager.setting(
            forKey: "FastForwardButton\(suffix)Y",
            default: Double(fallback.y)
        ).value

        let normalizedX = storedX.isFinite ? min(1.0, max(0.0, storedX)) : Double(fallback.x)
        let normalizedY = storedY.isFinite ? min(1.0, max(0.0, storedY)) : Double(fallback.y)
        let buttonSize = nativeSettingsManager.setting(forKey: "FastForwardButtonSize", default: 44.0).value
        let halfButton = CGFloat(min(72.0, max(36.0, buttonSize.isFinite ? buttonSize : 44.0))) / 2
        let edgeInset = halfButton + 12
        let minX = min(edgeInset, size.width / 2)
        let maxX = max(minX, size.width - edgeInset)
        let minY = min(edgeInset, size.height / 2)
        let maxY = max(minY, size.height - edgeInset)

        return CGPoint(
            x: minX + CGFloat(normalizedX) * max(0, maxX - minX),
            y: minY + CGFloat(normalizedY) * max(0, maxY - minY)
        )
    }
}

/// 游戏内按住快进按钮：touch-down 加速，touch-up 或取消时恢复正常速度。
private struct FastForwardButton: View {
    @ObservedObject var ryujinxController: RyujinxController
    @ObservedObject var nativeSettingsManager: NativeSettingsManager
    @State private var isPressed = false

    private var buttonSize: CGFloat {
        let value: Double = nativeSettingsManager.setting(forKey: "FastForwardButtonSize", default: 44.0).value
        return CGFloat(min(72.0, max(36.0, value.isFinite ? value : 44.0)))
    }

    private var buttonOpacity: Double {
        let value: Double = nativeSettingsManager.setting(forKey: "FastForwardButtonOpacity", default: 0.7).value
        return min(1.0, max(0.3, value.isFinite ? value : 0.7))
    }

    private var fastForwardEnabled: Bool {
        nativeSettingsManager.setting(forKey: "FastForwardEnabled", default: true).value
    }

    private var turboMultiplier: Double {
        let value: Double = nativeSettingsManager.setting(forKey: "FastForwardMultiplier", default: 2.0).value
        return value.isFinite ? min(20.0, max(1.0, value)) : 2.0
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isPressed ? Color.accentColor.opacity(0.95) : Color.black.opacity(0.55))
            Image(systemName: "forward.fill")
                .font(.system(size: buttonSize * 0.34, weight: .bold))
                .foregroundStyle(.white)
            if isPressed {
                Text("\(turboMultiplier, specifier: "%.1f")x")
                    .font(.system(size: buttonSize * 0.2, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: buttonSize * 0.28)
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .opacity(buttonOpacity)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginPress() }
                .onEnded { _ in endPress() }
        )
        .onChange(of: ryujinxController.isPaused) { paused in
            if paused { endPress() }
        }
        .onChange(of: ryujinxController.isStopping) { stopping in
            if stopping { endPress() }
        }
        .onChange(of: ryujinxController.isTurboMode) { active in
            if !active { isPressed = false }
        }
        .onChange(of: fastForwardEnabled) { enabled in
            if !enabled { endPress() }
        }
        .onDisappear { endPress() }
    }

    private func beginPress() {
        guard fastForwardEnabled,
              !ryujinxController.isPaused,
              !ryujinxController.isStopping,
              !isPressed else { return }

        isPressed = true
        // 核心使用整数百分比，避免浮点时钟误差；UI 输入保留一位小数。
        ryujinxController.setTurboMultiplier(Int((turboMultiplier * 100).rounded()))
        ryujinxController.setTurboMode(true)
        if !ryujinxController.isTurboMode {
            isPressed = false
        }
    }

    private func endPress() {
        guard isPressed || ryujinxController.isTurboMode else { return }

        isPressed = false
        ryujinxController.setTurboMode(false)
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
