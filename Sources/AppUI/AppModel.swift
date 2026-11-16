import SwiftUI
import StretchCore

/// All IOKit/filesystem work is confined to this actor, never the main UI thread.
private actor SessionWorker {
    private var session: StretchSession?
    struct Snapshot: Sendable {
        var displays: [DisplaySnapshot]
        var presets: [ResolutionPreset]
        var displayID: Int
        var presetID: String
        var backup: String
        var active: ActiveChange?
    }
    func start() throws -> Snapshot {
        if session == nil { session = try StretchSession() }
        try session?.recoverInterruptedChange()
        // Do not refresh a live transaction; the independent helper owns recovery.
        if session?.active == nil { try session?.refresh() }
        return snapshot()
    }
    func refresh() throws -> Snapshot { try session?.refresh(); return snapshot() }
    func selectDisplay(_ id: Int) throws -> Snapshot {
        if let index = session?.displays.firstIndex(where: { $0.serviceIndex == id }) {
            try session?.selectDisplay(index: index)
        }
        return snapshot()
    }
    func selectPreset(_ id: String) -> Snapshot {
        if let index = session?.presets.firstIndex(where: { $0.id == id }) { session?.selectPreset(index: index) }
        return snapshot()
    }
    func prepare(_ width: String, _ height: String, _ refresh: String) throws -> String {
        guard let session else { throw StretchError.displayNotFound }
        return try session.prepare(widthText: width, heightText: height, refreshText: refresh).modeLabel
    }
    func apply() throws -> Snapshot {
        guard let session, let change = session.prepared else {
            throw StretchError.invalidInput("Prepare a resolution first.")
        }
        try session.apply(change, confirmSeconds: 20)
        return snapshot()
    }
    func keep() throws -> Snapshot { try session?.keep(); try session?.refresh(); return snapshot() }
    func revert() throws -> Snapshot { try session?.revert(); try session?.refresh(); return snapshot() }
    func restore() throws -> Snapshot { try session?.restoreSelected(); return snapshot() }
    func cancel() { session?.cancelPrepared() }
    func snapshot() -> Snapshot {
        Snapshot(displays: session?.snapshots ?? [], presets: session?.presets ?? [],
                 displayID: session?.selectedDisplay?.serviceIndex ?? 0,
                 presetID: session?.selectedPreset?.id ?? "", backup: session?.backupDetail ?? "",
                 active: session?.active)
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public enum Sheet: Int, Identifiable { case confirm, confirmLive; public var id: Int { rawValue } }
    @Published public private(set) var displays: [DisplaySnapshot] = []
    @Published public private(set) var presets: [ResolutionPreset] = []
    @Published public private(set) var selectedDisplayID = 0
    @Published public private(set) var selectedPresetID = ""
    @Published public private(set) var backupDetail = "Waiting for a monitor"
    @Published public private(set) var statusText = "Connecting…"
    @Published public private(set) var statusIsError = false
    @Published public private(set) var pendingChange: ActiveChange?
    @Published public private(set) var remainingSeconds = 0
    @Published public private(set) var canKeepResolution = false
    @Published public private(set) var requestedMode = ""
    @Published public private(set) var isReady = false
    @Published public private(set) var isBusy = false
    @Published public var widthText = "1024"
    @Published public var heightText = "768"
    @Published public var refreshText = "60"
    @Published public var showsAdvanced = false
    @Published public private(set) var timingSummary = ""
    @Published public var sheet: Sheet?
    /// Private API behaviour is not a compatibility guarantee. Explicit acknowledgement is required.
    @Published public var acknowledgesExperimentalRisk = false
    private let worker = SessionWorker()
    private var timer: Timer?
    private var started = false
    private var lastDisplayID: Int?
    private var attemptedAutomaticRevert = false
    private var recoveredTransaction = false
    public init() {}
    public var selectedDisplay: DisplaySnapshot? { displays.first { $0.id == selectedDisplayID } }
    public var hasDisplay: Bool { !displays.isEmpty }
    public var usesCustomResolution: Bool {
        guard let preset = presets.first(where: { $0.id == selectedPresetID }) else { return true }
        return UInt16(widthText.trimmingCharacters(in: .whitespaces)) != preset.width
            || UInt16(heightText.trimmingCharacters(in: .whitespaces)) != preset.height
            || UInt16(refreshText.trimmingCharacters(in: .whitespaces)) != preset.refreshHz
    }
    public var canTest: Bool {
        isReady && !isBusy && pendingChange == nil && hasDisplay
            && !presets.isEmpty && selectedDisplay?.isOverrideActive == false
    }
    public var canConfirmTest: Bool {
        sheet == .confirm && acknowledgesExperimentalRisk && !isBusy
    }
    public var statusSymbol: String {
        statusIsError ? "exclamationmark.triangle.fill" : (pendingChange == nil ? "info.circle" : "clock")
    }

    public func start() {
        guard !started else { return }
        started = true
        perform {
            let snapshot = try await self.worker.start()
            self.sync(snapshot, inputs: true)
            self.isReady = true
            self.statusIsError = false
            self.statusText = snapshot.active != nil ? "Interrupted test requires restoration" : (snapshot.displays.isEmpty ? "No compatible external display detected" : "Ready to test a 4:3 resolution")
            if snapshot.active != nil {
                self.recoveredTransaction = true
                self.canKeepResolution = false
                self.attemptedAutomaticRevert = true // Recovery requires an explicit Restore action.
                self.sheet = .confirmLive
            }
        }
    }
    public func stop() { timer?.invalidate(); timer = nil }
    public func handleTermination() {
        stop()
        // Never block app termination on a private display API. The independent helper remains armed.
        if pendingChange != nil, !recoveredTransaction { Task { _ = try? await worker.revert() } }
    }
    private func sync(_ snapshot: SessionWorker.Snapshot, inputs: Bool = false) {
        displays = snapshot.displays; presets = snapshot.presets
        selectedDisplayID = snapshot.displayID; selectedPresetID = snapshot.presetID
        if pendingChange?.stateURL != snapshot.active?.stateURL { attemptedAutomaticRevert = false }
        backupDetail = snapshot.backup; pendingChange = snapshot.active
        canKeepResolution = snapshot.active != nil && !recoveredTransaction
        if snapshot.active != nil, timer == nil {
            let countdown = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            countdown.tolerance = 0.05
            RunLoop.main.add(countdown, forMode: .common)
            timer = countdown
        } else if snapshot.active == nil {
            stop()
            remainingSeconds = 0
        }
        if let active = snapshot.active {
            requestedMode = active.modeLabel; remainingSeconds = active.remainingSeconds()
        }
        if inputs || lastDisplayID != snapshot.displayID {
            if let preset = presets.first(where: { $0.id == selectedPresetID }) {
                widthText = String(preset.width); heightText = String(preset.height)
                refreshText = String(preset.refreshHz)
            }
        }
        lastDisplayID = snapshot.displayID
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await action() } catch {
                sync(await worker.snapshot()) // Preserve recovery state even after a partial apply failure.
                statusText = error.displayMessage; statusIsError = true
                if pendingChange != nil { canKeepResolution = false; sheet = .confirmLive }
            }
        }
    }
    public func refreshDisplays() {
        guard !isBusy, pendingChange == nil else { return }
        if !isReady { started = false; start(); return }
        perform { self.sync(try await self.worker.refresh(), inputs: true); self.statusText = "Displays refreshed"; self.statusIsError = false }
    }
    public func selectDisplay(_ id: Int) {
        perform { self.sync(try await self.worker.selectDisplay(id), inputs: true) }
    }
    public func selectPreset(_ id: String) {
        perform { self.sync(await self.worker.selectPreset(id), inputs: true) }
    }
    public func testResolution() {
        guard canTest else { return }
        acknowledgesExperimentalRisk = false
        perform {
            self.requestedMode = try await self.worker.prepare(self.widthText, self.heightText, self.refreshText)
            self.statusIsError = false
            self.sheet = .confirm
        }
    }
    public func confirmTest() {
        guard canConfirmTest else { return }
        perform {
            self.recoveredTransaction = false
            self.sync(try await self.worker.apply())
            self.sheet = .confirmLive; self.statusText = "Confirm only if the new picture is visible"
        }
    }
    public func cancelTest() { sheet = nil; Task { await worker.cancel() } }
    public func keepResolution() {
        guard canKeepResolution, remainingSeconds > 0 else { return }
        perform {
            self.sync(try await self.worker.keep()); self.sheet = nil
            self.statusText = "Resolution kept for this connection session"; self.statusIsError = false
        }
    }
    public func revertResolution() {
        perform {
            self.sync(try await self.worker.revert()); self.sheet = nil
            self.statusText = "Temporary EDID override removed"; self.statusIsError = false
        }
    }
    public func restoreFactory() {
        perform {
            self.sync(try await self.worker.restore()); self.sync(try await self.worker.refresh())
            self.sheet = nil; self.statusText = "Temporary EDID override removed"; self.statusIsError = false
        }
    }
    private func tick() {
        guard let active = pendingChange else { return }
        let seconds = active.remainingSeconds()
        if remainingSeconds != seconds { remainingSeconds = seconds }
        if remainingSeconds == 0, !isBusy, !attemptedAutomaticRevert {
            attemptedAutomaticRevert = true
            revertResolution()
        }
    }
}

