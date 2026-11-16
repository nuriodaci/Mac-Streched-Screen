import XCTest
@testable import StretchCore

final class WatchdogTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func record(deadline: Int64 = Clock.nowMS + 20_000) throws -> URL {
        let store = BackupStore(root: root)
        let url = store.pendingDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let change = PendingChange(identity: try Edid.parse(Fixtures.factory()).identity,
                                   deadlineUnixMS: deadline, requestedMode: "1024 × 768")
        try SecureFiles.create(url, data: JSONEncoder().encode(change))
        return url
    }
    func testCancelledRecordCannotRestore() throws {
        let url = try record(); let platform = try FakePlatform()
        try Watchdog.cancel(url); try Watchdog.cancel(url)
        XCTAssertFalse(try Watchdog.restore(url, platform: platform))
        XCTAssertTrue(platform.resets.isEmpty)
    }
    func testFailurePreservesRecordForRetry() throws {
        let url = try record(); let platform = try FakePlatform(); platform.resetError = true
        XCTAssertThrowsError(try Watchdog.restore(url, platform: platform))
        XCTAssertTrue(SecureFiles.exists(url))
        platform.resetError = false
        XCTAssertTrue(try Watchdog.restore(url, platform: platform))
        XCTAssertFalse(SecureFiles.exists(url))
    }
    func testInvalidSchemaAndIdentityRejected() throws {
        let url = try record()
        var change = try Watchdog.record(at: url); change.schema = 999
        try FileManager.default.removeItem(at: url)
        try SecureFiles.create(url, data: JSONEncoder().encode(change))
        XCTAssertThrowsError(try Watchdog.record(at: url))
        XCTAssertThrowsError(try Watchdog.restore(url, platform: FakePlatform()))
    }
    func testCorruptRecordBlocksNewTransactionsInsteadOfSilentlyIgnoring() throws {
        let store = BackupStore(root: root)
        try SecureFiles.create(store.pendingDirectory.appendingPathComponent("broken.json"), data: Data("bad".utf8))
        XCTAssertThrowsError(try Watchdog.records(store: store))
    }
    func testCorruptRecordDoesNotDisableManualHardwareRecovery() throws {
        let store = BackupStore(root: root)
        try SecureFiles.create(store.pendingDirectory.appendingPathComponent("broken.json"), data: Data("bad".utf8))
        let platform = try FakePlatform()
        XCTAssertThrowsError(try Watchdog.restoreAll(store: store, platform: platform))
        XCTAssertTrue(SecureFiles.exists(store.pendingDirectory.appendingPathComponent("broken.json")))
    }
    func testHelperMustBeDedicatedExecutableNotTestHost() throws {
        let guardProcess = ProcessRestoreGuard(executable: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertThrowsError(try guardProcess.arm(store: BackupStore(root: root),
                                                 identity: Edid.parse(Fixtures.factory()).identity,
                                                 mode: "test", timeout: 20))
        XCTAssertFalse(SecureFiles.exists(root))
    }
    func testDedicatedFakeHelperReadinessHandshakeAndCancellation() throws {
        // A shell-only protocol stub. Never imports IOKit or accesses a real monitor.
        try SecureFiles.directory(root)
        let executable = root.appendingPathComponent("StretchRestoreHelper")
        try Data("""
        #!/bin/sh
        test "$1" = "--state" || exit 64
        printf ready > "$2.ready"
        while test -f "$2"; do sleep 0.05; done
        rm -f "$2.ready"
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let store = BackupStore(root: root)
        let guardProcess = ProcessRestoreGuard(executable: executable)
        let url = try guardProcess.arm(store: store, identity: Edid.parse(Fixtures.factory()).identity,
                                        mode: "fake", timeout: 20)
        XCTAssertTrue(SecureFiles.exists(Watchdog.readyURL(url)))
        try guardProcess.cancel(url)
        XCTAssertFalse(SecureFiles.exists(url))
        Thread.sleep(forTimeInterval: 0.15)
    }
    func testHelperEarlyExitFailsClosedAndRemovesUnappliedRecord() throws {
        try SecureFiles.directory(root)
        let executable = root.appendingPathComponent("StretchRestoreHelper")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let store = BackupStore(root: root)
        XCTAssertThrowsError(try ProcessRestoreGuard(executable: executable).arm(
            store: store, identity: Edid.parse(Fixtures.factory()).identity, mode: "fake", timeout: 20))
        XCTAssertTrue(try Watchdog.records(store: store).isEmpty)
    }
    func testKeepRestoreRaceIsSerialized() throws {
        // Deliberately race both sides repeatedly; after cancellation returns no later reset may begin.
        for _ in 0..<30 {
            let url = try record()
            let platform = try FakePlatform()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { defer { group.leave() }; try? Watchdog.cancel(url) }
            group.enter()
            DispatchQueue.global().async { defer { group.leave() }; _ = try? Watchdog.restore(url, platform: platform) }
            XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
            XCTAssertFalse(SecureFiles.exists(url))
            XCTAssertLessThanOrEqual(platform.resets.count, 1)
            XCTAssertFalse(try Watchdog.restore(url, platform: platform))
        }
    }
    func testSymlinkAndOversizedRecordsRejected() throws {
        let url = try record()
        let target = root.appendingPathComponent("target")
        try Data("private".utf8).write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try Watchdog.record(at: url))
        XCTAssertEqual(try String(contentsOf: target), "private")
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 0, count: 40_000).write(to: url)
        XCTAssertThrowsError(try Watchdog.record(at: url))
    }
}
