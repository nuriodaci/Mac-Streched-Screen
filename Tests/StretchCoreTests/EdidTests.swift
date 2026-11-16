import XCTest
@testable import StretchCore

final class EdidTests: XCTestCase {
    func testCVTReferenceVectors() throws {
        // Integer CVT vectors cross-checked against the reference implementation, not display tests.
        let cases: [(UInt16, UInt16, UInt16, Int64, UInt16, UInt16)] = [
            (1280, 960, 75, 130_000_000, 448, 45), (1024, 768, 60, 63_500_000, 304, 30),
            (1600, 1200, 60, 161_000_000, 560, 45), (1440, 1080, 60, 129_000_000, 480, 40),
            (1280, 960, 60, 101_250_000, 416, 36), (800, 600, 60, 38_250_000, 224, 24),
        ]
        for (w, h, r, clock, hb, vb) in cases {
            let t = try Edid.cvtTiming(width: w, height: h, refreshHz: r)
            XCTAssertEqual(t.pixelClockHz, clock); XCTAssertEqual(t.hBlank, hb); XCTAssertEqual(t.vBlank, vb)
            XCTAssertEqual(t.hActive, w); XCTAssertEqual(t.vActive, h)
        }
    }
    func testGenericMonitorsHaveIndependentLimitsAndIdentity() throws {
        for vendor in ["ABC", "DEL", "SAM", "GSM", "ACR"] {
            for serial in 1...5 {
                let source = Fixtures.factory(vendor: vendor, serial: UInt32(serial))
                let generated = try Edid.generate(original: source, width: 1280, height: 960, refreshHz: 75)
                XCTAssertEqual(try Edid.parse(generated.edid).identity, try Edid.parse(source).identity)
                XCTAssertEqual(generated.edid.count, 128)
                XCTAssertTrue(Edid.isOverride(generated.edid))
                XCTAssertEqual(generated.timing.actualRefreshHz, 74.8572, accuracy: 0.001)
                try Edid.validate(generated.edid)
            }
        }
        XCTAssertThrowsError(try Edid.generate(original: Fixtures.factory(vertical: (48, 60)), width: 1280, height: 960, refreshHz: 75))
        XCTAssertThrowsError(try Edid.generate(original: Fixtures.factory(clock: 8), width: 1280, height: 960, refreshHz: 75))
        XCTAssertThrowsError(try Edid.generate(original: Fixtures.factory(horizontal: (30, 60)), width: 1280, height: 960, refreshHz: 75))
    }
    func testMalformedInputNeverTraps() throws {
        for length in 0..<256 {
            XCTAssertThrowsError(try Edid.parse([UInt8](repeating: 0, count: length)))
        }
        for (index, value) in [(113, UInt8(90)), (115, 100), (8, 0), (18, 2), (19, 1)] {
            var bytes = Fixtures.factory(); bytes[index] = value; Fixtures.checksum(&bytes)
            XCTAssertThrowsError(try Edid.parse(bytes))
        }
        var corrupted = Fixtures.factory(); corrupted[20] ^= 1
        XCTAssertThrowsError(try Edid.parse(corrupted))
        var extra = Fixtures.factory(); extra += Fixtures.factory()
        XCTAssertThrowsError(try Edid.parse(extra))
    }
    func testFuzzValidChecksummedBaseBlocksDoNotCrash() {
        var state: UInt64 = 42
        for _ in 0..<2_000 {
            var bytes = Fixtures.factory()
            for i in 20..<127 {
                state = state &* 6364136223846793005 &+ 1
                bytes[i] = UInt8(truncatingIfNeeded: state >> 32)
            }
            bytes[126] = 0; Fixtures.checksum(&bytes)
            _ = try? Edid.parse(bytes)
            _ = Edid.presets(for: bytes)
        }
    }
    func testMissingLimitsFailClosed() throws {
        var bytes = Fixtures.factory(); bytes[111] = 0; Fixtures.checksum(&bytes)
        XCTAssertTrue(Edid.presets(for: bytes).isEmpty)
        XCTAssertThrowsError(try Edid.generate(original: bytes, width: 1024, height: 768, refreshHz: 60))
    }
    func testInvalidResolutionAndRefreshRejectedWithoutRounding() {
        for (w, h, r) in [(UInt16(1028), UInt16(771), UInt16(60)), (1280, 720, 60), (0, 0, 60), (1024, 768, 360), (4092, 3069, 75)] {
            XCTAssertThrowsError(try Edid.generate(original: Fixtures.factory(), width: w, height: h, refreshHz: r))
        }
        XCTAssertEqual(Edid.physicalSize(originalWidthCM: 0, originalHeightCM: 0, width: 0, height: 0).widthMM, 0)
    }
    func testUnknownPhysicalSizeNotInvented() throws {
        var bytes = Fixtures.factory(); bytes[21] = 0; bytes[22] = 0; Fixtures.checksum(&bytes)
        let generated = try Edid.generate(original: bytes, width: 1024, height: 768, refreshHz: 60).edid
        XCTAssertEqual(Array(generated[21...22]), [0, 0])
        XCTAssertEqual(Array(generated[66...68]), [0, 0, 0])
    }
    func testPresetsAreValidatedCandidatesNotRecommendations() throws {
        let source = Fixtures.factory()
        let presets = Edid.presets(for: source)
        XCTAssertEqual(presets.first?.id, "1024x768@60")
        for p in presets {
            XCTAssertFalse(p.isRecommended)
            XCTAssertNoThrow(try Edid.generate(original: source, width: p.width, height: p.height, refreshHz: p.refreshHz))
        }
    }
}
