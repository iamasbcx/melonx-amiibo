import Foundation
import UIKit

/// 传输期间的防熄屏引用计数器。
/// 只有第一个 lease 保存并修改系统状态，最后一个 lease 释放时恢复原值。
/// UIKit 状态仅在主 actor 访问；lease 可以从任意线程释放。
@MainActor
final class TransferActivityCoordinator {
    static let shared = TransferActivityCoordinator()

    private var activeLeaseIDs: Set<UUID> = []
    private var savedIdleTimerDisabled: Bool?

    private init() {}

    /// 获取独立传输 lease。调用方必须在任务结束、取消或失败时释放。
    @discardableResult
    func acquire() -> TransferActivityLease {
        if activeLeaseIDs.isEmpty {
            savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        let leaseID = UUID()
        activeLeaseIDs.insert(leaseID)
        return TransferActivityLease { [weak self] in
            Task { @MainActor [weak self] in
                self?.release(leaseID: leaseID)
            }
        }
    }

    private func release(leaseID: UUID) {
        // 进入后台后旧 lease 会被作废；旧连接结束不能释放新前台服务的 lease。
        guard activeLeaseIDs.remove(leaseID) != nil, activeLeaseIDs.isEmpty else { return }
        if let savedIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = savedIdleTimerDisabled
        }
        self.savedIdleTimerDisabled = nil
    }

    /// 进入后台时作废现有 lease，并恢复原防熄屏状态。
    func suspendForBackground() {
        activeLeaseIDs.removeAll()
        if let savedIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = savedIdleTimerDisabled
        }
        self.savedIdleTimerDisabled = nil
    }
}

/// 一个引用计数 lease，释放时自动归还防熄屏状态。
nonisolated final class TransferActivityLease {
    private let lock = NSLock()
    private var onRelease: (() -> Void)?

    fileprivate init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    func release() {
        lock.lock()
        let action = onRelease
        onRelease = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}
