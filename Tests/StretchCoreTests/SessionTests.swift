import XCTest
@testable import StretchCore

final class SessionTests: XCTestCase {
    var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func session(_ platform: FakePlatform, _ guardProcess: FakeGuard = FakeGuard()) throws -> StretchSession {
        try StretchSession(platform: platform, store: BackupStore(root: root), restoreGuard: guardProcess)
    }
    func prepare(_ session: StretchSession) throws -> PreparedChange {
        try session.refresh()
        return try session.prepare(widthText: "1280", heightText: "960", refreshText: "75")
    }

    func testDiscoveryIsReadOnlyAndDoesNotResetOrSave() throws {
        let platform = try FakePlatform()
        let session = try session(platform)
        XCTAssertTrue(try session.refresh())
        XCTAssertFalse(try session.refresh())
        XCTAssertTrue(platform.applied.isEmpty)
        XCTAssertTrue(platform.resets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.store.monitorsDirectory.path))
        XCTAssertEqual(session.selectedPreset?.id, "1024x768@60")
        XCTAssertFalse(session.presets.contains { $0.isRecommended })
    }
    func testBackupThenAcknowledgedGuardThenApply() throws {
        let platform = try FakePlatform()
        let guardProcess = FakeGuard()
        let session = try session(platform, guardProcess)
        let change = try prepare(session)
        guardProcess.onArm = {
            XCTAssertEqual(try session.store.loadFactoryBackup(change.identity), Fixtures.factory())
            XCTAssertTrue(platform.applied.isEmpty)
        }
        platform.onApply = {
            XCTAssertEqual(guardProcess.armed.count, 1)
            XCTAssertNotNil(session.active)
        }
        let active = try session.apply(change, confirmSeconds: 20)
        XCTAssertEqual(try Watchdog.record(at: active.stateURL).identity, change.identity)
        XCTAssertNil(session.prepared)
    }
    func testHelperFailurePreventsMutation() throws {
        let platform = try FakePlatform(); let guardProcess = FakeGuard(); guardProcess.fail = true
        let session = try session(platform, guardProcess)
        let change = try prepare(session)
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        XCTAssertTrue(platform.applied.isEmpty)
        XCTAssertNil(session.active)
    }
    func testPartialApplyFailurePreservesGuardAndRecoveryState() throws {
        let platform = try FakePlatform(); platform.applyError = true
        let session = try session(platform)
        let change = try prepare(session)
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        let active = try XCTUnwrap(session.active)
        XCTAssertTrue(SecureFiles.exists(active.stateURL))
        XCTAssertThrowsError(try session.keep()) // A partially failed apply cannot be confirmed.
        try session.revert()
        XCTAssertFalse(SecureFiles.exists(active.stateURL))
        XCTAssertNil(session.active)
    }
    func testFailedRestoreKeepsRecordAndActiveState() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        let active = try session.apply(change, confirmSeconds: 20)
        platform.resetError = true
        XCTAssertThrowsError(try session.revert())
        XCTAssertTrue(SecureFiles.exists(active.stateURL))
        XCTAssertNotNil(session.active)
    }
    func testKeepCancelsAndHelperCannotResetLater() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        let active = try session.apply(change, confirmSeconds: 20)
        try session.keep()
        XCTAssertNil(session.active)
        XCTAssertFalse(try Watchdog.restore(active.stateURL, platform: platform))
        XCTAssertTrue(platform.resets.isEmpty)
    }
    func testExpiredPersistedDeadlineCannotBeKept() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        let active = try session.apply(change, confirmSeconds: 20)
        var record = try Watchdog.record(at: active.stateURL)
        record.deadlineUnixMS = Clock.nowMS - 1
        try FileManager.default.removeItem(at: active.stateURL)
        try SecureFiles.create(active.stateURL, data: JSONEncoder().encode(record))
        XCTAssertThrowsError(try session.keep())
        XCTAssertTrue(SecureFiles.exists(active.stateURL))
    }
    func testKeepAfterHelperRestoreIsRejected() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        let active = try session.apply(change, confirmSeconds: 20)
        XCTAssertTrue(try Watchdog.restore(active.stateURL, platform: platform))
        XCTAssertThrowsError(try session.keep())
        try session.revert()
        XCTAssertEqual(platform.resets.count, 1) // No duplicate reset after helper succeeded.
    }
    func testApplyReturningAfterHelperCancellationRequestsAnotherReset() throws {
        let platform = try FakePlatform(); let guardProcess = FakeGuard()
        let session = try session(platform, guardProcess)
        let change = try prepare(session)
        platform.onApply = { try Watchdog.cancel(XCTUnwrap(guardProcess.armed.first)) }
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        XCTAssertEqual(platform.resets.count, 1)
        XCTAssertNil(session.active)
    }
    func testPersistedRecordBlocksAnotherTestBeforeAnyApply() throws {
        let platform = try FakePlatform(); let guardProcess = FakeGuard()
        let session = try session(platform, guardProcess)
        let change = try prepare(session)
        _ = try guardProcess.arm(store: session.store, identity: change.identity, mode: "old", timeout: 20)
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        XCTAssertTrue(platform.applied.isEmpty)
    }
    func testConcurrentSecondApplyAndStalePreparedChangeAreRejected() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        _ = try session.apply(change, confirmSeconds: 20)
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        XCTAssertThrowsError(try session.prepare(widthText: "1024", heightText: "768", refreshText: "60"))
        XCTAssertEqual(platform.applied.count, 1)
    }
    func testFailedPrepareInvalidatesPreviousChange() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let old = try prepare(session)
        XCTAssertThrowsError(try session.prepare(widthText: "oops", heightText: "768", refreshText: "60"))
        XCTAssertNil(session.prepared)
        XCTAssertThrowsError(try session.apply(old, confirmSeconds: 20))
    }
    func testHotUnplugAndDuplicateIdentityRefuseApply() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        platform.stored = []
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        platform.stored = try [Display(serviceIndex: 0, edid: Fixtures.factory()), Display(serviceIndex: 1, edid: Fixtures.factory())]
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
        XCTAssertTrue(platform.applied.isEmpty)
    }
    func testChangedEDIDBetweenPrepareAndApplyIsRejected() throws {
        let platform = try FakePlatform(); let session = try session(platform)
        let change = try prepare(session)
        var changed = Fixtures.factory(); changed[23] = 121; Fixtures.checksum(&changed)
        platform.stored = try [Display(serviceIndex: 0, edid: changed)]
        XCTAssertThrowsError(try session.apply(change, confirmSeconds: 20))
    }
    func testOverrideWithoutFactoryBackupDoesNotAutoReset() throws {
        let override = try Edid.generate(original: Fixtures.factory(), width: 1024, height: 768, refreshHz: 60).edid
        let platform = try FakePlatform([override]); let session = try session(platform)
        XCTAssertThrowsError(try session.refresh())
        XCTAssertTrue(platform.resets.isEmpty)
        XCTAssertFalse(session.store.hasFactoryBackup(try Edid.parse(override).identity))
    }
    func testInterruptedRecoveryUsesExactRecordAndDoesNotMutateDisplay() throws {
        let platform = try FakePlatform(); let guardProcess = FakeGuard()
        let session = try session(platform, guardProcess)
        let identity = try Edid.parse(Fixtures.factory()).identity
        let url = try guardProcess.arm(store: session.store, identity: identity, mode: "test", timeout: 20)
        try session.recoverInterruptedChange()
        XCTAssertEqual(session.active?.stateURL.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
        XCTAssertTrue(platform.resets.isEmpty)
        XCTAssertThrowsError(try session.keep()) // It isn't actually active on the fake display.
    }
    func testSecondSessionIsRejected() throws {
        let platform = try FakePlatform(); let first = try session(platform)
        XCTAssertThrowsError(try session(platform))
        withExtendedLifetime(first) {}
    }
    func testNoDisplay() throws {
        let session = try session(FakePlatform([]))
        XCTAssertFalse(try session.refresh())
        XCTAssertTrue(session.presets.isEmpty)
        XCTAssertThrowsError(try session.prepare(widthText: "1024", heightText: "768", refreshText: "60"))
    }
}
