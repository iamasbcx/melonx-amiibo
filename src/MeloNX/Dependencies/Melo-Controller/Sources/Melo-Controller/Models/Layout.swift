//
//  Layout.swift
//  Melo-Controller
//
//  Created by Stossy11 on 8/3/2026.
//

import Foundation
import CoreGraphics

public enum LayoutOrientation: String, Codable, Hashable {
    case portrait
    case landscape
}

public struct ButtonLayout: Codable, Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0
    var hidden: Bool = false
    var toggle: Bool = false
    var dpadToJoystickl: Bool = false
}

public struct JoystickLayout: Codable, Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0
    var hide: Bool = true
    var background: Bool = false
    var hidden: Bool = false
}

/// 屏幕滑动视角区域的归一化布局。位置和尺寸相对于全屏控制画布保存，与游戏画面宽高比无关。
public struct TouchLookLayout: Codable, Equatable {
    public var centerX: CGFloat = 0.75
    public var centerY: CGFloat = 0.5
    public var width: CGFloat = 0.5
    public var height: CGFloat = 1.0
    public var hidden: Bool = false

    public init() {}

    public var rect: CGRect {
        CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    /// 限制区域在归一化画面内，避免编辑器拖动后生成不可用区域。
    public mutating func clamp() {
        width = min(1, max(0.1, width.isFinite ? width : 0.5))
        height = min(1, max(0.1, height.isFinite ? height : 1.0))
        centerX = min(1 - width / 2, max(width / 2, centerX.isFinite ? centerX : 0.75))
        centerY = min(1 - height / 2, max(height / 2, centerY.isFinite ? centerY : 0.5))
    }
}

public struct LayoutConfig: Codable, Equatable {
    var buttons: [String: ButtonLayout] = [:]
    var joysticks: [String: JoystickLayout] = [:]
    public var touchLook: TouchLookLayout = TouchLookLayout()

    /// 编辑器网格开关。该字段随布局保存，便于每个游戏单独使用不同的对齐习惯。
    var gridEnabled: Bool = false
    /// 网格间距（显示点）。取值由编辑器限制在 8...64，避免过密或过疏导致误操作。
    var gridSpacing: CGFloat = 16

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case buttons, joysticks, touchLook, gridEnabled, gridSpacing
    }

    /// 兼容已有布局文件：网格字段缺失时使用关闭及 16 点间距的默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: ButtonLayout].self, forKey: .buttons) ?? [:]
        joysticks = try container.decodeIfPresent([String: JoystickLayout].self, forKey: .joysticks) ?? [:]
        touchLook = try container.decodeIfPresent(TouchLookLayout.self, forKey: .touchLook) ?? TouchLookLayout()
        touchLook.clamp()
        gridEnabled = try container.decodeIfPresent(Bool.self, forKey: .gridEnabled) ?? false
        let spacing = try container.decodeIfPresent(CGFloat.self, forKey: .gridSpacing) ?? 16
        gridSpacing = min(64, max(8, spacing))
    }

    /// 将一个偏移量吸附到当前网格。负坐标使用 Swift 的 rounded 规则，保证四个方向对称。
    func snapped(_ offset: CGSize) -> CGSize {
        guard gridEnabled, gridSpacing > 0 else { return offset }

        func snap(_ value: CGFloat) -> CGFloat {
            (value / gridSpacing).rounded() * gridSpacing
        }

        return CGSize(width: snap(offset.width), height: snap(offset.height))
    }

    /// 对布局中已有控件执行一次网格吸附，用于打开网格后统一整理旧布局。
    /// 视角区域使用编辑器实际画布尺寸换算网格，不依赖固定分辨率常数。
    mutating func snapAllOffsets(in canvasSize: CGSize = .zero) {
        for id in buttons.keys {
            guard var item = buttons[id] else { continue }
            item.offset = snapped(item.offset)
            buttons[id] = item
        }
        for id in joysticks.keys {
            guard var item = joysticks[id] else { continue }
            item.offset = snapped(item.offset)
            joysticks[id] = item
        }
        if gridEnabled, canvasSize.width > 0, canvasSize.height > 0 {
            let center = ControllerLayoutGeometry.nudgedCenter(CGPoint(x: touchLook.centerX, y: touchLook.centerY),
                size: CGSize(width: touchLook.width, height: touchLook.height), canvas: canvasSize,
                dx: 0, dy: 0, gridSpacing: gridSpacing)
            touchLook.centerX = center.x
            touchLook.centerY = center.y
            touchLook.clamp()
        }
    }
}
