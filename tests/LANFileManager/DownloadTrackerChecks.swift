import Foundation

/// 在 macOS CI 验证下载状态生命周期；sent 只代表服务端发送结束，不代表浏览器落盘。
@main
struct DownloadTrackerChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LANDownloadTrackerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let tracker = LANDownloadTracker()
        let id = UUID().uuidString
        try require(tracker.snapshot(downloadID: id).state == .waiting, "未知 ID 必须等待实际 GET")
        let first = try tracker.begin(downloadID: id, path: "roms/game.nsp")
        try require(first != nil && tracker.snapshot(downloadID: id).state == .sending, "GET 未进入 sending")
        do {
            _ = try tracker.begin(downloadID: id, path: "roms/another.nsp")
            try require(false, "同 ID 不得绑定其他路径")
        } catch LANDownloadTracker.BeginError.pathMismatch {}
        do {
            _ = try tracker.begin(downloadID: id, path: "roms/game.nsp")
            try require(false, "同 ID 并发发送必须拒绝")
        } catch LANDownloadTracker.BeginError.alreadySending {}
        first?.markSent()
        first?.markFailed()
        try require(tracker.snapshot(downloadID: id).state == .sent, "lease 只能完成一次")

        let abandonedID = UUID().uuidString
        var abandoned = try tracker.begin(downloadID: abandonedID, path: "abandoned")
        try require(abandoned != nil, "响应 lease 创建失败")
        abandoned = nil
        try require(tracker.snapshot(downloadID: abandonedID).state == .failed, "丢弃响应必须失败")

        let old = try tracker.begin(downloadID: id, path: "roms/game.nsp")
        tracker.stop()
        try require(tracker.snapshot(downloadID: id).state == .failed, "停止服务必须终止发送状态")
        let retry = try tracker.begin(downloadID: id, path: "roms/game.nsp")
        old?.markSent()
        try require(tracker.snapshot(downloadID: id).state == .sending, "旧连接不得覆盖新 generation")
        retry?.markFailed("测试网络中断")
        let failed = tracker.snapshot(downloadID: id)
        try require(failed.state == .failed && failed.error == "测试网络中断", "发送错误未保留")

        let bounded = LANDownloadTracker(maximumEntries: 8)
        var leases: [LANDownloadTracker.WriteLease] = []
        for index in 0..<8 {
            guard let lease = try bounded.begin(downloadID: "id-\(index)", path: "file-\(index)") else {
                throw NSError(domain: "LANDownloadTrackerChecks", code: 2)
            }
            leases.append(lease)
        }
        let overflow = try bounded.begin(downloadID: "overflow", path: "overflow")
        try require(overflow == nil, "容量耗尽不得淘汰正在发送的条目")
        try require(bounded.snapshot(downloadID: "overflow").state == .waiting, "未跟踪下载应保持 waiting")
        leases[0].markSent()
        let admitted = try bounded.begin(downloadID: "new", path: "new")
        try require(admitted != nil, "未淘汰已完成记录")
        try require(bounded.snapshot(downloadID: "id-0").state == .waiting, "完成记录未从容量表淘汰")
        for index in 1..<8 {
            try require(bounded.snapshot(downloadID: "id-\(index)").state == .sending, "正在发送记录被误淘汰")
        }
        admitted?.markSent()
        bounded.stop()
        print("DownloadTrackerChecks passed")
    }
}
