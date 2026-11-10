// 直接编译手柄包中的生产状态与坐标模块；不依赖 UIKit，覆盖输入仲裁及真实画布网格。
import Foundation
import CoreGraphics

@main
struct VirtualControllerInteractionTests {
    static func main() throws {
        checkRightStickOwnership()
        checkCanvasGeometry()
        checkGridNudges()
        try checkLayoutGridPersistence()
        print("VirtualControllerInteractionTests: input ownership, canvas geometry and grid adjustment passed")
    }

    static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
    }

    static func checkRightStickOwnership() {
        var state = ControllerRightStickState()
        state.updateSwipe(CGPoint(x: 0.8, y: -0.4))
        precondition(state.output == CGPoint(x: 0.8, y: -0.4))
        state.setStickActive(true)
        state.updateStick(CGPoint(x: -0.6, y: 0.3))
        state.updateSwipe(CGPoint(x: 0.9, y: 0.7))
        precondition(state.output == CGPoint(x: -0.6, y: 0.3), "Swipe replaced a held stick")
        state.updateSwipe(.zero)
        precondition(state.output == CGPoint(x: -0.6, y: 0.3), "Swipe timeout cleared a held stick")

        // 摇杆停在中心但手指仍按住时仍拥有输入，不能被第二根手指接管。
        state.updateStick(.zero)
        state.updateSwipe(CGPoint(x: 0.25, y: -0.5))
        precondition(state.output == .zero)
        state.setStickActive(false)
        precondition(state.output == CGPoint(x: 0.25, y: -0.5), "Releasing stick lost the live swipe")
        state.updateSwipe(CGPoint(x: 10, y: -.infinity))
        precondition(state.output == CGPoint(x: 1, y: 0))
        state.reset()
        precondition(state.output == .zero && !state.stickActive)
    }

    static func checkCanvasGeometry() {
        let center = CGPoint(x: 0.75, y: 0.75)
        let size = CGSize(width: 0.2, height: 0.2)
        let rect = ControllerLayoutGeometry.rect(center: center, size: size, canvas: CGSize(width: 390, height: 844))
        near(rect.minY, 548.6, "Portrait region must use full controller canvas")
        near(rect.maxY, 717.4, "Portrait region bottom")
        precondition(rect.contains(CGPoint(x: 292.5, y: 633)))
        precondition(!rect.contains(CGPoint(x: 292.5, y: 164.5)), "Removed Metal fallback left a ghost region")

        // 编辑显示与命中共用该函数；小区域不能仅在编辑时被扩大到 60 点。
        let small = ControllerLayoutGeometry.rect(center: CGPoint(x: 0.5, y: 0.5),
            size: CGSize(width: 0.1, height: 0.1), canvas: CGSize(width: 844, height: 390))
        near(small.height, 39, "Editor and runtime must share the small region size")
    }

    static func checkGridNudges() {
        for canvas in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 1366)] {
            let size = CGSize(width: 0.2, height: 0.2)
            let start = CGPoint(x: 0.5, y: 0.5)
            let snapped = ControllerLayoutGeometry.nudgedCenter(start, size: size, canvas: canvas, dx: 0, dy: 0, gridSpacing: 16)
            let right = ControllerLayoutGeometry.nudgedCenter(snapped, size: size, canvas: canvas, dx: 1, dy: 0, gridSpacing: 16)
            let down = ControllerLayoutGeometry.nudgedCenter(snapped, size: size, canvas: canvas, dx: 0, dy: 1, gridSpacing: 16)
            near((right.x - snapped.x) * canvas.width, 16, "Horizontal grid step")
            near((down.y - snapped.y) * canvas.height, 16, "Vertical grid step")
            let back = ControllerLayoutGeometry.nudgedCenter(right, size: size, canvas: canvas, dx: -1, dy: 0, gridSpacing: 16)
            near(back.x, snapped.x, "Opposite nudges must restore center")
            let fine = ControllerLayoutGeometry.nudgedCenter(start, size: size, canvas: canvas, dx: 0, dy: -1, gridSpacing: nil)
            near((start.y - fine.y) * canvas.height, 1, "Fine adjustment is one logical point")
            let edge = ControllerLayoutGeometry.nudgedCenter(CGPoint(x: 0.9, y: 0.9), size: size, canvas: canvas, dx: 1, dy: 1, gridSpacing: 64)
            precondition(edge.x <= 0.9 && edge.y <= 0.9)
        }
    }

    static func checkLayoutGridPersistence() throws {
        var layout = LayoutConfig()
        layout.gridEnabled = true
        layout.gridSpacing = 16
        layout.touchLook.width = 0.2
        layout.touchLook.height = 0.2
        layout.touchLook.centerX = 0.51
        layout.touchLook.centerY = 0.51
        let canvas = CGSize(width: 390, height: 844)
        layout.snapAllOffsets(in: canvas)
        let gridX = layout.touchLook.centerX * canvas.width / 16
        let gridY = layout.touchLook.centerY * canvas.height / 16
        near(gridX, gridX.rounded(), "Enabling grid snaps X")
        near(gridY, gridY.rounded(), "Enabling grid snaps Y")
        let roundTrip = try JSONDecoder().decode(LayoutConfig.self, from: JSONEncoder().encode(layout))
        precondition(roundTrip == layout, "Saving changed the snapped region")
    }
}
