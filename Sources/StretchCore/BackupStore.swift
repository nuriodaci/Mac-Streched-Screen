import Foundation

public struct BackupManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var monitorKey: String
    public var displayName: String
    public var sha256: String
    public var bytes: Int

    public init(schema: Int = 1, monitorKey: String, displayName: String, sha256: String, bytes: Int) {
        self.schema = schema
        self.monitorKey = monitorKey
        self.displayName = displayName
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public enum BackupState: Equatable, Sendable {
    /// A new factory EDID was written and verified.
    case created(URL)
    /// A byte-identical factory EDID was already present and is verified.
    case verified(URL)

    public var url: URL {
        switch self {
        case .created(let url), .verified(let url): return url
        }
    }
}

/// Create-only, crash-safe EDID storage. Existing backups are never replaced.
public struct BackupStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func applicationDefault() throws -> BackupStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return BackupStore(root: base.appendingPathComponent("Mac-Streched-Screen", isDirectory: true))
    }

    public var pendingDirectory: URL { root.appendingPathComponent("pending", isDirectory: true) }

    public var monitorsDirectory: URL { root.appendingPathComponent("monitors", isDirectory: true) }

    public func monitorDirectory(for identity: MonitorIdentity) -> URL {
        monitorsDirectory.appendingPathComponent(identity.stableKey, isDirectory: true)
    }

    public var lockURL: URL { root.appendingPathComponent("app.lock") }

    public var watchdogLogURL: URL { root.appendingPathComponent("watchdog.log") }

    /// Validates and stores the factory EDID. Refuses to overwrite different bytes.
    ///
    /// An EDID produced by this application is never accepted as a factory backup: if a previous
    /// run left an override live, archiving it would permanently destroy the only copy of the
    /// monitor's own identity. The caller must restore first.
    @discardableResult
    public func ensureFactoryBackup(_ edid: [UInt8]) throws -> BackupState {
        try Edid.validate(edid)
        guard !Edid.isOverride(edid) else {
            throw StretchError.backupConflict(
                "refusing to archive a temporary override as the factory EDID; restore the display first"
            )
        }
        let info = try Edid.parse(edid)
        guard info.identity.isValid else { throw StretchError.backupCorrupted("Invalid monitor identity.") }
        let directory = monitorDirectory(for: info.identity)
        try SecureFiles.directory(root)
        try SecureFiles.directory(monitorsDirectory)
        try SecureFiles.directory(directory)
        let edidURL = directory.appendingPathComponent("factory-edid.bin")
        let digestURL = directory.appendingPathComponent("factory-edid.sha256")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let digest = Edid.sha256Hex(edid)

        if SecureFiles.exists(edidURL) {
            let existing = [UInt8](try SecureFiles.read(edidURL))
            do {
                try Edid.validate(existing)
            } catch {
                throw StretchError.backupCorrupted("stored factory EDID is invalid")
            }
            guard existing == edid else {
                throw StretchError.backupConflict(
                    "refusing to overwrite a different EDID backup for \(info.identity.stableKey)"
                )
            }
            if SecureFiles.exists(digestURL) {
                let recorded = String(decoding: try SecureFiles.read(digestURL, maximum: 128), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard recorded == digest else {
                    throw StretchError.backupCorrupted("factory EDID checksum sidecar does not match")
                }
            } else {
                try atomicCreate(digestURL, data: Data("\(digest)\n".utf8))
            }
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                let manifest = BackupManifest(
                    monitorKey: info.identity.stableKey,
                    displayName: info.name,
                    sha256: digest,
                    bytes: edid.count
                )
                try atomicCreate(manifestURL, data: try encode(manifest))
            }
            return .verified(edidURL)
        }

        try atomicCreate(edidURL, data: Data(edid))
        try atomicCreate(digestURL, data: Data("\(digest)\n".utf8))
        let manifest = BackupManifest(
            monitorKey: info.identity.stableKey,
            displayName: info.name,
            sha256: digest,
            bytes: edid.count
        )
        try atomicCreate(manifestURL, data: try encode(manifest))
        return .created(edidURL)
    }

    public func loadFactoryBackup(_ identity: MonitorIdentity) throws -> [UInt8] {
        guard identity.isValid else { throw StretchError.backupCorrupted("Invalid monitor identity.") }
        let directory = monitorDirectory(for: identity)
        try SecureFiles.directory(monitorsDirectory)
        try SecureFiles.directory(directory)
        let data = [UInt8](try SecureFiles.read(directory.appendingPathComponent("factory-edid.bin")))
        let info = try Edid.parse(data)
        let expected = String(decoding: try SecureFiles.read(
            directory.appendingPathComponent("factory-edid.sha256"), maximum: 128
        ), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard info.identity == identity, !Edid.isOverride(data), expected == Edid.sha256Hex(data) else {
            throw StretchError.backupCorrupted("stored factory EDID checksum verification failed")
        }
        return data
    }

    public func hasFactoryBackup(_ identity: MonitorIdentity) -> Bool {
        FileManager.default.fileExists(
            atPath: monitorDirectory(for: identity).appendingPathComponent("factory-edid.bin").path
        )
    }

    private func encode(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private func atomicCreate(_ url: URL, data: Data) throws {
        try SecureFiles.create(url, data: data)
    }
}
