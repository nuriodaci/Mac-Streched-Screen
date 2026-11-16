import XCTest
import Darwin
@testable import StretchCore

final class BackupStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-streched-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNamedPipeStateIsRejectedWithoutWaitingForWriter() throws {
        let pipe = root.appendingPathComponent("state.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try SecureFiles.read(pipe))
    }

    func testStateReadHonorsExactByteLimit() throws {
        let file = root.appendingPathComponent("bounded.bin")
        try SecureFiles.create(file, data: Data(repeating: 42, count: 128))
        XCTAssertEqual(try SecureFiles.read(file, maximum: 128).count, 128)
        XCTAssertThrowsError(try SecureFiles.read(file, maximum: 127))
    }

    func factory() throws -> [UInt8] { Fixtures.factory() }

    func testCreatesThenVerifiesWithoutOverwriting() throws {
        let store = BackupStore(root: root)
        let edid = try factory()
        let first = try store.ensureFactoryBackup(edid)
        guard case .created(let url) = first else { return XCTFail("expected created") }
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), edid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
            .appendingPathComponent("factory-edid.sha256").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
            .appendingPathComponent("manifest.json").path))

        guard case .verified = try store.ensureFactoryBackup(edid) else {
            return XCTFail("expected verified")
        }
        XCTAssertEqual(try store.loadFactoryBackup(try Edid.parse(edid).identity), edid)
    }

    func testRefusesToOverwriteDifferentEdid() throws {
        let store = BackupStore(root: root)
        let edid = try factory()
        try store.ensureFactoryBackup(edid)
        let (different, _) = try Edid.generate(original: edid, width: 1024, height: 768, refreshHz: 60)
        XCTAssertThrowsError(try store.ensureFactoryBackup(different)) { error in
            guard case .backupConflict = (error as? StretchError) else {
                return XCTFail("expected backupConflict, got \(error)")
            }
        }
        XCTAssertEqual([UInt8](try Data(contentsOf: store.monitorDirectory(for: try Edid.parse(edid).identity)
            .appendingPathComponent("factory-edid.bin"))), edid)
    }

    func testRepairsMissingSidecarButDetectsMismatchedChecksum() throws {
        let store = BackupStore(root: root)
        let edid = try factory()
        let state = try store.ensureFactoryBackup(edid)
        let directory = state.url.deletingLastPathComponent()
        let digestURL = directory.appendingPathComponent("factory-edid.sha256")
        try FileManager.default.removeItem(at: digestURL)
        guard case .verified = try store.ensureFactoryBackup(edid) else {
            return XCTFail("expected verified after sidecar repair")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: digestURL.path))

        try Data("deadbeef\n".utf8).write(to: digestURL)
        XCTAssertThrowsError(try store.ensureFactoryBackup(edid))
        XCTAssertThrowsError(try store.loadFactoryBackup(try Edid.parse(edid).identity))
    }

    func testManifestIsNonSensitiveAndComplete() throws {
        let store = BackupStore(root: root)
        let edid = try factory()
        let state = try store.ensureFactoryBackup(edid)
        let data = try Data(contentsOf: state.url.deletingLastPathComponent()
            .appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        let info = try Edid.parse(edid)
        XCTAssertEqual(manifest.monitorKey, info.identity.stableKey)
        XCTAssertEqual(manifest.displayName, info.name)
        XCTAssertEqual(manifest.sha256, Edid.sha256Hex(edid))
        XCTAssertEqual(manifest.bytes, edid.count)
        XCTAssertEqual(manifest.schema, 1)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("hostname"))
        XCTAssertFalse(text.contains(NSUserName()))
    }

    func testRefusesToArchiveAnOverrideAsFactoryEdid() throws {
        let store = BackupStore(root: root)
        let factory = try factory()
        let (override, _) = try Edid.generate(original: factory, width: 1280, height: 960, refreshHz: 75)
        XCTAssertTrue(Edid.isOverride(override))
        // Archiving an override would permanently destroy the factory identity.
        XCTAssertThrowsError(try store.ensureFactoryBackup(override)) { error in
            guard case .backupConflict(let message)? = error as? StretchError else {
                return XCTFail("expected backupConflict, got \(error)")
            }
            XCTAssertTrue(message.contains("temporary override"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("monitors").path))
    }

    func testInvalidEdidIsRejectedBeforeWriting() throws {
        let store = BackupStore(root: root)
        XCTAssertThrowsError(try store.ensureFactoryBackup([]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("monitors").path))
    }

    func testStableKeyIsFilenameSafe() {
        // Hostile serial text must not escape the monitors directory.
        let identity = MonitorIdentity(vendor: "ABC", product: 1, serial: 1, serialText: "../../../etc")
        let key = identity.stableKey
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("."))
        XCTAssertTrue(key.hasPrefix("ABC-0001-00000001-"))
        XCTAssertLessThanOrEqual(key.count, 64)

        let empty = MonitorIdentity(vendor: "ABC", product: 1, serial: 1, serialText: "")
        XCTAssertEqual(empty.stableKey, "ABC-0001-00000001-none")

        let normal = MonitorIdentity(vendor: "DEL", product: 0xA0B1, serial: 1, serialText: "ABC123")
        XCTAssertEqual(normal.stableKey, "DEL-A0B1-00000001-ABC123")

        // Distinct monitors never collide.
        XCTAssertNotEqual(identity.stableKey, empty.stableKey)
    }
}
