//
//  GameRemarksStore.swift
//  MeloNX
//
//  游戏库备注仓库：备注独立于游戏元数据和模拟器配置，仅在主线程读写并通知所有展示路径。
//

import Foundation
import Combine

@MainActor
final class GameRemarksStore: ObservableObject {
    static let shared = GameRemarksStore()

    /// 仅持有用户自定义备注；空文本删除对应键，避免列表出现空白第三行。
    @Published private(set) var notes: [String: String]

    private static let storageKey = "GameLibraryRemarks"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.notes = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func note(for game: GameInfo) -> String {
        notes[Self.key(for: game)] ?? ""
    }

    /// 保存不超过 500 字的备注；超限直接拒绝并返回 false，完成后发布新字典。
    @discardableResult
    func setNote(_ text: String, for game: GameInfo) -> Bool {
        guard text.count <= 500 else { return false }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = notes
        if note.isEmpty {
            updated.removeValue(forKey: Self.key(for: game))
        } else {
            updated[Self.key(for: game)] = note
        }
        defaults.set(updated, forKey: Self.storageKey)
        notes = updated
        return true
    }

    /// 有有效 Title ID 时使用稳定标识，同一游戏的不同文件共用备注。
    /// 缺少 Title ID 时使用 Documents 下的相对路径；此时移动或改名游戏文件会形成新的备注身份，应用容器迁移不影响备注。
    private static func key(for game: GameInfo) -> String {
        let titleId = game.titleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = titleId.hasPrefix("0x") ? String(titleId.dropFirst(2)) : titleId
        if let number = UInt64(digits, radix: 16), number != 0 {
            return String(format: "title:%016llx", number)
        }
        let documents = URL.documentsDirectory.standardizedFileURL
        let fileURL = game.fileURL.standardizedFileURL
        let relativePath: String
        if fileURL.path.hasPrefix(documents.path + "/") {
            relativePath = String(fileURL.path.dropFirst(documents.path.count + 1))
        } else {
            // 外部文件未位于应用 Documents 时仍保留稳定的规范化 URL 作为明确 fallback。
            relativePath = fileURL.absoluteString
        }
        return "file:" + relativePath
    }
}
