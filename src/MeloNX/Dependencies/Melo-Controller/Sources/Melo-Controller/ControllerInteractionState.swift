import Foundation
// 几何类型的 Swift 扩展由 CoreGraphics 提供，独立编译时不能依赖 Foundation 间接导入。
import CoreGraphics

/// 右摇杆与滑动视角分别保存输入；按住摇杆时优先使用摇杆，滑动定时归零只清理滑动源。
/// 此值类型不持有设备，调用方在主线程串行修改并把 output 提交给手柄。
struct ControllerRightStickState {
    private(set) var stick = CGPoint.zero
    private(set) var swipe = CGPoint.zero
    private(set) var stickActive = false

    var output: CGPoint { stickActive ? stick : swipe }

    mutating func updateStick(_ position: CGPoint) { stick = bounded(position) }
    mutating func setStickActive(_ active: Bool) {
        stickActive = active
        if !active { stick = .zero }
    }
    mutating func updateSwipe(_ position: CGPoint) { swipe = bounded(position) }
    mutating func reset() { self = Self() }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? min(1, max(-1, point.x)) : 0,
                y: point.y.isFinite ? min(1, max(-1, point.y)) : 0)
    }
}

/// 编辑和运行共用全屏控制画布；所有像素/归一化换算及网格运算集中在此处。
enum ControllerLayoutGeometry {
    static func rect(center: CGPoint, size: CGSize, canvas: CGSize) -> CGRect {
        CGRect(x: (center.x - size.width / 2) * canvas.width,
               y: (center.y - size.height / 2) * canvas.height,
               width: size.width * canvas.width, height: size.height * canvas.height)
    }

    /// 步长为逻辑点；开启网格时从当前位置吸附后再移动一格，边缘最终限制在画布内。
    static func nudgedCenter(_ center: CGPoint, size: CGSize, canvas: CGSize,
                             dx: Int, dy: Int, gridSpacing: CGFloat?) -> CGPoint {
        guard canvas.width > 0, canvas.height > 0 else { return center }
        let step = gridSpacing.map { max(1, $0) } ?? 1
        var x = center.x * canvas.width
        var y = center.y * canvas.height
        if gridSpacing != nil {
            x = (x / step).rounded() * step
            y = (y / step).rounded() * step
        }
        x += CGFloat(dx) * step
        y += CGFloat(dy) * step
        return CGPoint(x: min(1 - size.width / 2, max(size.width / 2, x / canvas.width)),
                       y: min(1 - size.height / 2, max(size.height / 2, y / canvas.height)))
    }
}
