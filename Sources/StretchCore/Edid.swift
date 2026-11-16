import Foundation
import CryptoKit

// MARK: - Errors

public enum EdidError: Error, Equatable, CustomStringConvertible {
    case length
    case header
    case missingBlocks
    case checksum(Int)
    case resolution
    case refresh
    case pixelClock
    case outsideRange(String)

    public var description: String {
        switch self {
        case .length: return "EDID length must be a non-zero multiple of 128 bytes"
        case .header: return "invalid EDID header"
        case .missingBlocks: return "EDID declares more blocks than supplied"
        case .checksum(let block): return "checksum failure in EDID block \(block)"
        case .resolution: return "resolution must be progressive, 320..4095 wide and 200..4095 high"
        case .refresh: return "refresh rate must be between 24 and 360 Hz"
        case .pixelClock: return "generated pixel clock exceeds the EDID detailed-timing limit"
        case .outsideRange(let detail): return "requested timing exceeds the monitor range descriptor: \(detail)"
        }
    }

    public var localizedMessage: String { description }
}

// MARK: - Identity

public struct MonitorIdentity: Codable, Equatable, Hashable, Sendable {
    public var vendor: String
    public var product: UInt16
    public var serial: UInt32
    public var serialText: String

    public init(vendor: String, product: UInt16, serial: UInt32, serialText: String) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.serialText = serialText
    }

    public var isValid: Bool {
        vendor.utf8.count == 3 && vendor.utf8.allSatisfy { (65...90).contains($0) }
            && serialText.utf8.count <= 13
            && serialText.utf8.allSatisfy { (32...126).contains($0) }
    }

    /// Stable, filename-safe identity used for backup directories and watchdog records.
    public var stableKey: String {
        let filtered = serialText
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            .prefix(32)
        let text = filtered.isEmpty ? "none" : String(filtered)
        let safeVendor = isValid ? vendor : "INVALID"
        return String(format: "%@-%04X-%08X-%@", safeVendor, product, serial, text)
    }
}

// MARK: - Information

public struct EdidInfo: Equatable, Sendable {
    public var identity: MonitorIdentity
    public var name: String
    public var blocks: Int
    public var maxPixelClockMHz: UInt32?
    public var verticalRangeHz: ClosedRange<UInt8>?
    public var horizontalRangeKHz: ClosedRange<UInt8>?
    public var nativeSize: (width: UInt16, height: UInt16)?

    public static func == (lhs: EdidInfo, rhs: EdidInfo) -> Bool {
        lhs.identity == rhs.identity
            && lhs.name == rhs.name
            && lhs.blocks == rhs.blocks
            && lhs.maxPixelClockMHz == rhs.maxPixelClockMHz
            && lhs.verticalRangeHz == rhs.verticalRangeHz
            && lhs.horizontalRangeKHz == rhs.horizontalRangeKHz
            && lhs.nativeSize?.width == rhs.nativeSize?.width
            && lhs.nativeSize?.height == rhs.nativeSize?.height
    }
}

// MARK: - Timing

public struct Timing: Equatable, Sendable {
    public var pixelClockHz: Int64
    public var hActive: UInt16
    public var hBlank: UInt16
    public var hSyncOffset: UInt16
    public var hSyncWidth: UInt16
    public var vActive: UInt16
    public var vBlank: UInt16
    public var vSyncOffset: UInt16
    public var vSyncWidth: UInt16
    public var positiveHSync: Bool
    public var positiveVSync: Bool

    public init(
        pixelClockHz: Int64,
        hActive: UInt16,
        hBlank: UInt16,
        hSyncOffset: UInt16,
        hSyncWidth: UInt16,
        vActive: UInt16,
        vBlank: UInt16,
        vSyncOffset: UInt16,
        vSyncWidth: UInt16,
        positiveHSync: Bool,
        positiveVSync: Bool
    ) {
        self.pixelClockHz = pixelClockHz
        self.hActive = hActive
        self.hBlank = hBlank
        self.hSyncOffset = hSyncOffset
        self.hSyncWidth = hSyncWidth
        self.vActive = vActive
        self.vBlank = vBlank
        self.vSyncOffset = vSyncOffset
        self.vSyncWidth = vSyncWidth
        self.positiveHSync = positiveHSync
        self.positiveVSync = positiveVSync
    }

    public var actualRefreshHz: Double {
        let hTotal = Double(hActive) + Double(hBlank)
        let vTotal = Double(vActive) + Double(vBlank)
        return Double(pixelClockHz) / (hTotal * vTotal)
    }

