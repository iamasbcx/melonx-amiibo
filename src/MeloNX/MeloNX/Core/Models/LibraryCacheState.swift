import Foundation
import CryptoKit

/// 文件身份、大小、修改/创建时间共同决定 ROM 缓存是否可复用；同路径替换文件也会失效。
nonisolated struct LibraryFileStamp: Hashable, Sendable {
    let identity: String
    let bytes: Int64
    let modified: TimeInterval
    let created: TimeInterval

    static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        let identity = "\(attributes[.systemNumber] ?? "?"):\(attributes[.systemFileNumber] ?? url.path)"
        return Self(identity: identity, bytes: size.int64Value, modified: modified.timeIntervalSince1970,
            created: (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
}

/// 依赖指纹与 UI 无关，供正式扫描和临时目录回归共用；文件错误由调用方明确处理。
nonisolated enum LibraryDependencyFingerprint {
    static func digestFile(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        return digest(try Data(contentsOf: url))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func update(titleId: String?, documents: URL) throws -> String {
        guard let titleId, let number = UInt64(titleId, radix: 16) else { return "none" }
        // 与 GameInfoLoader.GetGameUpdateData 的基础标题掩码一致，不猜测其他更新路径。
        let base = String(format: "%016llx", number & ~UInt64(0xf))
        let metadata = documents.appendingPathComponent("games").appendingPathComponent(base).appendingPathComponent("updates.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return "missing" }
        let data = try Data(contentsOf: metadata)
        let metadataDigest = digest(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selected = object["selected"] as? String, !selected.isEmpty else { return metadataDigest }
        let selectedURL = selected.hasPrefix("/") ? URL(fileURLWithPath: selected) : documents.appendingPathComponent(selected)
        guard FileManager.default.fileExists(atPath: selectedURL.path) else { return metadataDigest + ":missing" }
        return metadataDigest + ":" + String(describing: try LibraryFileStamp.read(selectedURL))
    }
}

/// 纯缓存决策，不读取磁盘。环境包含密钥/语言，依赖包含该标题更新选择及更新文件身份。
nonisolated struct LibraryMetadataSignature: Equatable, Sendable {
    let file: LibraryFileStamp
    let environment: String
    let dependency: String
}

nonisolated struct LibraryMetadataCache<Value> {
    private nonisolated struct Entry { let signature: LibraryMetadataSignature; let value: Value }
    private var entries: [String: Entry] = [:]
    var count: Int { entries.count }
    init() {}
    func previous(for key: String) -> Value? { entries[key]?.value }
    func value(for key: String, matching signature: LibraryMetadataSignature) -> Value? {
        guard let entry = entries[key], entry.signature == signature else { return nil }
        return entry.value
    }
    mutating func store(_ value: Value, for key: String, signature: LibraryMetadataSignature) {
        entries[key] = Entry(signature: signature, value: value)
    }
    mutating func retain(keys: Set<String>) { entries = entries.filter { keys.contains($0.key) } }
    mutating func remove(_ key: String) { entries[key] = nil }
}

/// 严格限制自身拥有的条目数和成本；最近使用顺序由单一调用线程维护，不承担跨线程同步。
nonisolated struct BoundedLRUCache<Key: Hashable, Value> {
    private nonisolated struct Entry { let value: Value; let cost: Int; var tick: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    let countLimit: Int
    let costLimit: Int
    private(set) var totalCost = 0
    var count: Int { entries.count }
    init(countLimit: Int, costLimit: Int) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
    }
    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        tick &+= 1
        entry.tick = tick
        entries[key] = entry
        return entry.value
    }
    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        if let previous = entries.removeValue(forKey: key) { totalCost -= previous.cost }
        guard cost >= 0, cost <= costLimit, countLimit > 0 else { return }
        while entries.count >= countLimit || totalCost > costLimit - cost {
            guard let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            totalCost -= removed.cost
        }
        tick &+= 1
        entries[key] = Entry(value: value, cost: cost, tick: tick)
        totalCost += cost
    }
    mutating func removeAll() { entries.removeAll(); totalCost = 0 }
}
