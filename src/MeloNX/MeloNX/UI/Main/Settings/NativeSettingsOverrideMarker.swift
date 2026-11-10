// 原生游戏设置的存在标记必须反映实际覆盖键，不能因曾经修改过某项而永久保留。
import Foundation

nonisolated enum NativeSettingsOverrideMarker {
    /// 只重算当前标题标记，不删除其他配置；false 值同样属于有效覆盖。
    /// 映射/键盘文件由各自存储检测，本标记仅负责 UserDefaults 中的游戏覆盖。
    @discardableResult
    static func refresh(titleId: String, defaults: UserDefaults = .standard) -> Bool {
        guard !titleId.isEmpty, titleId != "0" else { return false }
        let hasOverrides = defaults.dictionaryRepresentation().keys.contains {
            $0 != titleId && $0.hasSuffix(titleId)
        }
        if hasOverrides {
            defaults.set(true, forKey: titleId)
        } else {
            defaults.removeObject(forKey: titleId)
        }
        return hasOverrides
    }
}
