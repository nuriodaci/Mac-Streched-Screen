import AppKit
import AppUI
import StretchCore
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func run() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "/tmp/mss-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let factory = SampleData.edid
        let presets = Edid.presets(for: factory)
        let parsed = try Edid.parse(factory)
        let snapshot = DisplaySnapshot(
            id: 0,
            name: parsed.name,
            vendor: parsed.identity.vendor,
            product: parsed.identity.product,
            blocks: parsed.blocks,
            nativeSize: parsed.nativeSize,
            verticalRangeHz: parsed.verticalRangeHz,
            maxPixelClockMHz: parsed.maxPixelClockMHz,
            identity: parsed.identity,
            isOverrideActive: false
        )

        let ready = AppModel.preview(
            displays: [snapshot],
            presets: presets,
            backupDetail: "Saved and verified",
            status: "Display ready"
        )
        ready.setTimingSummary("EDID-compatible candidate — not hardware validated")
        try render(ContentView(model: ready),
                   to: output.appendingPathComponent("01-ready.png"), appearance: .aqua)

        ready.showsAdvanced = true
        try render(ContentView(model: ready),
                   to: output.appendingPathComponent("02-advanced.png"), appearance: .aqua)

        let empty = AppModel.preview(displays: [], presets: [], backupDetail: "Waiting for a monitor",
                                     status: "No external display")
        try render(ContentView(model: empty),
                   to: output.appendingPathComponent("03-empty.png"), appearance: .aqua)

        let failure = AppModel.preview(displays: [snapshot], presets: presets,
                                       backupDetail: "Saved and verified", status: "Display ready")
        failure.setPreviewStatus(
            "The requested timing is outside this monitor's 48–76 Hz range.", isError: true)
        try render(ContentView(model: failure),
                   to: output.appendingPathComponent("04-error.png"), appearance: .aqua)

        let confirm = AppModel.preview(displays: [snapshot], presets: presets,
                                       backupDetail: "Saved and verified", status: "Display ready")
        confirm.setRequestedMode("1280 × 960 @ 74.86 Hz")
        confirm.sheet = .confirm
        try renderSheet(ConfirmSheet(model: confirm), to: output.appendingPathComponent("05-confirm.png"),
                        appearance: .aqua)

        let live = AppModel.preview(displays: [snapshot], presets: presets,
                                    backupDetail: "Saved and verified", status: "Awaiting confirmation")
        live.beginPreviewCountdown(seconds: 17, mode: "1280 × 960 @ 74.86 Hz")
        try renderSheet(LiveConfirmSheet(model: live), to: output.appendingPathComponent("06-live.png"),
                        appearance: .aqua)

        let readyDark = AppModel.preview(displays: [snapshot], presets: presets,
                                         backupDetail: "Saved and verified", status: "Display ready")
        try render(ContentView(model: readyDark),
                   to: output.appendingPathComponent("07-ready-dark.png"), appearance: .darkAqua)

        let advancedDark = AppModel.preview(displays: [snapshot], presets: presets,
                                            backupDetail: "Saved and verified", status: "Display ready")
        advancedDark.showsAdvanced = true
        advancedDark.setTimingSummary("EDID-compatible candidate — not hardware validated")
        try render(ContentView(model: advancedDark),
                   to: output.appendingPathComponent("08-advanced-dark.png"), appearance: .darkAqua)

        let liveDark = AppModel.preview(displays: [snapshot], presets: presets,
                                        backupDetail: "Saved and verified", status: "Awaiting confirmation")
        liveDark.beginPreviewCountdown(seconds: 8, mode: "1024 × 768 @ 59.92 Hz")
        try renderSheet(LiveConfirmSheet(model: liveDark), to: output.appendingPathComponent("09-live-dark.png"),
                        appearance: .darkAqua)

        let emptyDark = AppModel.preview(displays: [], presets: [], backupDetail: "Waiting for a monitor",
                                         status: "No external display")
        try render(ContentView(model: emptyDark),
                   to: output.appendingPathComponent("10-empty-dark.png"), appearance: .darkAqua)

        var overridden = snapshot
        overridden.isOverrideActive = true
        let active = AppModel.preview(displays: [overridden], presets: presets,
                                      backupDetail: "Verified", status: "Resolution kept for this connection session")
        try render(ContentView(model: active), to: output.appendingPathComponent("11-override.png"), appearance: .aqua)

        var longName = snapshot
        longName.name = "An unusually long external monitor name connected through a display adapter"
        let long = AppModel.preview(displays: [longName], presets: presets,
                                   backupDetail: "Verified", status: "Display ready")
        long.showsAdvanced = true
        long.widthText = "1280"
        long.heightText = "960"
        try render(ContentView(model: long), to: output.appendingPathComponent("12-custom-long-name.png"), appearance: .aqua)

        print("preview frames written to \(output.path)")
    }

    private static func render<V: View>(
        _ view: V,
        to url: URL,
        appearance: NSAppearance.Name
    ) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        settle()
        hosting.layoutSubtreeIfNeeded()
        try capture(hosting, to: url)
    }

    private static func renderSheet<V: View>(
        _ view: V,
        to url: URL,
        appearance: NSAppearance.Name
    ) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        // Sheets declare an explicit width; resolve height from the laid-out content.
        hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()
        settle()
        let fitting = hosting.fittingSize
        hosting.frame = CGRect(x: 0, y: 0, width: max(fitting.width, 400),
                               height: max(fitting.height, 1))
        hosting.layoutSubtreeIfNeeded()
        settle()
        try capture(hosting, to: url)
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    private static func capture(_ view: NSView, to url: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.renderFailed("no bitmap representation")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.renderFailed("no PNG data")
        }
        try png.write(to: url)
    }

    struct SampleData {
        // Synthetic EDID. UI previews never read a real monitor or contain a user's serial number.
        static var edid: [UInt8] {
            var e = [UInt8](repeating: 0, count: 128)
            e.replaceSubrange(0..<8, with: Edid.header)
            e[8] = 4; e[9] = 67; e[10] = 1; e[12] = 1
            e[18] = 1; e[19] = 4; e[20] = 128; e[21] = 53; e[22] = 30
            e[54] = 2; e[55] = 58; e[56] = 128; e[58] = 112
            e[59] = 56; e[61] = 64
            let name = Array("Sample Panel".utf8)
            e[75] = 252
            for (i, byte) in name.enumerated() { e[77 + i] = byte }
            e[111] = 253; e[113] = 48; e[114] = 76
            e[115] = 30; e[116] = 85; e[117] = 18
            e[127] = 0 &- e[..<127].reduce(UInt8(0), &+)
            return e
        }
    }

    enum PreviewError: Error {
        case renderFailed(String)
    }
}
