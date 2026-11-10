import Foundation
import Dispatch

/// 测试直接调用生产缓存、指纹、回调槽和 BLE 解码，避免用复制实现验证自身。
@main
@MainActor
struct UIRuntimeOptimizationTests {
    private static func require(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        checkCallbacks()
        checkObserversAndSessions()
        checkLoadingProgress()
        checkCacheRules()
        try checkDiskInvalidation()
        checkSteamReports()
        checkSteamDelta()
        print("UIRuntimeOptimizationTests: callbacks, library invalidation, bounded icons and ordered Steam input passed")
    }

    static func checkCallbacks() {
        let slot = CallbackHandlerSlot<Int>()
        let total = LockedTotal()
        slot.replace { @Sendable value in total.add(value) }
        slot.invoke(2)
        slot.replace { @Sendable value in total.add(value * 3) }
        slot.invoke(2)
        slot.replace(nil)
        slot.invoke(100)
        precondition(total.value == 8)

        // 正在运行的旧回调可结束；替换后的新调用只能进入新回调，撤销不释放旧栈仍借用的闭包。
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        slot.replace { @Sendable value in
            entered.signal()
            precondition(release.wait(timeout: .now() + 5) == .success)
            total.add(value)
        }
        DispatchQueue.global().async { slot.invoke(4); finished.signal() }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        slot.replace { @Sendable value in total.add(value * 2) }
        slot.invoke(3)
        release.signal()
        precondition(finished.wait(timeout: .now() + 5) == .success)
        precondition(total.value == 18)

        // 回调内重入替换，以及旧捕获对象析构重入，都不能在注册锁内死锁。
        slot.replace { @Sendable value in slot.replace { @Sendable next in total.add(next) }; total.add(value) }
        slot.invoke(1)
        slot.invoke(2)
        do {
            let owner = ReleaseProbe { slot.replace { @Sendable value in total.add(value) } }
            slot.replace { @Sendable _ in withExtendedLifetime(owner) {} }
        }
        slot.replace(nil)
        slot.invoke(3)
        precondition(total.value == 24)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in slot.invoke(1) }
        precondition(total.value == 224)
    }

    static func checkObserversAndSessions() {
        let observers = RemovableObservers<Int>()
        var count = 0
        var selfRemoving: UUID?
        selfRemoving = observers.add { value in
            count += value
            if let selfRemoving { observers.remove(selfRemoving) }
        }
        let retained = observers.add { count += $0 }
        precondition(observers.count == 2)
        observers.send(1)
        precondition(count == 2 && observers.count == 1)
        observers.send(2)
        precondition(count == 4)
        observers.remove(retained)
        observers.remove(retained)
        observers.send(10)
        precondition(count == 4 && observers.count == 0)

        let session = CallbackSessionEpoch()
        precondition(session.current() == nil)
        session.begin()
        let first = session.current()!
        precondition(session.accepts(first))
        session.end()
        precondition(!session.accepts(first) && session.current() == nil)
        session.begin()
        precondition(!session.accepts(first) && session.accepts(session.current()!))
    }

    static func checkLoadingProgress() {
        func decode(_ text: String) -> LoadingProgressSnapshot? { .decode(Data(text.utf8)) }
        let progress = decode("[\"PTC\",5,100]")!
        precondition(progress.type == "PTC" && progress.current == 5 && progress.total == 100 && progress.visible)
        precondition(decode("[\"Shaders\",100,100]")?.visible == false)
        precondition(decode("[\"Shaders\",0,0]")?.visible == false)
        for bad in ["null", "[]", "{}", "[\"Other\",1,20]", "[\"PTC\",-1,20]", "[\"PTC\",1,-2]",
                    "[\"PTC\",21,20]", "[\"PTC\",true,20]", "[\"PTC\",1.5,20]", "[\"PTC\",\"1\",20]",
                    "[\"PTC\",1,20,0]", "[\"PTC\",1]", "[\"PTC\",1,999999999999999999999]"] {
            precondition(decode(bad) == nil, bad)
        }
    }

    static func checkCacheRules() {
        let file = LibraryFileStamp(identity: "device:inode", bytes: 100, modified: 10, created: 1)
        let original = LibraryMetadataSignature(file: file, environment: "keys:en", dependency: "updateA")
        var cache = LibraryMetadataCache<String>()
        cache.store("Game", for: "rom", signature: original)
        precondition(cache.value(for: "rom", matching: original) == "Game")
        let changedFiles = [
            LibraryFileStamp(identity: "device:replacement", bytes: 100, modified: 10, created: 1),
            LibraryFileStamp(identity: "device:inode", bytes: 101, modified: 10, created: 1),
            LibraryFileStamp(identity: "device:inode", bytes: 100, modified: 11, created: 1),
            LibraryFileStamp(identity: "device:inode", bytes: 100, modified: 10, created: 2)
        ]
        for changed in changedFiles {
            precondition(cache.value(for: "rom", matching: .init(file: changed, environment: "keys:en", dependency: "updateA")) == nil)
        }
        precondition(cache.value(for: "rom", matching: .init(file: file, environment: "newkeys:en", dependency: "updateA")) == nil)
        precondition(cache.value(for: "rom", matching: .init(file: file, environment: "keys:zh", dependency: "updateA")) == nil)
        precondition(cache.value(for: "rom", matching: .init(file: file, environment: "keys:en", dependency: "updateB")) == nil)
        cache.store("Other", for: "other", signature: original)
        cache.retain(keys: ["rom"])
        precondition(cache.count == 1 && cache.previous(for: "other") == nil)
        cache.remove("rom")
        precondition(cache.count == 0)

        var images = BoundedLRUCache<String, Int>(countLimit: 2, costLimit: 10)
        images.insert(1, for: "a", cost: 4)
        images.insert(2, for: "b", cost: 4)
        precondition(images.value(for: "a") == 1)
        images.insert(3, for: "c", cost: 4)
        precondition(images.value(for: "b") == nil && images.totalCost == 8 && images.count == 2)
        images.insert(4, for: "a", cost: 7)
        precondition(images.value(for: "c") == nil && images.totalCost == 7 && images.count == 1)
        images.insert(5, for: "a", cost: 11)
        precondition(images.value(for: "a") == nil && images.totalCost == 0)
        images.insert(6, for: "negative", cost: -1)
        precondition(images.count == 0)
        images.insert(7, for: "zero", cost: 0)
        images.removeAll()
        precondition(images.count == 0 && images.totalCost == 0)
        var disabled = BoundedLRUCache<Int, Int>(countLimit: 0, costLimit: 0)
        disabled.insert(0, for: 0, cost: 0)
        precondition(disabled.count == 0)
    }

    static func checkDiskInvalidation() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("MeloNX-library-tests-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let rom = root.appendingPathComponent("rom.nsp")
        try Data([1, 2, 3]).write(to: rom)
        let initial = try LibraryFileStamp.read(rom)
        require(try LibraryFileStamp.read(rom) == initial)
        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: initial.modified + 10)], ofItemAtPath: rom.path)
        require(try LibraryFileStamp.read(rom) != initial)
        let replacement = root.appendingPathComponent("replacement.nsp")
        try Data([3, 2, 1]).write(to: replacement)
        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: initial.modified)], ofItemAtPath: replacement.path)
        try files.removeItem(at: rom)
        try files.moveItem(at: replacement, to: rom)
        require(try LibraryFileStamp.read(rom).identity != initial.identity)

        let keys = root.appendingPathComponent("prod.keys")
        require(try LibraryDependencyFingerprint.digestFile(keys) == "missing")
        try Data("keyA".utf8).write(to: keys)
        let firstDigest = try LibraryDependencyFingerprint.digestFile(keys)
        let keysStamp = try LibraryFileStamp.read(keys)
        try Data("keyB".utf8).write(to: keys)
        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: keysStamp.modified)], ofItemAtPath: keys.path)
        require(try LibraryDependencyFingerprint.digestFile(keys) != firstDigest)

        let title = "0100000000000007"
        let metadata = root.appendingPathComponent("games/0100000000000000/updates.json")
        try files.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        func dependency() throws -> String { try LibraryDependencyFingerprint.update(titleId: title, documents: root) }
        require(try dependency() == "missing")
        try Data("{\"selected\":\"update.nsp\",\"paths\":[\"update.nsp\"]}".utf8).write(to: metadata)
        let absentUpdate = try dependency()
        let update = root.appendingPathComponent("update.nsp")
        try Data([1, 2]).write(to: update)
        let presentUpdate = try dependency()
        precondition(presentUpdate != absentUpdate)
        try Data([1, 2, 3]).write(to: update)
        require(try dependency() != presentUpdate)
        try Data("{\"selected\":\"\",\"paths\":[]}".utf8).write(to: metadata)
        require(try dependency() != presentUpdate)
        try Data("invalid".utf8).write(to: metadata)
        do { _ = try dependency(); preconditionFailure("Corrupt metadata must report an error") }
        catch { }
    }

    static func checkSteamReports() {
        var bytes = [UInt8](repeating: 0, count: 45)
        func set16(_ offset: Int, _ value: Int16) {
            let bits = UInt16(bitPattern: value)
            bytes[offset] = UInt8(truncatingIfNeeded: bits)
            bytes[offset + 1] = UInt8(bits >> 8)
        }
        bytes[1] = 0x01; bytes[3] = 0x08
        set16(5, .max); set16(7, -1)
        set16(9, .min); set16(11, .max)
        set16(13, 16384); set16(15, -16384)
        bytes[29] = 1
        set16(33, 16384); set16(35, -16384); set16(37, 8192)
        set16(39, 16384); set16(41, -16384); set16(43, 8192)
        var decoder = SteamControllerDecoder()
        let first = decoder.decode(Data(bytes), reportID: 0x45)!
        precondition(first.buttons == 0x80001 && first.leftTrigger == 1 && first.rightTrigger == 0)
        precondition(first.stick == SIMD2(-1, 1) && first.rightStick.y == -0.5)
        precondition(first.accelerometer == SIMD3(-1, -1, 0.5))
        precondition(first.gyroscope == SIMD3(1000, 1000, -500))
        let repeatReport = decoder.decode(Data(bytes), reportID: 0x45)!
        precondition(repeatReport.accelerometer == nil && repeatReport.gyroscope == nil)
        bytes[31] = 2
        precondition(decoder.decode(Data(bytes), reportID: 0x47)?.gyroscope != nil)
        let prefixed = Data([0xff]) + Data(bytes)
        var slicedDecoder = SteamControllerDecoder()
        precondition(slicedDecoder.decode(prefixed.dropFirst(), reportID: 0x47)?.buttons == first.buttons)
        precondition(decoder.decode(Data(bytes.dropLast()), reportID: 0x45) == nil)
        precondition(decoder.decode(Data(bytes), reportID: 0x44) == nil)
    }

    static func checkSteamDelta() {
        var delta = SteamInputDelta()
        var state = SteamControllerState()
        let epoch = SteamInputDelta.Epoch(revision: 1, session: 1, attachment: 1)
        let first = delta.update(state, epoch: epoch)
        precondition(first.buttons == UInt32.max && first.leftTrigger && first.rightTrigger && first.leftStick && first.rightStick)
        precondition(delta.update(state, epoch: epoch).isEmpty)
        state.buttons = 1
        precondition(delta.update(state, epoch: epoch).buttons == 1)
        state.buttons = 0
        precondition(delta.update(state, epoch: epoch).buttons == 1)
        state.leftTrigger = 0.2
        precondition(delta.update(state, epoch: epoch).leftTrigger)
        state.rightTrigger = 0.3
        precondition(delta.update(state, epoch: epoch).rightTrigger)
        state.stick = SIMD2(0.4, 0.5)
        precondition(delta.update(state, epoch: epoch).leftStick)
        state.rightStick = SIMD2(-0.4, -0.5)
        precondition(delta.update(state, epoch: epoch).rightStick)
        state.gyroscope = SIMD3(1, 2, 3)
        precondition(delta.update(state, epoch: epoch).isEmpty)
        for next in [SteamInputDelta.Epoch(revision: 2, session: 1, attachment: 1),
                     .init(revision: 2, session: nil, attachment: 1),
                     .init(revision: 2, session: 2, attachment: 1),
                     .init(revision: 2, session: 2, attachment: 2)] {
            precondition(delta.update(state, epoch: next).buttons == UInt32.max)
        }
        let revision = SteamInputRevision()
        let before = revision.current
        revision.advance()
        precondition(revision.current != before)
    }
}

private nonisolated final class LockedTotal: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ value: Int) { lock.lock(); total += value; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return total }
}

private nonisolated final class ReleaseProbe: @unchecked Sendable {
    private let onRelease: @Sendable () -> Void
    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}
