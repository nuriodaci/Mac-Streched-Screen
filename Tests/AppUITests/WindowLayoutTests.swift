import AppKit
import SwiftUI
import XCTest
import AppUI
import StretchCore

/// Hosts the real `ContentView` inside a real `NSWindow` so window sizing behaviour (the part that
/// drives the visible window) is measured, not just a view's fitting size.
@MainActor
final class WindowLayoutTests: XCTestCase {
    private func makeModel() -> AppModel {
        let identity = MonitorIdentity(vendor: "ABC", product: 1, serial: 1, serialText: "SAMPLE")
        let display = DisplaySnapshot(
            id: 0, name: "Sample Panel", vendor: "ABC", product: 1, blocks: 1,
            nativeSize: (1920, 1080), verticalRangeHz: 48...76, maxPixelClockMHz: 180,
            identity: identity, isOverrideActive: false
        )
        return AppModel.preview(
            displays: [display],
            presets: [ResolutionPreset(width: 1024, height: 768, refreshHz: 60)],
            backupDetail: "synthetic",
            status: "Ready"
        )
    }

    private func makeWindow(_ model: AppModel) -> NSWindow {
        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.layoutIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
    }

    func testWindowWidthIsFixedAndContentNeverClips() {
        let model = makeModel()
        let window = makeWindow(model)
        settle(window)

        let collapsed = window.contentView?.fittingSize ?? .zero
        XCTAssertEqual(collapsed.width, 480, accuracy: 1, "The window must stay 480 pt wide.")

        model.showsAdvanced = true
        settle(window)
        let expanded = window.contentView?.fittingSize ?? .zero
        XCTAssertEqual(expanded.width, 480, accuracy: 1, "Expanding must not widen the window.")
        XCTAssertGreaterThan(expanded.height, collapsed.height + 40,
                             "Expanding must reveal the custom fields, not clip them.")

        model.showsAdvanced = false
        settle(window)
        let recollapsed = window.contentView?.fittingSize ?? .zero
        XCTAssertEqual(recollapsed.width, 480, accuracy: 1)
        XCTAssertEqual(recollapsed.height, collapsed.height, accuracy: 2,
                       "Collapsing must return to the original height.")
    }

    /// An error message must wrap inside the window instead of widening it, and clearing the error
    /// must restore the compact height.
    func testLongErrorMessageWrapsWithoutResizingWidth() {
        let model = makeModel()
        let window = makeWindow(model)
        settle(window)
        let baseHeight = window.contentView?.fittingSize.height ?? 0

        model.setPreviewStatus(
            "The requested timing is outside this monitor's reported 48–76 Hz vertical range "
                + "and its maximum pixel clock, so it was refused.",
            isError: true
        )
        settle(window)
        let withError = window.contentView?.fittingSize ?? .zero
        XCTAssertEqual(withError.width, 480, accuracy: 1, "Error text must not widen the window.")
        XCTAssertGreaterThan(withError.height, baseHeight - 2)

        model.setPreviewStatus("Ready", isError: false)
        settle(window)
        XCTAssertEqual(window.contentView?.fittingSize.height ?? 0, baseHeight, accuracy: 2,
                       "Clearing the error must restore the compact layout.")
    }
}
