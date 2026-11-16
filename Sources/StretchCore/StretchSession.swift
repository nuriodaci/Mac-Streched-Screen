import Foundation

/// Read-only projection of a connected display for the interface. Keeps EDID bytes out of the view
/// layer so the interface cannot mutate them.
public struct DisplaySnapshot: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var vendor: String
    public var product: UInt16
    public var blocks: Int
    public var nativeSize: (width: UInt16, height: UInt16)?
    public var verticalRangeHz: ClosedRange<UInt8>?
    public var maxPixelClockMHz: UInt32?
    public var identity: MonitorIdentity
    public var isOverrideActive: Bool

    public init(
        id: Int,
        name: String,
        vendor: String,
        product: UInt16,
        blocks: Int,
        nativeSize: (width: UInt16, height: UInt16)?,
        verticalRangeHz: ClosedRange<UInt8>?,
        maxPixelClockMHz: UInt32?,
        identity: MonitorIdentity,
        isOverrideActive: Bool
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.product = product
        self.blocks = blocks
        self.nativeSize = nativeSize
        self.verticalRangeHz = verticalRangeHz
        self.maxPixelClockMHz = maxPixelClockMHz
        self.identity = identity
        self.isOverrideActive = isOverrideActive
    }

    public static func == (lhs: DisplaySnapshot, rhs: DisplaySnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.vendor == rhs.vendor
            && lhs.product == rhs.product
            && lhs.blocks == rhs.blocks
            && lhs.nativeSize?.width == rhs.nativeSize?.width
            && lhs.nativeSize?.height == rhs.nativeSize?.height
            && lhs.verticalRangeHz == rhs.verticalRangeHz
            && lhs.maxPixelClockMHz == rhs.maxPixelClockMHz
            && lhs.identity == rhs.identity
            && lhs.isOverrideActive == rhs.isOverrideActive
    }

    public var nativeLabel: String {
        guard let nativeSize else { return "Not reported" }
        return "\(nativeSize.width) × \(nativeSize.height)"
    }

    public var detailLabel: String {
        String(format: "%@ · Product %04X · %d EDID block%@",
               vendor, product, blocks, blocks == 1 ? "" : "s")
    }

    public var rangeLabel: String {
        var parts: [String] = []
        if let verticalRangeHz {
            parts.append("\(verticalRangeHz.lowerBound)–\(verticalRangeHz.upperBound) Hz")
        } else {
            parts.append("Refresh range not reported")
        }
        if let maxPixelClockMHz {
            parts.append("max \(maxPixelClockMHz) MHz")
        }
        return parts.joined(separator: " · ")
    }
}

public struct PreparedChange: Equatable, Sendable {
    public var identity: MonitorIdentity
    public var edid: [UInt8]
    public var width: UInt16
    public var height: UInt16
    public var requestedRefreshHz: UInt16
    public var timing: Timing

    public var modeLabel: String {
        String(format: "%d × %d @ %.2f Hz", width, height, timing.actualRefreshHz)
    }
}

public struct ActiveChange: Equatable, Sendable {
    public var identity: MonitorIdentity
    public var displayName: String
    public var stateURL: URL
    public var deadline: Date
    public var monotonicDeadline: TimeInterval
    public var modeLabel: String

    public init(
        identity: MonitorIdentity,
        displayName: String,
        stateURL: URL,
        deadline: Date,
        modeLabel: String
    ) {
        self.identity = identity
        self.displayName = displayName
        self.stateURL = stateURL
        self.deadline = deadline
        self.monotonicDeadline = ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow)
        self.modeLabel = modeLabel
    }

    public func remainingSeconds(now: Date = Date()) -> Int {
        max(0, Int(min(deadline.timeIntervalSince(now), monotonicDeadline - ProcessInfo.processInfo.systemUptime).rounded(.up)))
    }
}

/// Serially owned by the UI worker actor. Discovery is read-only; mutations are explicit actions.
public final class StretchSession {
    public let store: BackupStore
    private let platform: DisplayPlatform
    private let guardProcess: RestoreGuard
    private let runLock: FileLock
    public private(set) var displays: [Display] = []
    public private(set) var selectedIndex = 0
    public private(set) var presets: [ResolutionPreset] = []
    public private(set) var selectedPresetIndex = 0
    public private(set) var active: ActiveChange?
    public private(set) var prepared: PreparedChange?
    public private(set) var backupDetail = "Waiting for a monitor"
    private var cachedEDID: [UInt8] = []
    private var expectedOverride: [UInt8]?
    private var applicationSucceeded = false

    public init(platform: DisplayPlatform, store: BackupStore, restoreGuard: RestoreGuard) throws {
        self.platform = platform
        self.store = store
        self.guardProcess = restoreGuard
        self.runLock = try FileLock(store.lockURL, nonblocking: true)
    }