extension AppModel {
    /// Builds a model with injected data so interface states can be reviewed offscreen.
    public static func preview(
        displays: [DisplaySnapshot],
        presets: [ResolutionPreset],
        backupDetail: String,
        status: String
    ) -> AppModel {
        let model = AppModel()
        model.displays = displays
        model.presets = presets
        model.selectedDisplayID = displays.first?.id ?? 0
        model.selectedPresetID = presets.first?.id ?? ""
        model.backupDetail = backupDetail
        model.statusText = status
        model.isReady = true
        model.started = true // Preview onAppear must never construct a hardware session.
        if let preset = presets.first {
            model.widthText = String(preset.width)
            model.heightText = String(preset.height)
            model.refreshText = String(preset.refreshHz)
        }
        return model
    }

    public func setRequestedMode(_ text: String) {
        requestedMode = text
    }

    public func setTimingSummary(_ text: String) {
        timingSummary = text
    }

    public func setPreviewStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
    }

    public func beginPreviewCountdown(seconds: Int, mode: String) {
        requestedMode = mode
        remainingSeconds = seconds
        pendingChange = ActiveChange(
            identity: displays.first?.identity
                ?? MonitorIdentity(vendor: "ABC", product: 1, serial: 1, serialText: "SAMPLE"),
            displayName: displays.first?.name ?? "External display",
            stateURL: URL(fileURLWithPath: "/tmp/preview-state.json"),
            deadline: Date().addingTimeInterval(TimeInterval(seconds)),
            modeLabel: mode
        )
        canKeepResolution = true
        sheet = .confirmLive
    }
}
