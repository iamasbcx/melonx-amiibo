import Foundation
import CoreGraphics

/// 只在几何尺寸或目标刷新率实际变化时通知核心。状态由 MetalView 在主线程持有。
/// 尺寸按核心的整点坐标比较；空窗口或非有限几何不覆盖最后一次有效尺寸。
nonisolated struct MetalViewConfigurationState {
    private var reportedSize: CGSize?
    private var reportedFrameRate: Int?

    nonisolated struct Update {
        let size: CGSize?
        let frameRate: Int?
    }

    mutating func update(size: CGSize, frameRate: Int) -> Update {
        var changedSize: CGSize?
        if size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
           size.width <= CGFloat(Int32.max), size.height <= CGFloat(Int32.max) {
            let integralSize = CGSize(width: size.width.rounded(.towardZero), height: size.height.rounded(.towardZero))
            if integralSize != reportedSize {
                reportedSize = integralSize
                changedSize = integralSize
            }
        }
        let normalizedRate = max(1, frameRate)
        let changedRate = normalizedRate == reportedFrameRate ? nil : normalizedRate
        reportedFrameRate = normalizedRate
        return Update(size: changedSize, frameRate: changedRate)
    }
}
