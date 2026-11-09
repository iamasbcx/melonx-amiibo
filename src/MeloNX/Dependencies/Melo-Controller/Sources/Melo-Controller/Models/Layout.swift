//
//  Layout.swift
//  Melo-Controller
//
//  Created by Stossy11 on 8/3/2026.
//

import Foundation

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

public struct LayoutConfig: Codable, Equatable {
    var buttons: [String: ButtonLayout] = [:]
    var joysticks: [String: JoystickLayout] = [:]

    /// 编辑器网格开关。该字段随布局保存，便于每个游戏单独使用不同的对齐习惯。
    var gridEnabled: Bool = false
    /// 网格间距（显示点）。取值由编辑器限制在 8...64，避免过密或过疏导致误操作。
    var gridSpacing: CGFloat = 16

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case buttons, joysticks, gridEnabled, gridSpacing
    }

    /// 兼容已有布局文件：网格字段缺失时使用关闭及 16 点间距的默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: ButtonLayout].self, forKey: .buttons) ?? [:]
        joysticks = try container.decodeIfPresent([String: JoystickLayout].self, forKey: .joysticks) ?? [:]
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
    mutating func snapAllOffsets() {
        for id in buttons.keys {
            buttons[id]?.offset = snapped(buttons[id]?.offset ?? .zero)
        }
        for id in joysticks.keys {
            joysticks[id]?.offset = snapped(joysticks[id]?.offset ?? .zero)
        }
    }
}
