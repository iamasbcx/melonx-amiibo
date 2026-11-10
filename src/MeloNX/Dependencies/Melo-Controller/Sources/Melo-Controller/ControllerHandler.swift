//
//  ControllerHandler.swift
//  Melo-Controller
//
//  Created by Stossy11 on 8/3/2026.
//

import SwiftUI

@MainActor
class ControllerHandler: ObservableObject {

    @Published var isPortrait: Bool = false

    /// 使用实际控制画布，横竖屏动画完成后的尺寸变化也会触发更新。
    func updateOrientation(canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        self.isPortrait = canvasSize.height > canvasSize.width
    }
}
