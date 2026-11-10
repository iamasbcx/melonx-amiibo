import Foundation

/// 输入资源的按需条件。只影响传感器和震动，不替代按键的会话/绑定代次屏障。
nonisolated enum InputPowerPolicy {
    static func resourcesAllowed(gameRunning: Bool, paused: Bool, applicationActive: Bool, editing: Bool) -> Bool {
        gameRunning && !paused && applicationActive && !editing
    }

    static func phoneMotionEnabled(_ controls: PhoneMotionControls) -> Bool {
        controls.translationFactors != SIMD3<Float>.zero || controls.rotationFactors != SIMD3<Float>.zero
    }

    /// nil 或 UInt32.max 表示持续，零时长/全零或非法幅值不应维持引擎和刷新定时器。
    static func hasVibration(durationMs: UInt32?, amplitudes: [Float]) -> Bool {
        durationMs != 0 && amplitudes.contains { $0.isFinite && $0 > 0 }
    }
}

/// 主线程在设置或界面方向变化时替换快照；采样队列只读取值，不同步等待主线程。
/// 未知方向传 nil，保留最近一次有效方向。所有可变状态均受短锁保护。
nonisolated final class PhoneMotionContextStore: @unchecked Sendable {
    nonisolated struct Snapshot: Sendable, Equatable {
        var orientation: PhoneMotionTransform.Orientation = .portrait
        var controls: PhoneMotionControls = .standard
    }

    static let shared = PhoneMotionContextStore()
    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func update(orientation: PhoneMotionTransform.Orientation?, controls: PhoneMotionControls) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = value
        if let orientation { value.orientation = orientation }
        value.controls = controls
        return previous != value
    }
}

/// 资源停用后让已排队震动失效；解绑后固定虚拟设备可重新启用。
nonisolated final class InputResourceActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var generation: UInt64 = 0

    var activeGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return allowed ? generation : nil
    }

    func setAllowed(_ value: Bool) {
        lock.lock()
        if value != allowed { generation &+= 1 }
        allowed = value
        lock.unlock()
    }
}

/// 没有显式配对需求时绝不广扫；已知设备重连独立于发现新设备。
nonisolated struct SteamDiscoveryPolicy {
    var foreground = true
    var bluetoothReady = false
    var pairingRequested = false
    var shouldScan: Bool { foreground && bluetoothReady && pairingRequested }
    func shouldReconnect(knownDeviceCount: Int) -> Bool {
        foreground && bluetoothReady && knownDeviceCount > 0
    }
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(300, 15 * pow(2, Double(min(5, max(0, attempt)))))
    }
}
