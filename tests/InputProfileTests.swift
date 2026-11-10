// 与应用编译同一份 ControllerInputProfile；替身只提供核心类型边界，不重写存储逻辑。
import Foundation

enum ControllerType: Int, CaseIterable {
    case proController = 1, handheld, joyconPair, joyconLeft, joyconRight, pokeball
}

struct Options {
    var types = Array(repeating: ControllerType.proController, count: 8)
    static func updateControllerType(index: Int, to type: ControllerType, options: inout Options) {
        options.types[index] = type
    }
}

@main
struct InputProfileTests {
    static func main() {
        let suite = "MeloNX.InputProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gameA = "0100000000000001"
        let gameB = "0100000000000002"

        precondition(ControllerInputProfile.normalizedGameId(nil) == nil)
        precondition(ControllerInputProfile.normalizedGameId("") == nil)
        precondition(ControllerInputProfile.normalizedGameId("0") == nil)
        precondition(ControllerInputProfile.selection(gameId: gameA, defaults: defaults) == nil)

        ControllerInputProfile.setType(.handheld, index: 0, gameId: nil, defaults: defaults)
        precondition(ControllerInputProfile.type(index: 0, gameId: gameA, defaults: defaults) == .handheld)
        precondition(!ControllerInputProfile.hasOverrides(gameId: gameA, defaults: defaults))
        ControllerInputProfile.setType(.joyconPair, index: 0, gameId: gameA, defaults: defaults)
        ControllerInputProfile.setType(.joyconLeft, index: 0, gameId: nil, defaults: defaults)
        precondition(ControllerInputProfile.type(index: 0, gameId: gameA, defaults: defaults) == .joyconPair)
        precondition(ControllerInputProfile.type(index: 0, gameId: gameB, defaults: defaults) == .joyconLeft)
        precondition(ControllerInputProfile.type(index: 0, gameId: nil, defaults: defaults) == .joyconLeft)

        ControllerInputProfile.setSelection(["virtual"], gameId: nil, defaults: defaults)
        ControllerInputProfile.setSelection([], gameId: gameA, defaults: defaults)
        precondition(ControllerInputProfile.selection(gameId: gameA, defaults: defaults) == [])
        precondition(ControllerInputProfile.selection(gameId: gameB, defaults: defaults) == ["virtual"])
        ControllerInputProfile.setType(.pokeball, index: 7, gameId: gameB, defaults: defaults)
        ControllerInputProfile.resetOverrides(gameId: gameA, defaults: defaults)
        precondition(ControllerInputProfile.selection(gameId: gameA, defaults: defaults) == ["virtual"])
        precondition(ControllerInputProfile.type(index: 0, gameId: gameA, defaults: defaults) == .joyconLeft)
        precondition(ControllerInputProfile.type(index: 7, gameId: gameB, defaults: defaults) == .pokeball)
        precondition(!ControllerInputProfile.hasOverrides(gameId: gameA, defaults: defaults))

        var options = Options()
        ControllerInputProfile.applyTypes(to: &options, gameId: gameB, defaults: defaults)
        precondition(options.types[0] == .joyconLeft && options.types[7] == .pokeball)
        precondition(options.types[1] == .proController)
        defaults.set(999, forKey: ControllerInputProfile.typeKeys[2] + gameA)
        precondition(ControllerInputProfile.type(index: 2, gameId: gameA, defaults: defaults) == .proController)
        precondition(ControllerInputProfile.type(index: -1, gameId: gameA, defaults: defaults) == .proController)
        print("InputProfileTests: scope isolation, live fallback, explicit keyboard selection and reset passed")
    }
}
