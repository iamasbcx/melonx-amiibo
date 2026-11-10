import Foundation

/// 只在原生回调栈内读取 JSON 并复制标量；排队到主线程的结果不持有 native 缓冲区。
nonisolated struct LoadingProgressSnapshot: Equatable, Sendable {
    let type: String
    let current: Int
    let total: Int
    static let empty = Self(type: "", current: 0, total: 1)
    var visible: Bool { current < max(0, total - 10) }

    private nonisolated struct WireProgress: Decodable {
        let type: String
        let current: Int
        let total: Int
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            type = try values.decode(String.self)
            current = try values.decode(Int.self)
            total = try values.decode(Int.self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorrupted(.init(codingPath: values.codingPath, debugDescription: "Expected three progress values"))
            }
        }
    }

    static func decode(_ data: Data) -> Self? {
        // Int 解码拒绝布尔值和小数，不能依赖 NSNumber 的宽松桥接把 true 当作 1。
        guard let values = try? JSONDecoder().decode(WireProgress.self, from: data),
              ["PTC", "Shaders"].contains(values.type),
              values.current >= 0, values.total >= 0, values.current <= values.total else { return nil }
        return Self(type: values.type, current: values.current, total: values.total)
    }
}