    public convenience init() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StretchRestoreHelper")
        try self.init(platform: MacDisplayPlatform(), store: BackupStore.applicationDefault(),
                      restoreGuard: ProcessRestoreGuard(executable: executable))
    }

    public var selectedDisplay: Display? {
        displays.indices.contains(selectedIndex) ? displays[selectedIndex] : nil
    }
    public var selectedPreset: ResolutionPreset? {
        presets.indices.contains(selectedPresetIndex) ? presets[selectedPresetIndex] : nil
    }
    public var snapshots: [DisplaySnapshot] {
        displays.map { display in
            // Keep the factory display name/ranges when the temporary marker is active.
            let info = (try? Edid.parse(factoryEdid(for: display))) ?? display.info
            return DisplaySnapshot(id: display.serviceIndex, name: info.name, vendor: info.identity.vendor,
                                   product: info.identity.product, blocks: info.blocks, nativeSize: info.nativeSize,
                                   verticalRangeHz: info.verticalRangeHz, maxPixelClockMHz: info.maxPixelClockMHz,
                                   identity: info.identity, isOverrideActive: Edid.isOverride(display.edid))
        }
    }

    public func factoryEdid(for display: Display) throws -> [UInt8] {
        if Edid.isOverride(display.edid) { return try store.loadFactoryBackup(display.info.identity) }
        return display.edid
    }

    @discardableResult
    public func refresh() throws -> Bool {
        guard active == nil else { return false }
        let previous = selectedDisplay?.info.identity
        let previousPreset = selectedPreset?.id
        displays = try platform.displays()
        selectedIndex = previous.flatMap { identity in displays.firstIndex { $0.info.identity == identity } } ?? 0
        let changed = previous != selectedDisplay?.info.identity
        guard let display = selectedDisplay else {
            presets = []; cachedEDID = []; backupDetail = "Waiting for a monitor"
            return changed
        }
        let source = try factoryEdid(for: display)
        // Cache pure timing generation; polling does not rewrite/rehash every backup every time.
        if source != cachedEDID || changed {
            presets = Edid.presets(for: source)
            cachedEDID = source
            selectedPresetIndex = presets.firstIndex { $0.id == previousPreset } ?? 0
        }
        backupDetail = Edid.isOverride(display.edid)
            ? "Factory EDID backup verified (override active)"
            : "Factory backup will be saved and verified before testing"
        return changed
    }

    public func selectDisplay(index: Int) throws {
        guard active == nil, displays.indices.contains(index) else { return }
        prepared = nil
        selectedIndex = index
        cachedEDID = []
        let source = try factoryEdid(for: displays[index])
        presets = Edid.presets(for: source)
        cachedEDID = source
        selectedPresetIndex = 0
    }
    public func selectPreset(index: Int) {
        guard active == nil, presets.indices.contains(index) else { return }
        prepared = nil
        selectedPresetIndex = index
    }

    public func prepare(widthText: String, heightText: String, refreshText: String) throws -> PreparedChange {
        prepared = nil // A failed prepare must not leave an older, applicable change behind.
        guard active == nil else { throw StretchError.invalidInput("A test is already in progress.") }
        guard let width = UInt16(widthText.trimmingCharacters(in: .whitespaces)),
              let height = UInt16(heightText.trimmingCharacters(in: .whitespaces)),
              let refresh = UInt16(refreshText.trimmingCharacters(in: .whitespaces)) else {
            throw StretchError.invalidInput("Enter whole-number width, height and refresh rate.")
        }
        let change = try previewTiming(width: width, height: height, refreshHz: refresh)
        prepared = change
        return change
    }

    public func previewTiming(width: UInt16, height: UInt16, refreshHz: UInt16) throws -> PreparedChange {
        guard let display = selectedDisplay else { throw StretchError.displayNotFound }
        let source = try factoryEdid(for: display)
        let generated = try Edid.generate(original: source, width: width, height: height, refreshHz: refreshHz)
        return PreparedChange(identity: display.info.identity, edid: generated.edid, width: width,
                              height: height, requestedRefreshHz: refreshHz, timing: generated.timing)
    }

    @discardableResult
    public func apply(_ change: PreparedChange, confirmSeconds: Int) throws -> ActiveChange {
        guard active == nil, prepared == change, (10...30).contains(confirmSeconds) else {
            throw StretchError.invalidInput("No valid prepared change, or another test is pending.")
        }
        // Global operation lock also serializes GUI apply with terminal recovery.
        let operation = try FileLock(store.root.appendingPathComponent("operation.lock"))
        defer { withExtendedLifetime(operation) {} }
        guard try Watchdog.records(store: store).isEmpty else {
            throw StretchError.invalidInput("An interrupted test needs recovery. Restore before testing again.")
        }
        let live = try platform.displays().filter { $0.info.identity == change.identity }
        guard live.count == 1 else {
            throw live.isEmpty ? StretchError.displayNotFound : StretchError.ambiguousIdentity
        }
        guard !Edid.isOverride(live[0].edid) else {
            throw StretchError.invalidInput("Restore the existing override before starting a new test.")
        }
        let regenerated = try Edid.generate(original: live[0].edid, width: change.width,
                                            height: change.height, refreshHz: change.requestedRefreshHz)
        guard regenerated.edid == change.edid else {
            throw StretchError.invalidInput("Display capabilities changed. Refresh and prepare the test again.")
        }
        try store.ensureFactoryBackup(live[0].edid)
        _ = try store.loadFactoryBackup(change.identity)
        let state = try guardProcess.arm(store: store, identity: change.identity, mode: change.modeLabel,
                                         timeout: TimeInterval(confirmSeconds))
        let pending = ActiveChange(identity: change.identity, displayName: live[0].info.name, stateURL: state,
                                   deadline: Date().addingTimeInterval(TimeInterval(confirmSeconds)),
                                   modeLabel: change.modeLabel)
        // Set this BEFORE entering the possibly blocking/private API. A returned error can still
        // mean the hardware changed partially: never cancel the guard on apply failure.
        active = pending
        applicationSucceeded = false
        expectedOverride = change.edid
        prepared = nil
        do {
            try platform.applyOverride(change.edid, to: change.identity)
        } catch {
            // A late error may occur after the independent helper has already finished. Do not
            // mistake a missing record for proof that a partially applied override is gone.
            if !SecureFiles.exists(state) {
                try platform.resetOverride(for: change.identity)
                self.active = nil
            }
            throw error
        }
        guard SecureFiles.exists(state), pending.remainingSeconds() > 0 else {
            // The private call can return AFTER the helper's deadline. It might have applied an
            // override after the helper reset it, so explicitly reset this late completion too.
            try platform.resetOverride(for: change.identity)
            try guardProcess.cancel(state)
            self.active = nil
            throw StretchError.watchdogFailed("The display test timed out while applying and was reverted.")
        }
        applicationSucceeded = true
        return pending
    }

    public func keep() throws {
        guard applicationSucceeded, let active, active.remainingSeconds() > 0, SecureFiles.exists(active.stateURL) else {
            throw StretchError.invalidInput("Confirmation expired. Restore before trying again.")
        }
        let lock = try FileLock(Watchdog.lockURL(active.stateURL))
        defer { withExtendedLifetime(lock) {} }
        guard active.remainingSeconds() > 0, SecureFiles.exists(active.stateURL),
              try Watchdog.record(at: active.stateURL).deadlineUnixMS > Clock.nowMS else {
            throw StretchError.invalidInput("The restore helper already completed or expired this test.")
        }
        let live = try platform.displays().filter { $0.info.identity == active.identity }
        guard live.count == 1, let expectedOverride, live[0].edid == expectedOverride else {
            throw StretchError.invalidInput("The requested display timing is no longer active.")
        }
        guard active.remainingSeconds() > 0 else {
            throw StretchError.invalidInput("Confirmation expired while checking the display.")
        }
        // Already holding the helper lock: unlink directly to avoid recursively locking it.
        guard unlink(active.stateURL.path) == 0 else { throw SecureFiles.posixError() }
        self.active = nil
    }

    public func revert() throws {
        guard let active else { return }
        // If the helper already restored, this is a no-op; no duplicate display reset.
        _ = try Watchdog.restore(active.stateURL, platform: platform)
        self.active = nil
    }

    public func restoreSelected() throws {
        guard let display = selectedDisplay else { throw StretchError.displayNotFound }
        let operation = try FileLock(store.root.appendingPathComponent("operation.lock"))
        defer { withExtendedLifetime(operation) {} }
        let pending: [(url: URL, change: PendingChange)]
        do {
            pending = try Watchdog.records(store: store).filter { $0.change.identity == display.info.identity }
        } catch {
            try platform.resetOverride(for: display.info.identity)
            throw StretchError.watchdogFailed("Override removal requested, but a corrupt recovery record still requires diagnosis.")
        }
        if pending.isEmpty {
            try platform.resetOverride(for: display.info.identity)
        } else {
            for record in pending { _ = try Watchdog.restore(record.url, platform: platform) }
        }
        active = nil
    }
    public func cancelPrepared() { prepared = nil }

    /// Reuses the EXACT stored path, never fabricates a filename or resets a monitor at startup.
    public func recoverInterruptedChange() throws {
        guard active == nil else { return }
        guard let record = try Watchdog.records(store: store).first else { return }
        active = ActiveChange(identity: record.change.identity,
                              displayName: "Interrupted test", stateURL: record.url,
                              deadline: Date(timeIntervalSince1970: Double(record.change.deadlineUnixMS) / 1000),
                              modeLabel: record.change.requestedMode)
    }
}