    public var horizontalFrequencyKHz: Double {
        Double(pixelClockHz) / (Double(hActive) + Double(hBlank)) / 1000.0
    }
}

// MARK: - EDID

public enum Edid {
    public static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    public static let overrideName = "STRETCHED"

    public static func validate(_ data: [UInt8]) throws {
        guard !data.isEmpty, data.count <= 32_768, data.count % 128 == 0 else { throw EdidError.length }
        guard Array(data.prefix(8)) == header else { throw EdidError.header }
        let blocks = 1 + Int(data[126])
        guard blocks == data.count / 128 else { throw EdidError.missingBlocks }
        guard data[18] == 1, (3...4).contains(data[19]) else {
            throw EdidError.outsideRange("only EDID 1.3 and 1.4 are supported")
        }
        for index in 0..<blocks {
            let slice = data[(index * 128)..<((index + 1) * 128)]
            let sum = slice.reduce(UInt8(0)) { $0 &+ $1 }
            guard sum == 0 else { throw EdidError.checksum(index) }
        }
    }

    public static func sha256Hex(_ data: [UInt8]) -> String {
        SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
    }

    /// True when the bytes are an override produced by this application, so the factory backup
    /// remains the authoritative source for identity and limits.
    public static func isOverride(_ data: [UInt8]) -> Bool {
        (try? validate(data)) != nil
            && data.count == 128
            && data[126] == 0
            && [overrideName, "STRETCHGUARD", "PY 4:3 STRETC"].contains(descriptorText(data, tag: 0xFC))
    }

