import Foundation

/// 使用生产解析和会话门控检查非对齐 ABI、坏值与退出/重开后的陈旧包。
@main
struct PerformanceSamplingTests {
    static func main() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 34, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 34)
        let packet = buffer.advanced(by: 1)
        func put(_ value: Double, at offset: Int) {
            var copy = value
            withUnsafeBytes(of: &copy) { bytes in
                packet.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        put(30, at: 0)
        put(33.3, at: 8)
        packet.storeBytes(of: UInt8(1), toByteOffset: 16, as: UInt8.self)
        put(12.5, at: 17)
        let decoded = PerformanceStatisticsSnapshot.read(packet, length: 33)!
        precondition(decoded.fps == 30 && decoded.frameTime == 33.3 && decoded.started && decoded.fifo == 12.5)
        precondition(PerformanceStatisticsSnapshot.read(packet, length: 32) == nil)
        put(.nan, at: 0)
        put(-1, at: 8)
        put(.infinity, at: 17)
        let bounded = PerformanceStatisticsSnapshot.read(packet, length: 33)!
        precondition(bounded.fps == 0 && bounded.frameTime == 0 && bounded.fifo == 0)

        let session = PerformanceStatisticsSession()
        precondition(session.current() == nil)
        session.begin()
        let first = session.current()!
        precondition(session.accepts(first))
        session.end()
        precondition(!session.accepts(first) && session.current() == nil)
        session.begin()
        precondition(!session.accepts(first) && session.accepts(session.current()!))

        for active in [false, true] {
            for menu in [false, true] {
                for automatic in [false, true] {
                    precondition(!AmiiboPollingPolicy.needsPolling(hasSession: false,
                        applicationActive: active, menuVisible: menu, automaticUse: automatic))
                }
            }
        }
        precondition(!AmiiboPollingPolicy.needsPolling(hasSession: true, applicationActive: false,
            menuVisible: true, automaticUse: true))
        precondition(!AmiiboPollingPolicy.needsPolling(hasSession: true, applicationActive: true,
            menuVisible: false, automaticUse: false))
        precondition(AmiiboPollingPolicy.needsPolling(hasSession: true, applicationActive: true,
            menuVisible: false, automaticUse: true))
        precondition(AmiiboPollingPolicy.needsPolling(hasSession: true, applicationActive: true,
            menuVisible: true, automaticUse: false))
        print("PerformanceSamplingTests: unaligned packet, invalid values, session epochs and Amiibo demand passed")
    }
}
