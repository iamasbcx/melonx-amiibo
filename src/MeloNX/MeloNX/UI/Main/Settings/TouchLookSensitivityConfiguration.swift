//
//  TouchLookSensitivityConfiguration.swift
//  MeloNX
//
//  滑动视角灵敏度的数值契约，供设置编辑器和两条运行态触摸路径共用。
//  该模块不持有设置或 UI 状态，数值解析可独立验证。
//

import Foundation

enum TouchLookSensitivityConfiguration {
    static let baseCoefficient: Double = 0.012
    static let defaultMultiplier: Double = 1.0
    static let range: ClosedRange<Double> = 0.25...100.0

    enum InputError: Error, Equatable {
        case empty
        case invalidNumber
        case outOfRange
    }

    /// 解析用户提交的普通十进制文本，允许点或逗号小数分隔符；不接受单位、分组或指数记法。
    /// 空文本可在编辑期间保留，只有显式提交时才返回错误，避免每次按键强制改写输入。
    static func parseMultiplier(_ text: String) -> Result<Double, InputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let decimalPattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#
        guard normalized.range(of: decimalPattern, options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite else {
            return .failure(.invalidNumber)
        }
        guard range.contains(value) else { return .failure(.outOfRange) }
        return .success(value)
    }

    /// 存储值进入运行态前统一检查有限值与范围；非有限值恢复默认倍数。
    static func normalizedMultiplier(_ value: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultMultiplier
    }

    /// 返回每个 UIKit 逻辑点对应的右摇杆增量系数；最终摇杆输出仍由输入层限制到 -1...1。
    static func coefficient(for multiplier: Double) -> Double {
        baseCoefficient * normalizedMultiplier(multiplier)
    }
}