    static func descriptorText(_ data: [UInt8], tag: UInt8) -> String {
        for offset in [54, 72, 90, 108] {
            let slice = Array(data[offset..<(offset + 18)])
            if slice[0] == 0, slice[1] == 0, slice[2] == 0, slice[3] == tag {
                let text = slice[5..<18].map { byte -> Character in
                    if byte == 0 || byte == 0x0A || byte == 0x0D || byte == 0x20 { return " " }
                    if byte >= 0x20 && byte < 0x7F { return Character(UnicodeScalar(byte)) }
                    return "?"
                }
                return String(text).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    static func decodeDetailedTimingSize(_ slice: ArraySlice<UInt8>) -> (UInt16, UInt16)? {
        guard slice.count >= 18 else { return nil }
        let array = Array(slice.prefix(18))
        if array[0] == 0 && array[1] == 0 { return nil }
        let width = UInt16(array[2]) | (UInt16(array[4] >> 4) << 8)
        let height = UInt16(array[5]) | (UInt16(array[7] >> 4) << 8)
        return (width, height)
    }

    public static func parse(_ data: [UInt8]) throws -> EdidInfo {
        try validate(data)
        let word = UInt16(data[8]) << 8 | UInt16(data[9])
        let vendor = [10, 5, 0].reduce(into: "") { result, shift in
            let value = ((word >> UInt16(shift)) & 0x1F) + 0x40
            result.append(Character(UnicodeScalar(UInt8(value))))
        }

        guard [10, 5, 0].allSatisfy({ (1...26).contains(Int((word >> $0) & 0x1F)) }) else {
            throw EdidError.outsideRange("invalid manufacturer identifier")
        }
        var vertical: ClosedRange<UInt8>?
        var horizontal: ClosedRange<UInt8>?
        var clock: UInt32?
        for offset in [54, 72, 90, 108] {
            let slice = Array(data[offset..<(offset + 18)])
            if slice[0] == 0, slice[1] == 0, slice[2] == 0, slice[3] == 0xFD, slice[4] == 0 {
                // EDID 1.4 range-offset flags require separate decoding; fail closed rather than
                // interpreting a 300 Hz panel as a 45 Hz panel or constructing an invalid range.
                guard slice[5] > 0, slice[5] <= slice[6], slice[7] > 0, slice[7] <= slice[8] else {
                    throw EdidError.outsideRange("malformed monitor range descriptor")
                }
                vertical = slice[5]...slice[6]
                horizontal = slice[7]...slice[8]
                clock = slice[9] == 0 ? nil : UInt32(slice[9]) * 10
            }
        }

        let identity = MonitorIdentity(
            vendor: vendor,
            product: UInt16(data[10]) | UInt16(data[11]) << 8,
            serial: UInt32(data[12]) | UInt32(data[13]) << 8 | UInt32(data[14]) << 16 | UInt32(data[15]) << 24,
            serialText: descriptorText(data, tag: 0xFF)
        )
        let name = descriptorText(data, tag: 0xFC)
        return EdidInfo(
            identity: identity,
            name: name.isEmpty ? "External Display" : name,
            blocks: 1 + Int(data[126]),
            maxPixelClockMHz: clock,
            verticalRangeHz: vertical,
            horizontalRangeKHz: horizontal,
            nativeSize: decodeDetailedTimingSize(data[54..<72])
        )
    }

    // MARK: Window generation (VESA CVT, non-reduced blanking)

    public static func cvtTiming(width: UInt16, height: UInt16, refreshHz: UInt16) throws -> Timing {
        guard (320...4095).contains(width), (200...4095).contains(height), width % 8 == 0 else {
            throw EdidError.resolution
        }
        guard (24...360).contains(refreshHz) else { throw EdidError.refresh }

        let hDisplay = Int64(width) - Int64(width) % 8
        let vDisplay = Int64(height)
        let rate = Int64(refreshHz)
        let vsync: Int64
        if height % 3 == 0 && UInt32(height) * 4 / 3 == UInt32(width) {
            vsync = 4
        } else if height % 9 == 0 && UInt32(height) * 16 / 9 == UInt32(width) {
            vsync = 5
        } else if height % 10 == 0 && UInt32(height) * 16 / 10 == UInt32(width) {
            vsync = 6
        } else if height % 4 == 0 && UInt32(height) * 5 / 4 == UInt32(width) {
            vsync = 7
        } else {
            vsync = 10
        }

        let tmp1 = 1_000 * 1_000_000 - 550 * 1_000 * rate
        let tmp2 = (vDisplay + 3) * 2
        let hPeriod = tmp1 * 2 / (tmp2 * rate)
        let syncBp = max(550 * 1_000 / hPeriod + 1, vsync + 3)
        let vTotal = vDisplay + syncBp + 3
        let blankPct = max(30 * 1_000 - 300 * hPeriod / 1_000, 20 * 1_000)
        var hBlank = hDisplay * blankPct / (100 * 1_000 - blankPct)
        hBlank -= hBlank % 16
        let hTotal = hDisplay + hBlank
        let hSyncEnd = hDisplay + hBlank / 2
        var hSyncStart = hSyncEnd - hTotal * 8 / 100
        hSyncStart += 8 - hSyncStart % 8
        var clockKHz = hTotal * 1_000 * 1_000 / hPeriod
        clockKHz -= clockKHz % 250
        guard clockKHz > 0, clockKHz <= 655_350 else { throw EdidError.pixelClock }

        return Timing(
            pixelClockHz: clockKHz * 1_000,
            hActive: UInt16(hDisplay),
            hBlank: UInt16(hBlank),
            hSyncOffset: UInt16(hSyncStart - hDisplay),
            hSyncWidth: UInt16(hSyncEnd - hSyncStart),
            vActive: height,
            vBlank: UInt16(vTotal - vDisplay),
            vSyncOffset: 3,
            vSyncWidth: UInt16(vsync),
            positiveHSync: false,
            positiveVSync: true
        )
    }

    static func textDescriptor(tag: UInt8, text: String) -> [UInt8] {
        var result = [UInt8](repeating: 0x20, count: 18)
        result[0] = 0; result[1] = 0; result[2] = 0; result[3] = tag; result[4] = 0
        let bytes = Array(text.utf8.prefix(13)).map { $0 < 0x7F ? $0 : 0x3F }
        for (index, byte) in bytes.enumerated() {
            result[5 + index] = byte
        }
        return result
    }

    static func rangeDescriptor(info: EdidInfo, refreshHz: UInt16, clockMHz: UInt32) -> [UInt8] {
        let clamp = UInt8(min(refreshHz, 255))
        let vertical = info.verticalRangeHz ?? (24...max(24, clamp))
        let horizontal = info.horizontalRangeKHz ?? (15...255)
        var descriptor = [UInt8](repeating: 0, count: 18)
        descriptor[0] = 0; descriptor[1] = 0; descriptor[2] = 0; descriptor[3] = 0xFD; descriptor[4] = 0
        descriptor[5] = min(vertical.lowerBound, clamp)
        descriptor[6] = max(vertical.upperBound, clamp)
        descriptor[7] = horizontal.lowerBound
        descriptor[8] = horizontal.upperBound
        descriptor[9] = UInt8(min((clockMHz + 9) / 10, 255))
        return descriptor
    }

    static func encodeDetailedTiming(_ timing: Timing, widthMM: UInt16, heightMM: UInt16) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 18)
        let clock = UInt16(timing.pixelClockHz / 10_000)
        d[0] = UInt8(clock & 0xFF)
        d[1] = UInt8(clock >> 8)
        d[2] = UInt8(timing.hActive & 0xFF)
        d[3] = UInt8(timing.hBlank & 0xFF)
        d[4] = ((UInt8(timing.hActive >> 8) << 4) | (UInt8(timing.hBlank >> 8) & 0x0F))
        d[5] = UInt8(timing.vActive & 0xFF)
        d[6] = UInt8(timing.vBlank & 0xFF)
        d[7] = ((UInt8(timing.vActive >> 8) << 4) | (UInt8(timing.vBlank >> 8) & 0x0F))
        d[8] = UInt8(timing.hSyncOffset & 0xFF)
        d[9] = UInt8(timing.hSyncWidth & 0xFF)
        d[10] = ((UInt8(timing.vSyncOffset & 0x0F) << 4) | (UInt8(timing.vSyncWidth) & 0x0F))
        d[11] = ((UInt8(timing.hSyncOffset >> 8) & 0x03) << 6)
            | ((UInt8(timing.hSyncWidth >> 8) & 0x03) << 4)
            | ((UInt8(timing.vSyncOffset >> 4) & 0x03) << 2)
            | ((UInt8(timing.vSyncWidth >> 4)) & 0x03)
        d[12] = UInt8(widthMM & 0xFF)
        d[13] = UInt8(heightMM & 0xFF)
        d[14] = ((UInt8(widthMM >> 8) << 4) | (UInt8(heightMM >> 8) & 0x0F))
        d[15] = 0
        d[16] = 0
        d[17] = 0x18
            | (timing.positiveHSync ? 0x02 : 0x00)
            | (timing.positiveVSync ? 0x04 : 0x00)
        return d
    }

    /// Builds a single-block EDID that advertises exactly one preferred physical timing.
    public static func generate(
        original: [UInt8],
        width: UInt16,
        height: UInt16,
        refreshHz: UInt16
    ) throws -> (edid: [UInt8], timing: Timing) {
        let info = try parse(original)
        guard !isOverride(original), original[20] & 0x80 != 0,
              UInt32(width) * 3 == UInt32(height) * 4 else {
            throw EdidError.outsideRange("a digital factory EDID and exact 4:3 resolution are required")
        }
        // Missing limits are not permission to invent them. EDID ranges are necessary but are not
        // sufficient evidence of scaler/cable compatibility; physical tests remain experimental.
        let offsets: [Int] = [54, 72, 90, 108]
        let extendedRangeFlags = offsets.contains { offset -> Bool in
            let isRange = original[offset] == 0 && original[offset + 1] == 0 && original[offset + 3] == 253
            return isRange && original[offset + 4] != 0
        }
        guard !extendedRangeFlags,
              info.verticalRangeHz != nil, info.horizontalRangeKHz != nil, info.maxPixelClockMHz != nil else {
            throw EdidError.outsideRange("the monitor does not report complete timing limits")
        }
        if let native = info.nativeSize, width > native.width || height > native.height {
            throw EdidError.outsideRange("requested dimensions exceed the preferred panel dimensions")
        }
        let timing = try cvtTiming(width: width, height: height, refreshHz: refreshHz)
        guard timing.hBlank <= 4095, timing.vBlank <= 4095,
              timing.hSyncOffset <= 1023, timing.hSyncWidth <= 1023,
              timing.vSyncOffset <= 63, timing.vSyncWidth <= 63 else {
            throw EdidError.resolution
        }
        if let vertical = info.verticalRangeHz,
           (refreshHz < UInt16(vertical.lowerBound) || refreshHz > UInt16(vertical.upperBound)
            || timing.actualRefreshHz < Double(vertical.lowerBound)
            || timing.actualRefreshHz > Double(vertical.upperBound)) {
            throw EdidError.outsideRange("vertical range is \(vertical.lowerBound)–\(vertical.upperBound) Hz")
        }
        if let horizontal = info.horizontalRangeKHz {
            let hfreq = timing.horizontalFrequencyKHz
            if hfreq < Double(horizontal.lowerBound) || hfreq > Double(horizontal.upperBound) {
                throw EdidError.outsideRange(
                    "horizontal range is \(horizontal.lowerBound)–\(horizontal.upperBound) kHz"
                )
            }
        }
        if let maxClock = info.maxPixelClockMHz,
           timing.pixelClockHz > Int64(maxClock) * 1_000_000 {
            throw EdidError.outsideRange("pixel clock limit is \(maxClock) MHz")
        }

        var result = [UInt8](repeating: 0, count: 128)
        result.replaceSubrange(0..<18, with: original[0..<18])
        result[18] = 1
        result[19] = 4
        result[20] = original[20] | 0x80
        result[24] = (original[24] | 0x02) & 0xFE
        result.replaceSubrange(25..<35, with: original[25..<35])
        // No established timings, no standard timings, no extension blocks.
        for index in 35..<38 { result[index] = 0 }
        for index in 38..<54 { result[index] = 0x01 }

        // Keep the panel's physical height but describe a signal-accurate width, so the detailed
        // timing advertises square pixels for the requested 4:3 frame (matching the verified
        // reference: 400 × 300 mm for a 1280 × 960 signal on this 530 × 300 mm panel).
        let (widthMM, heightMM) = physicalSize(
            originalWidthCM: original[21],
            originalHeightCM: original[22],
            width: width,
            height: height
        )
        result[21] = UInt8(min((widthMM + 5) / 10, 255))
        result[22] = UInt8(min((heightMM + 5) / 10, 255))
        result[23] = original[23]
        result.replaceSubrange(54..<72, with: encodeDetailedTiming(timing, widthMM: widthMM, heightMM: heightMM))
        result.replaceSubrange(72..<90, with: textDescriptor(tag: 0xFC, text: overrideName))
        result.replaceSubrange(90..<108, with: textDescriptor(tag: 0xFF, text: info.identity.serialText))
        result.replaceSubrange(
            108..<126,
            with: rangeDescriptor(
                info: info,
                refreshHz: refreshHz,
                clockMHz: UInt32(timing.pixelClockHz / 1_000_000)
            )
        )
        result[126] = 0
        let sum = result[0..<127].reduce(UInt8(0)) { $0 &+ $1 }
        result[127] = 0 &- sum
        try validate(result)
        return (result, timing)
    }

    /// Physical size in millimetres that matches the requested frame aspect.
    public static func physicalSize(
        originalWidthCM: UInt8,
        originalHeightCM: UInt8,
        width: UInt16,
        height: UInt16
    ) -> (widthMM: UInt16, heightMM: UInt16) {
        guard width > 0, height > 0 else { return (0, 0) }
        let widthCM = UInt32(originalWidthCM)
        let heightCM = UInt32(originalHeightCM)
        let heightMM: UInt32
        let widthMM: UInt32
        if heightCM > 0 {
            heightMM = heightCM * 10
            widthMM = (heightMM * UInt32(width) + UInt32(height) / 2) / UInt32(height)
        } else if widthCM > 0 {
            widthMM = widthCM * 10
            heightMM = (widthMM * UInt32(height) + UInt32(width) / 2) / UInt32(width)
        } else {
            // Unknown physical dimensions remain unknown; do not invent them.
            widthMM = 0
            heightMM = 0
        }
        return (UInt16(min(widthMM, 4095)), UInt16(min(heightMM, 4095)))
    }

    /// Candidate presets, not a hardware-safety guarantee: exact 4:3 sizes inside EDID limits.
    public static func presets(for factoryEdid: [UInt8]) -> [ResolutionPreset] {
        guard let info = try? parse(factoryEdid) else { return [] }
        let resolutions: [(UInt16, UInt16)] = [
            (1920, 1440), (1600, 1200), (1440, 1080), (1280, 960), (1024, 768), (800, 600),
        ]
        let refreshRates: [UInt16] = [60, 75, 120, 144, 165, 240]
        var presets: [ResolutionPreset] = []
        for (width, height) in resolutions {
            if let native = info.nativeSize, width > native.width || height > native.height { continue }
            for refresh in refreshRates where (try? generate(
                original: factoryEdid,
                width: width,
                height: height,
                refreshHz: refresh
            )) != nil {
                presets.append(ResolutionPreset(width: width, height: height, refreshHz: refresh))
            }
        }
        if !presets.isEmpty {
            // Prefer a low-clock 60 Hz entry for the first test, not the largest/highest mode.
            if let index = presets.firstIndex(where: { $0.width == 1024 && $0.refreshHz == 60 }) {
                presets.swapAt(0, index)
            }
            // EDID range compliance is not a recommendation or a hardware validation.
        }
        return presets
    }
}

public struct ResolutionPreset: Equatable, Hashable, Identifiable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var refreshHz: UInt16
    public var isRecommended: Bool

    public init(width: UInt16, height: UInt16, refreshHz: UInt16, isRecommended: Bool = false) {
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
        self.isRecommended = isRecommended
    }

    public var id: String { "\(width)x\(height)@\(refreshHz)" }

    public var title: String { "\(width) × \(height)" }

    public var subtitle: String {
        isRecommended ? "\(refreshHz) Hz — Recommended" : "\(refreshHz) Hz"
    }
}
