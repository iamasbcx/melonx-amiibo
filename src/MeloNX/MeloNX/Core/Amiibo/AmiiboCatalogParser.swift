//
//  AmiiboCatalogParser.swift
//  MeloNX
//
//  单一 TXT 目录契约：严格解析后一次性交付；不接受半个目录或旧 JSON 格式。
//  本文件仅依赖 Foundation，可独立用于命令行回归测试。
//

import Foundation

public nonisolated struct AmiiboCatalogEntry: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var searchText: String { "\(name) \(id)".lowercased() }
    public var note: String {
        id == "01030000024F0902"
            ? "虚拟身份；狼林克心数等应用区存档效果尚未验证。"
            : "虚拟身份；游戏是否支持及奖励由游戏决定。应用区存档效果尚未验证。"
    }
}

public nonisolated struct AmiiboCatalogParseError: LocalizedError, Sendable {
    public let line: Int
    public let reason: String

    public var errorDescription: String? {
        line > 0 ? "第 \(line) 行：\(reason)" : reason
    }
}

public nonisolated enum AmiiboCatalogParser {
    public static let maxBytes = 1_048_576
    public static let maxEntries = 4096
    public static let header = "MELONX_AMIIBO_CATALOG 1"

    public static func validId(_ raw: String) -> Bool {
        raw.utf8.count == 16 && raw.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    public static func validName(_ raw: String, maxLength: Int = 80) -> Bool {
        !raw.isEmpty && raw.unicodeScalars.count <= maxLength &&
        raw.unicodeScalars.allSatisfy {
            $0 != "[" && $0 != "]" && !CharacterSet.controlCharacters.contains($0)
        }
    }

    public static func parse(_ data: Data) throws -> [AmiiboCatalogEntry] {
        guard data.count <= maxBytes else { throw failure(0, "目录超过 1 MiB。") }
        guard var content = String(data: data, encoding: .utf8) else {
            throw failure(0, "目录必须使用 UTF-8 编码。")
        }
        if content.first == "\u{FEFF}" { content.removeFirst() }
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sawHeader = false
        var pending: (name: String, line: Int)?
        var entries: [AmiiboCatalogEntry] = []
        var ids = Set<String>()
        var names = Set<String>()

        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !sawHeader {
                guard line == header else { throw failure(number, "目录头必须是 \(header)。") }
                sawHeader = true
                continue
            }

            if let item = pending {
                guard validId(line) else { throw failure(number, "amiibo ID 必须是 16 位 ASCII 十六进制字符。") }
                let id = line.uppercased()
                guard ids.insert(id).inserted else { throw failure(number, "amiibo ID 重复。") }
                guard names.insert(item.name).inserted else { throw failure(item.line, "名称重复。") }
                entries.append(AmiiboCatalogEntry(id: id, name: item.name))
                guard entries.count <= maxEntries else { throw failure(number, "目录超过 4096 个项目。") }
                pending = nil
            } else {
                guard line.hasPrefix("["), line.hasSuffix("]") else {
                    throw failure(number, "名称必须用 [名称] 包围。")
                }
                let name = String(line.dropFirst().dropLast())
                guard validName(name) else { throw failure(number, "名称须为 1～80 个字符，且不能包含方括号或控制字符。") }
                pending = (name, number)
            }
        }

        guard sawHeader else { throw failure(0, "目录缺少格式头。") }
        if let item = pending { throw failure(item.line, "名称后缺少 amiibo ID。") }
        guard !entries.isEmpty else { throw failure(0, "目录没有任何项目。") }
        return entries
    }

    public static func encode(_ entries: [AmiiboCatalogEntry]) throws -> Data {
        let body = ([header, ""] + entries.flatMap { ["[\($0.name)]", $0.id.uppercased(), ""] }).joined(separator: "\n")
        let data = Data(body.utf8)
        _ = try parse(data)
        return data
    }

    private static func failure(_ line: Int, _ reason: String) -> AmiiboCatalogParseError {
        AmiiboCatalogParseError(line: line, reason: reason)
    }
}
