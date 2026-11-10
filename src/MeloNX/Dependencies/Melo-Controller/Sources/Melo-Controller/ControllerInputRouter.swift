import SwiftUI
import Combine

/// 单个手柄叠层的输入所有者。所有调用来自 UIKit/SwiftUI 主线程，销毁叠层时释放各输入源。
final class ControllerInputRouter: ObservableObject, Controller {
    private let destination: any Controller
    private var rightStick = ControllerRightStickState()
    private var lastRightOutput = CGPoint.zero

    init(controller: any Controller) { destination = controller }
    func buttonPressed(_ button: VirtualControllerButton) { destination.buttonPressed(button) }
    func buttonReleased(_ button: VirtualControllerButton) { destination.buttonReleased(button) }

    func joystickMoved(position: CGPoint, right: Bool) {
        guard right else { destination.joystickMoved(position: position, right: false); return }
        rightStick.updateStick(position)
        publishRightStick()
    }

    func joystickActivityChanged(_ active: Bool, right: Bool) {
        guard right else { return }
        rightStick.setStickActive(active)
        publishRightStick()
    }

    func swipeMoved(_ position: CGPoint) {
        rightStick.updateSwipe(position)
        publishRightStick()
    }

    func reset() {
        rightStick.reset()
        lastRightOutput = .zero
        destination.joystickMoved(position: .zero, right: true)
        destination.joystickMoved(position: .zero, right: false)
    }

    private func publishRightStick() {
        let next = rightStick.output
        guard next != lastRightOutput else { return }
        lastRightOutput = next
        destination.joystickMoved(position: next, right: true)
    }
}
