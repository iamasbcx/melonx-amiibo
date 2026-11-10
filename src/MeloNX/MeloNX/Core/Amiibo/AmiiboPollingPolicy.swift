/// 纯需求判断：不使用 Amiibo 时没有后台轮询；自动模式在菜单关闭后仍需检测游戏读取窗口。
nonisolated enum AmiiboPollingPolicy {
    static func needsPolling(hasSession: Bool, applicationActive: Bool,
                             menuVisible: Bool, automaticUse: Bool) -> Bool {
        hasSession && applicationActive && (menuVisible || automaticUse)
    }
}
