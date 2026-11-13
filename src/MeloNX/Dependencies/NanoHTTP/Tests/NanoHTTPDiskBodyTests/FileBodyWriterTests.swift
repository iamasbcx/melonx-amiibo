import Foundation
import Darwin
import XCTest
@testable import NanoHTTP

/// 用真实本地 socket 验证源文件截短后的错误传播，不缓存大型测试正文。
final class FileBodyWriterTests: XCTestCase {
    func testShortFileFailsFixedLengthResponse() throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let output = NanoSocket(socketFileDescriptor: descriptors[0])
        defer { output.close(); Darwin.close(descriptors[1]) }
        guard let pointer = tmpfile() else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = NanoFile(pointer)
        defer { file.close() }
        try file.write([1, 2, 3])
        fflush(pointer)
        let writer = LengthLimitedBodyWriter(socket: output, length: 8)
        XCTAssertThrowsError(try writer.write(file, offset: 0, length: 8))
        XCTAssertEqual(writer.written, 3)
        XCTAssertFalse(writer.isComplete)
    }
}
