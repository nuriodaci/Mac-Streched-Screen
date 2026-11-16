import Foundation
@testable import StretchCore

/// Synthetic EDID, not captured from a user's monitor. No vendor mode whitelist in production.
enum Fixtures {
    static func factory(vendor: String = "ABC", product: UInt16 = 1, serial: UInt32 = 1,
                        width: UInt16 = 1920, height: UInt16 = 1080,
                        vertical: (UInt8, UInt8) = (48, 76),
                        horizontal: (UInt8, UInt8) = (30, 85), clock: UInt8 = 18) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<8, with: Edid.header)
        let chars = Array(vendor.utf8)
        let word = UInt16(chars[0] - 64) << 10 | UInt16(chars[1] - 64) << 5 | UInt16(chars[2] - 64)
        bytes[8] = UInt8(word >> 8); bytes[9] = UInt8(word & 255)
        bytes[10] = UInt8(product & 255); bytes[11] = UInt8(product >> 8)
        for i in 0..<4 { bytes[12 + i] = UInt8((serial >> (i * 8)) & 255) }
        bytes[18] = 1; bytes[19] = 4; bytes[20] = 0x80
        bytes[21] = 53; bytes[22] = 30; bytes[23] = 120; bytes[24] = 2
        for i in 38..<54 { bytes[i] = 1 }
        let timing = Timing(pixelClockHz: 148_500_000, hActive: width, hBlank: 280,
                            hSyncOffset: 88, hSyncWidth: 44, vActive: height, vBlank: 45,
                            vSyncOffset: 4, vSyncWidth: 5, positiveHSync: true, positiveVSync: true)
        bytes.replaceSubrange(54..<72, with: Edid.encodeDetailedTiming(timing, widthMM: 530, heightMM: 300))
        bytes.replaceSubrange(72..<90, with: Edid.textDescriptor(tag: 0xFC, text: "Sample Panel"))
        bytes.replaceSubrange(90..<108, with: Edid.textDescriptor(tag: 0xFF, text: "TEST-\(serial)"))
        bytes[111] = 0xFD; bytes[113] = vertical.0; bytes[114] = vertical.1
        bytes[115] = horizontal.0; bytes[116] = horizontal.1; bytes[117] = clock
        checksum(&bytes)
        return bytes
    }
    static func checksum(_ bytes: inout [UInt8]) {
        bytes[127] = 0 &- bytes[..<127].reduce(UInt8(0), &+)
    }
}

final class FakePlatform: DisplayPlatform, @unchecked Sendable {
    var stored: [Display]
    var applied: [[UInt8]] = []
    var resets: [MonitorIdentity] = []
    var applyError = false
    var resetError = false
    var onApply: (() throws -> Void)?
    init(_ edids: [[UInt8]] = [Fixtures.factory()]) throws {
        stored = try edids.enumerated().map { try Display(serviceIndex: $0.offset, edid: $0.element) }
    }
    func displays() throws -> [Display] { stored }
    func applyOverride(_ edid: [UInt8], to identity: MonitorIdentity) throws {
        try onApply?()
        applied.append(edid)
        if let index = stored.firstIndex(where: { $0.info.identity == identity }) {
            stored[index] = try Display(serviceIndex: stored[index].id, edid: edid)
        }
        // Models a partially successful private API that returns an error after changing hardware.
        if applyError { throw StretchError.ioKit("simulated partial apply failure") }
    }
    func resetOverride(for identity: MonitorIdentity) throws {
        resets.append(identity)
        if resetError { throw StretchError.ioKit("simulated reset failure") }
    }
    func resetAll() throws -> Int { stored.count }
}

final class FakeGuard: RestoreGuard {
    var armed: [URL] = []
    var fail = false
    var onArm: (() throws -> Void)?
    func arm(store: BackupStore, identity: MonitorIdentity, mode: String, timeout: TimeInterval) throws -> URL {
        try onArm?()
        if fail { throw StretchError.watchdogFailed("simulated handshake failure") }
        let url = store.pendingDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let change = PendingChange(identity: identity, deadlineUnixMS: Clock.nowMS + Int64(timeout * 1000), requestedMode: mode)
        try SecureFiles.create(url, data: JSONEncoder().encode(change))
        armed.append(url)
        return url
    }
    func cancel(_ url: URL) throws { try Watchdog.cancel(url) }
}
