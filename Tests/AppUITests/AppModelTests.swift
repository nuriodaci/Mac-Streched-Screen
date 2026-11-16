import XCTest
import AppUI
import StretchCore

final class AppModelTests: XCTestCase {
    @MainActor func testPreviewStartupNeverConstructsHardwareSession() async {
        let model = AppModel.preview(displays: [], presets: [], backupDetail: "synthetic", status: "preview")
        model.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.statusText, "preview")
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.displays.isEmpty)
        model.stop()
    }
    @MainActor func testExperimentalAcknowledgementRequiredForApply() {
        let identity = MonitorIdentity(vendor: "ABC", product: 1, serial: 1, serialText: "SAMPLE")
        let display = DisplaySnapshot(id: 0, name: "Sample", vendor: "ABC", product: 1, blocks: 1,
                                      nativeSize: (1920, 1080), verticalRangeHz: 48...76,
                                      maxPixelClockMHz: 180, identity: identity, isOverrideActive: false)
        let model = AppModel.preview(displays: [display],
                                     presets: [ResolutionPreset(width: 1024, height: 768, refreshHz: 60)],
                                     backupDetail: "synthetic", status: "preview")
        // Opening preflight is harmless; only the actual apply requires acknowledgement.
        XCTAssertTrue(model.canTest)
        model.sheet = .confirm
        XCTAssertFalse(model.canConfirmTest)
        model.acknowledgesExperimentalRisk = true
        XCTAssertTrue(model.canConfirmTest)
        model.beginPreviewCountdown(seconds: 10, mode: "test")
        XCTAssertFalse(model.canConfirmTest)
        XCTAssertFalse(model.canTest)
    }
    @MainActor func testCustomInputsDoNotMisrepresentSelectedPreset() {
        let model = AppModel.preview(displays: [],
            presets: [ResolutionPreset(width: 1024, height: 768, refreshHz: 60)],
            backupDetail: "synthetic", status: "preview")
        XCTAssertFalse(model.usesCustomResolution)
        model.widthText = "1280"
        XCTAssertTrue(model.usesCustomResolution)
        model.widthText = " 1024 "
        XCTAssertFalse(model.usesCustomResolution)
        model.refreshText = "invalid"
        XCTAssertTrue(model.usesCustomResolution)
    }

    @MainActor func testNoDisplayCannotBeTestedEvenAfterAcknowledgement() {
        let model = AppModel.preview(displays: [], presets: [], backupDetail: "synthetic", status: "preview")
        model.acknowledgesExperimentalRisk = true
        XCTAssertFalse(model.canTest)
    }
}
