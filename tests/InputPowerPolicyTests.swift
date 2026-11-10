// 编译生产资源策略和快照实现，验证节能边界不会恢复已停用资源或混用两帧设置。
import Foundation

@main
struct InputPowerPolicyTests {
    static func main() {
        checkResourceConditions()
        checkMotionDemand()
        checkSnapshot()
        checkResourceGeneration()
        checkDiscovery()
        checkVibration()
        print("InputPowerPolicyTests: resource lifecycle, motion snapshots, discovery and idle haptics passed")
    }

    static func checkResourceConditions() {
        // 暂停、后台、编辑独立限制资源；解除其中一个条件不能覆盖另一个条件。
        for mask in 0..<16 {
            let running = mask & 1 != 0
            let paused = mask & 2 != 0
            let active = mask & 4 != 0
            let editing = mask & 8 != 0
            let allowed = InputPowerPolicy.resourcesAllowed(gameRunning: running, paused: paused,
                applicationActive: active, editing: editing)
            precondition(allowed == (mask == 5))
        }
    }

    static func checkMotionDemand() {
        precondition(InputPowerPolicy.phoneMotionEnabled(.standard))
        precondition(!InputPowerPolicy.phoneMotionEnabled(PhoneMotionControls(
            translationFactors: .zero, rotationFactors: .zero)))
        for axis in 0..<6 {
            for factor in [Float(-1), Float(1)] {
                var translation = SIMD3<Float>.zero
                var rotation = SIMD3<Float>.zero
                if axis < 3 { translation[axis] = factor } else { rotation[axis - 3] = factor }
                precondition(InputPowerPolicy.phoneMotionEnabled(PhoneMotionControls(
                    translationFactors: translation, rotationFactors: rotation)))
            }
        }
    }

    static func checkSnapshot() {
        let store = PhoneMotionContextStore()
        let off = PhoneMotionControls(translationFactors: .zero, rotationFactors: .zero)
        for orientation in PhoneMotionTransform.Orientation.allCases {
            store.update(orientation: orientation, controls: .standard)
            precondition(store.snapshot.orientation == orientation)
            precondition(store.update(orientation: nil, controls: off))
            precondition(store.snapshot.orientation == orientation && store.snapshot.controls == off)
            precondition(!store.update(orientation: nil, controls: off))
        }

        // 方向与控制必须在同一短锁内更新，采样线程不能看到来自两次更新的混合快照。
        let first = PhoneMotionContextStore.Snapshot(orientation: .landscapeLeft, controls: .standard)
        let second = PhoneMotionContextStore.Snapshot(orientation: .portraitUpsideDown, controls: off)
        store.update(orientation: first.orientation, controls: first.controls)
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            let next = index.isMultiple(of: 2) ? first : second
            store.update(orientation: next.orientation, controls: next.controls)
            let snapshot = store.snapshot
            precondition(snapshot == first || snapshot == second)
        }
    }

    static func checkResourceGeneration() {
        let activity = InputResourceActivity()
        precondition(activity.activeGeneration == nil)
        activity.setAllowed(true)
        let first = activity.activeGeneration!
        activity.setAllowed(true)
        precondition(activity.activeGeneration == first)
        activity.setAllowed(false)
        precondition(activity.activeGeneration == nil)
        activity.setAllowed(false)
        activity.setAllowed(true)
        precondition(activity.activeGeneration != nil && activity.activeGeneration != first)
    }

    static func checkDiscovery() {
        var policy = SteamDiscoveryPolicy()
        precondition(!policy.shouldScan && !policy.shouldReconnect(knownDeviceCount: 1))
        policy.bluetoothReady = true
        precondition(!policy.shouldScan && policy.shouldReconnect(knownDeviceCount: 1))
        precondition(!policy.shouldReconnect(knownDeviceCount: 0))
        policy.pairingRequested = true
        precondition(policy.shouldScan)
        policy.foreground = false
        precondition(!policy.shouldScan && !policy.shouldReconnect(knownDeviceCount: 1))
        policy.foreground = true
        policy.bluetoothReady = false
        precondition(!policy.shouldScan)
        policy.bluetoothReady = true
        precondition(policy.shouldScan)
        policy.pairingRequested = false
        precondition(!policy.shouldScan && policy.shouldReconnect(knownDeviceCount: 1))

        let expected: [TimeInterval] = [15, 30, 60, 120, 240, 300, 300]
        for (attempt, delay) in expected.enumerated() {
            precondition(SteamDiscoveryPolicy.reconnectDelay(attempt: attempt) == delay)
        }
        precondition(SteamDiscoveryPolicy.reconnectDelay(attempt: -1) == 15)
        precondition(SteamDiscoveryPolicy.reconnectDelay(attempt: Int.max) == 300)
    }

    static func checkVibration() {
        precondition(!InputPowerPolicy.hasVibration(durationMs: 0, amplitudes: [1]))
        precondition(!InputPowerPolicy.hasVibration(durationMs: nil, amplitudes: []))
        precondition(!InputPowerPolicy.hasVibration(durationMs: 100, amplitudes: [0, -1, .nan, .infinity]))
        precondition(InputPowerPolicy.hasVibration(durationMs: 100, amplitudes: [0, 0.1]))
        precondition(InputPowerPolicy.hasVibration(durationMs: nil, amplitudes: [0.1]))
        precondition(InputPowerPolicy.hasVibration(durationMs: UInt32.max, amplitudes: [0.1]))
    }
}
