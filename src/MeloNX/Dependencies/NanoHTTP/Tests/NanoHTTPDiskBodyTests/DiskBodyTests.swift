import Foundation
import XCTest
@testable import NanoHTTP

/// 用生成式 socket 检查解析器的读取粒度，不把测试正文整体放进内存。
private final class GeneratedSocket: NanoSocket {
    private let header: [UInt8]
    private var headerOffset = 0
    private var availableBytes: Int
    private(set) var bodyReadCount = 0
    private(set) var largestRead = 0

    init(declared: Int, available: Int? = nil) {
        header = Array("PUT /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(declared)\r\n\r\n".utf8)
        availableBytes = available ?? declared
        super.init(socketFileDescriptor: -1)
    }

    override func read() throws -> UInt8 {
        guard headerOffset < header.count else { throw NanoSocketError.recvFailed("unexpected header read") }
        defer { headerOffset += 1 }
        return header[headerOffset]
    }

    override func read(length: Int) throws -> [UInt8] {
        largestRead = max(largestRead, length)
        guard length <= availableBytes else { throw NanoSocketError.recvFailed("interrupted test body") }
        availableBytes -= length
        bodyReadCount += length
        return [UInt8](repeating: 0x5A, count: length)
    }
}

final class DiskBodyTests: XCTestCase {
    private var directory: URL!
    private let maximum = 500 * 1024 * 1024

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeloNXDiskBodyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testDiskBodyIsBoundedAndRemovedAfterUse() throws {
        let size = 3 * 1024 * 1024 + 17
        let socket = GeneratedSocket(declared: size)
        let parser = NanoHTTPParser(socket: socket, limits: .init(maxBodyBytes: maximum))
        let request = try parser.readHttpRequest { _ in .file(directory: self.directory, maxBytes: self.maximum) }
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(request.bodyLength, Int64(size))
        XCTAssertLessThanOrEqual(socket.largestRead, 1024 * 1024)
        let url = try XCTUnwrap(request.bodyFileURL)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".melo-request.part"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, NSNumber(value: size))
        let handle = try FileHandle(forReadingFrom: url)
        try handle.seek(toOffset: UInt64(size - 1))
        XCTAssertEqual(try handle.read(upToCount: 1), Data([0x5A]))
        try handle.close()
        request.disposeBodyFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnauthorizedHeadersDoNotReadBodyOrCreateFiles() throws {
        let socket = GeneratedSocket(declared: maximum)
        let parser = NanoHTTPParser(socket: socket, limits: .init(maxBodyBytes: maximum))
        XCTAssertThrowsError(try parser.readHttpRequest { _ in throw NanoHTTPError.unauthorized("test") }) { error in
            XCTAssertEqual((error as? NanoHTTPError)?.status, 401)
        }
        XCTAssertEqual(socket.bodyReadCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testInterruptedBodyRemovesPartialRequestFile() throws {
        let socket = GeneratedSocket(declared: 3 * 1024 * 1024, available: 1024 * 1024 + 100)
        let parser = NanoHTTPParser(socket: socket, limits: .init(maxBodyBytes: maximum))
        XCTAssertThrowsError(try parser.readHttpRequest { _ in .file(directory: self.directory, maxBytes: self.maximum) })
        XCTAssertEqual(socket.bodyReadCount, 1024 * 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testBodyOver500MiBIsRejectedBeforeRead() throws {
        let socket = GeneratedSocket(declared: maximum + 1)
        let parser = NanoHTTPParser(socket: socket, limits: .init(maxBodyBytes: maximum))
        XCTAssertThrowsError(try parser.readHttpRequest { _ in .file(directory: self.directory, maxBytes: self.maximum) }) { error in
            guard case NanoHTTPParserError.bodyTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(socket.bodyReadCount, 0)
    }

    func testJSONMemoryLimitStaysSmallWhenDiskLimitIs500MiB() throws {
        let socket = GeneratedSocket(declared: 2 * 1024 * 1024)
        let parser = NanoHTTPParser(socket: socket, limits: .init(maxBodyBytes: maximum))
        XCTAssertThrowsError(try parser.readHttpRequest { _ in .memory(maxBytes: 1024 * 1024) })
        XCTAssertEqual(socket.bodyReadCount, 0)
    }

    func testRequestDeinitRemovesBodyFile() throws {
        let socket = GeneratedSocket(declared: 4)
        let parser = NanoHTTPParser(socket: socket)
        var request: NanoHTTPRequest? = try parser.readHttpRequest { _ in .file(directory: self.directory, maxBytes: self.maximum) }
        let url = try XCTUnwrap(request?.bodyFileURL)
        request = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
