// 独立 Foundation 回归入口：与应用编译同一份 parser，避免复制实现作为测试。
import Foundation

@main
struct AmiiboCatalogParserTests {
    static func main() throws {
        let header = AmiiboCatalogParser.header
        let valid = "\u{FEFF}# comment\r\n\(header)\r\n[Link]\r\n0100000000040002\r\n\r\n[Zelda]\r\n01010000000e0002\r\n"
        let entries = try AmiiboCatalogParser.parse(Data(valid.utf8))
        precondition(entries.count == 2 && entries[1].id == "01010000000E0002")
        let encoded = try AmiiboCatalogParser.encode(entries)
        let roundTrip = try AmiiboCatalogParser.parse(encoded)
        precondition(roundTrip == entries)
        expectFailure("\(header)\n[A]\n0100000000040002\n[B]\n0100000000040002", line: 5)
        expectFailure("\(header)\n[A]\n0100000000040002\n[A]\n01010000000E0002", line: 4)
        expectFailure("\(header)\n[A]", line: 2)
        expectFailure("\(header)\n[Bad[Name]]\n0100000000040002", line: 2)
        expectFailure("MELONX_AMIIBO_CATALOG 0\n[A]\n0100000000040002", line: 1)
        expectFailure("\(header)\n[A]\n\u{FF10}100000000040002", line: 3)
        do {
            _ = try AmiiboCatalogParser.parse(Data(repeating: 65, count: AmiiboCatalogParser.maxBytes + 1))
            preconditionFailure("oversize accepted")
        } catch is AmiiboCatalogParseError {}
        if CommandLine.arguments.count > 1 {
            let sample = try AmiiboCatalogParser.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(sample.count == 2)
        }
        print("AmiiboCatalogParser: all checks passed")
    }

    static func expectFailure(_ text: String, line: Int) {
        do {
            _ = try AmiiboCatalogParser.parse(Data(text.utf8))
            preconditionFailure("invalid catalog accepted")
        } catch let error as AmiiboCatalogParseError {
            precondition(error.line == line, "wrong error line: \(error.line)")
        } catch { preconditionFailure("unexpected error: \(error)") }
    }
}
