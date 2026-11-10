import Foundation
import Combine

/// 高频数值只通知性能条；游戏页面仅订阅首帧状态，避免整页随统计刷新。
@MainActor
final class PerformanceStatisticsStore: ObservableObject {
    @Published private(set) var snapshot = PerformanceStatisticsSnapshot.zero

    func update(_ next: PerformanceStatisticsSnapshot) {
        if snapshot != next { snapshot = next }
    }
}

/// 应用级回调只注册一次。会话代次拦截退出后仍在主队列等待的旧统计包。
@MainActor
final class StatisticsHandler: ObservableObject {
    static let shared = StatisticsHandler()
    @Published private(set) var started = false
    let metrics = PerformanceStatisticsStore()
    private let gate = PerformanceStatisticsSession()
    private var registered = false
    private var collecting = false

    private init() {}

    /// 必须在启动核心前调用；首帧通知不依赖普通 HUD 统计开关。
    func beginSession() {
        gate.begin()
        started = false
        metrics.update(.zero)
        collecting = false
        Ryujinx.setStatisticsEnabled(false)
        guard !registered else { return }
        registered = true
        let gate = gate
        CallbackManager.register(name: "push_statistics") { @Sendable [weak self, gate] data in
            guard let token = gate.current(), let ptr = data.ptr,
                  let packet = PerformanceStatisticsSnapshot.read(ptr, length: Int(data.len)) else { return }
            DispatchQueue.main.async { [weak self, gate] in
                guard let self, gate.accepts(token) else { return }
                if packet.started && !self.started { self.started = true }
                if self.collecting { self.metrics.update(packet) }
            }
        }
    }

    func endSession() {
        gate.end()
        setCollectionEnabled(false)
    }

    /// 由游戏页面根据可见性、暂停和前后台状态统一调用，重复状态不跨 ABI。
    func setCollectionEnabled(_ enabled: Bool) {
        let next = enabled && gate.current() != nil
        guard collecting != next else { return }
        collecting = next
        Ryujinx.setStatisticsEnabled(next)
    }
}
