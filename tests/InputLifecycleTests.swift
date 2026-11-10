// 编译真实输入屏障及覆盖标记模块，验证无需设备的生命周期和持久化边界。
import Foundation

@main
struct InputLifecycleTests {
    static func main() {
        checkGameEpoch()
        checkAttachmentReuse()
        checkMotionRegistration()
        checkOverrideMarker()
        print("InputLifecycleTests: game epochs, reusable attachment tokens and override markers passed")
    }

    static func checkGameEpoch() {
        let session = InGameInputSession()
        session.beginGame()
        let firstGame = session.activeGeneration!
        var writes = 0
        session.performIfActive(generation: firstGame) { writes += 1 }
        session.endGame()
        precondition(session.activeGeneration == nil)
        session.performIfActive(generation: firstGame) { writes += 100 }
        session.beginGame()
        let secondGame = session.activeGeneration!
        precondition(firstGame != secondGame)
        session.performIfActive(generation: firstGame) { writes += 100 }
        session.performIfActive(generation: secondGame) { writes += 1 }
        // 即使遗漏结束回调，新的开始边界仍必须阻止上一局帧。
        session.beginGame()
        session.performIfActive(generation: secondGame) { writes += 100 }
        precondition(writes == 2)
    }

    static func checkAttachmentReuse() {
        let attachment = InputAttachmentState()
        precondition(attachment.activeGeneration == nil)
        let first = attachment.begin()
        var writes = 0
        attachment.performIfActive(generation: first) { writes += 1 }
        attachment.end()
        attachment.performIfActive(generation: first) { writes += 100 }
        let second = attachment.begin()
        precondition(first != second)
        attachment.performIfActive(generation: first) { writes += 100 }
        attachment.performIfActive(generation: second) { writes += 1 }
        attachment.end()
        precondition(attachment.activeGeneration == nil && writes == 2)
    }

    static func checkOverrideMarker() {
        let suite = "MeloNX.InputLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gameA = "0100000000000001"
        let gameB = "0100000000000002"
        defaults.set(true, forKey: gameA)
        precondition(!NativeSettingsOverrideMarker.refresh(titleId: gameA, defaults: defaults))
        precondition(defaults.object(forKey: gameA) == nil)

        // 恢复方向开关后仍有图形或其他原生设置时，标记必须保留。
        defaults.set(false, forKey: "PhoneMotion.RotationX.Enabled" + gameA)
        defaults.set(false, forKey: "performacehud" + gameA)
        defaults.set(true, forKey: "PhoneMotion.RotationY.Enabled" + gameB)
        precondition(NativeSettingsOverrideMarker.refresh(titleId: gameA, defaults: defaults))
        defaults.removeObject(forKey: "PhoneMotion.RotationX.Enabled" + gameA)
        precondition(NativeSettingsOverrideMarker.refresh(titleId: gameA, defaults: defaults))
        defaults.removeObject(forKey: "performacehud" + gameA)
        precondition(!NativeSettingsOverrideMarker.refresh(titleId: gameA, defaults: defaults))
        precondition(defaults.bool(forKey: "PhoneMotion.RotationY.Enabled" + gameB))
        precondition(NativeSettingsOverrideMarker.refresh(titleId: gameB, defaults: defaults))
    }

    static func checkMotionRegistration() {
        let attachment = InputAttachmentState()
        let controller = attachment.begin()
        let oldMotion = attachment.beginMotion(generation: controller)!
        var writes = 0
        attachment.performIfActive(generation: controller, motionGeneration: oldMotion) { writes += 1 }
        attachment.endMotion()
        attachment.performIfActive(generation: controller, motionGeneration: oldMotion) { writes += 100 }
        // 单独停运动仍允许同一设备的按键写入。
        attachment.performIfActive(generation: controller) { writes += 1 }
        let newMotion = attachment.beginMotion(generation: controller)!
        attachment.performIfActive(generation: controller, motionGeneration: oldMotion) { writes += 100 }
        attachment.performIfActive(generation: controller, motionGeneration: newMotion) { writes += 1 }
        attachment.end()
        let nextController = attachment.begin()
        precondition(attachment.beginMotion(generation: controller) == nil)
        attachment.performIfActive(generation: nextController, motionGeneration: newMotion) { writes += 100 }
        precondition(writes == 3)
    }
}
