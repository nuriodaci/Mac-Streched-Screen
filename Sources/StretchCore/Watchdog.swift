import Foundation
import Darwin

public struct PendingChange: Codable, Equatable, Sendable {
    public var schema: Int
    public var identity: MonitorIdentity
    public var deadlineUnixMS: Int64
    public var requestedMode: String

    public init(schema: Int = 1, identity: MonitorIdentity, deadlineUnixMS: Int64, requestedMode: String) {
        self.schema = schema
        self.identity = identity
        self.deadlineUnixMS = deadlineUnixMS
        self.requestedMode = requestedMode
    }

    func validate() throws {
        guard schema == 1, identity.isValid, requestedMode.utf8.count <= 128,
              deadlineUnixMS > 0 else {
            throw StretchError.watchdogFailed("Invalid restore record.")
        }
    }
}

public enum Clock {
    public static var nowMS: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// Injected in unit tests. A fake platform must NEVER accidentally spawn a hardware helper.
public protocol RestoreGuard {
    func arm(store: BackupStore, identity: MonitorIdentity, mode: String, timeout: TimeInterval) throws -> URL
    func cancel(_ url: URL) throws
}

/// Separate, narrowly scoped executable; never self-spawn the GUI, XCTest, or an arbitrary caller.
public struct ProcessRestoreGuard: RestoreGuard {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func arm(store: BackupStore, identity: MonitorIdentity, mode: String, timeout: TimeInterval) throws -> URL {
        guard (5...60).contains(timeout), executable.lastPathComponent == "StretchRestoreHelper",
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StretchError.watchdogFailed("The bundled restore helper is missing or invalid. Reinstall the app.")
        }
        try SecureFiles.directory(store.root)
        try SecureFiles.directory(store.pendingDirectory)
        let url = store.pendingDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let record = PendingChange(identity: identity,
                                   deadlineUnixMS: Clock.nowMS + Int64(timeout * 1000), requestedMode: mode)
        try record.validate()
        try SecureFiles.create(url, data: JSONEncoder().encode(record))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--state", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? Watchdog.cancel(url)
            throw error
        }
        // A successful spawn is NOT proof the helper is alive and able to read the record.
        // Wait for its readiness handshake before allowing any display mutation.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if SecureFiles.exists(Watchdog.readyURL(url)), process.isRunning { return url }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try? Watchdog.cancel(url)
        if process.isRunning { process.terminate() }
        throw StretchError.watchdogFailed("Restore helper did not acknowledge readiness. No display change was made.")
    }

    public func cancel(_ url: URL) throws { try Watchdog.cancel(url) }
}

public enum Watchdog {
    static func readyURL(_ url: URL) -> URL { url.appendingPathExtension("ready") }
    static func lockURL(_ url: URL) -> URL { url.appendingPathExtension("lock") }

    public static func record(at url: URL) throws -> PendingChange {
        let record = try JSONDecoder().decode(PendingChange.self, from: SecureFiles.read(url))
        try record.validate()
        return record
    }

    /// Keep and rollback use the SAME cross-process lock. A late Keep can never race a reset.
    public static func cancel(_ url: URL) throws {
        let lock = try FileLock(lockURL(url))
        defer { withExtendedLifetime(lock) {} }
        try removeRecord(url)
    }

    private static func removeRecord(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw SecureFiles.posixError() }
        unlink(readyURL(url).path)
    }

    /// Returns false when already cancelled. Failed restores leave the record intact for recovery.
    @discardableResult
    public static func restore(_ url: URL, platform: DisplayPlatform) throws -> Bool {
        let lock = try FileLock(lockURL(url))
        defer { withExtendedLifetime(lock) {} }
        guard SecureFiles.exists(url) else { return false }
        let change = try record(at: url)
        try platform.resetOverride(for: change.identity)
        try removeRecord(url)
        return true
    }

    /// Purely enumerates records: startup/discovery never changes a display.
    public static func records(store: BackupStore) throws -> [(url: URL, change: PendingChange)] {
        guard SecureFiles.exists(store.pendingDirectory) else { return [] }
        try SecureFiles.directory(store.pendingDirectory)
        return try FileManager.default.contentsOfDirectory(at: store.pendingDirectory,
                                                           includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { ($0, try record(at: $0)) }
    }

    /// Explicit terminal recovery, serialized with apply. Only records with successful resets are
    /// removed. Corrupt records are reported rather than silently granting permission for a new test.
    public static func restoreAll(store: BackupStore, platform: DisplayPlatform) throws -> Int {
        let operation = try FileLock(store.root.appendingPathComponent("operation.lock"))
        defer { withExtendedLifetime(operation) {} }
        var failures: [String] = []
        do {
            for entry in try records(store: store) {
                do { _ = try restore(entry.url, platform: platform) }
                catch { failures.append(error.displayMessage) }
            }
        } catch { failures.append(error.displayMessage) }
        // A corrupt record must not disable the independent manual hardware recovery path.
        // It is retained and reported, and still blocks future tests until diagnosed.
        let count = try platform.resetAll()
        if !failures.isEmpty {
            throw StretchError.watchdogFailed("Hardware restore requested; unresolved recovery records: \(failures.joined(separator: "; "))")
        }
        return count
    }

    /// Entrypoint for the separate helper. No GUI, no subprocess spawning, no arbitrary commands.
    public static func run(stateURL: URL, platform: DisplayPlatform) throws {
        // Foundation Process starts a separate process group on macOS; it survives the UI exiting.
        // Do not call setsid(): a Process child is already a group leader (setsid would fail EPERM).
        _ = try record(at: stateURL)
        try SecureFiles.create(readyURL(stateURL), data: Data("ready\n".utf8))
        defer { unlink(readyURL(stateURL).path) }
        let start = ProcessInfo.processInfo.systemUptime
        let record = try record(at: stateURL)
        let remaining = max(0, min(60, Double(record.deadlineUnixMS - Clock.nowMS) / 1000))
        // Monotonic deadline prevents wall-clock adjustments extending the test indefinitely.
        while SecureFiles.exists(stateURL), Clock.nowMS < record.deadlineUnixMS,
              ProcessInfo.processInfo.systemUptime - start < remaining {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard SecureFiles.exists(stateURL) else { return }
        // Bounded retry; do not silently discard a failed restoration, or spin forever.
        var last: Error = StretchError.displayNotFound
        for attempt in 0..<12 {
            do {
                _ = try restore(stateURL, platform: platform)
                return
            } catch { last = error }
            if !SecureFiles.exists(stateURL) { return }
            Thread.sleep(forTimeInterval: min(5, Double(attempt + 1)))
        }
        throw last
    }
}
