import Foundation
import IOKit
import CoreGraphics

/// A physically connected external display discovered through Apple's display coprocessor.
public struct Display: Identifiable, Equatable, Sendable {
    public var serviceIndex: Int
    public var edid: [UInt8]
    public var info: EdidInfo

    public var id: Int { serviceIndex }

    public init(serviceIndex: Int, edid: [UInt8]) throws {
        self.serviceIndex = serviceIndex
        self.edid = edid
        self.info = try Edid.parse(edid)
    }

    public static func == (lhs: Display, rhs: Display) -> Bool {
        lhs.serviceIndex == rhs.serviceIndex && lhs.edid == rhs.edid
    }
}

/// The narrow platform boundary. All display mutation goes through this protocol so the safety
/// logic can be exercised without hardware.
public protocol DisplayPlatform: Sendable {
    func displays() throws -> [Display]
    func applyOverride(_ edid: [UInt8], to identity: MonitorIdentity) throws
    func resetOverride(for identity: MonitorIdentity) throws
    func resetAll() throws -> Int
}

// MARK: - Private IOKit bindings

typealias IOAVServiceCreateWithServiceFn =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias IOAVServiceCopyEDIDFn =
    @convention(c) (CFTypeRef?, UnsafeMutablePointer<Unmanaged<CFData>?>?) -> Int32
typealias IOAVServiceSetVirtualEDIDModeFn =
    @convention(c) (CFTypeRef?, UInt32, CFData?) -> Int32

enum PrivateIOAVService {
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static let create: IOAVServiceCreateWithServiceFn? =
        symbol("IOAVServiceCreateWithService", as: IOAVServiceCreateWithServiceFn.self)
    static let copyEDID: IOAVServiceCopyEDIDFn? =
        symbol("IOAVServiceCopyEDID", as: IOAVServiceCopyEDIDFn.self)
    static let setVirtualEDIDMode: IOAVServiceSetVirtualEDIDModeFn? =
        symbol("IOAVServiceSetVirtualEDIDMode", as: IOAVServiceSetVirtualEDIDModeFn.self)

    /// True when the machine exposes the private EDID override entry points.
    static var isAvailable: Bool { create != nil && copyEDID != nil && setVirtualEDIDMode != nil }

    static func formatted(_ value: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: value))
    }
}

// MARK: - macOS implementation

public struct MacDisplayPlatform: DisplayPlatform {
    public init() throws {
        #if arch(arm64)
        guard PrivateIOAVService.isAvailable else {
            throw StretchError.unsupportedHardware(
                "this macOS version does not expose the private IOAVService EDID interface"
            )
        }
        #else
        throw StretchError.unsupportedHardware("EDID override is supported only on Apple Silicon Macs")
        #endif
    }

    struct Service {
        var index: Int
        var avService: CFTypeRef
        var edid: [UInt8]?
    }

    /// All external AV services, optionally skipping those without a readable EDID.
    func services(requireEdid: Bool = true) throws -> [Service] {
        guard PrivateIOAVService.isAvailable,
              let create = PrivateIOAVService.create,
              let copyEDID = PrivateIOAVService.copyEDID
        else {
            throw StretchError.unsupportedHardware(
                "this macOS version does not expose the private IOAVService EDID interface"
            )
        }
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else {
            throw StretchError.ioKit("could not query the display coprocessor services")
        }
        var iterator: io_iterator_t = 0
        let matched = IOServiceGetMatchingServices(0, matching, &iterator)
        guard matched == KERN_SUCCESS else {
            throw StretchError.ioKit(
                "display service enumeration failed (\(PrivateIOAVService.formatted(matched)))"
            )
        }
        defer { IOObjectRelease(iterator) }

        var result: [Service] = []
        while true {
            let object = IOIteratorNext(iterator)
            if object == 0 { break }
            guard let avService = create(nil, object)?.takeRetainedValue() else {
                IOObjectRelease(object)
                continue
            }
            IOObjectRelease(object)

            var dataRef: Unmanaged<CFData>?
            let status = copyEDID(avService, &dataRef)
            let ownedData = dataRef?.takeRetainedValue()
            guard status == KERN_SUCCESS, let data = ownedData,
                  CFDataGetLength(data) <= 32_768 else {
                result.append(Service(index: result.count, avService: avService, edid: nil))
                continue
            }
            let bytes = [UInt8](data as Data)
            let valid = (try? Edid.validate(bytes)) != nil
            if valid {
                result.append(Service(index: result.count, avService: avService, edid: bytes))
            } else {
                result.append(Service(index: result.count, avService: avService, edid: nil))
            }
        }
        return requireEdid ? result.filter { $0.edid != nil } : result
    }

    func matchingService(for identity: MonitorIdentity) throws -> Service {
        let candidates = try services().filter { service in
            guard let edid = service.edid, let info = try? Edid.parse(edid) else { return false }
            return info.identity == identity
        }
        guard let match = candidates.first else { throw StretchError.displayNotFound }
        guard candidates.count == 1 else { throw StretchError.ambiguousIdentity }
        return match
    }

    public func displays() throws -> [Display] {
        var displays: [Display] = []
        for service in try services() {
            guard let edid = service.edid else { continue }
            if let display = try? Display(serviceIndex: service.index, edid: edid) {
                displays.append(display)
            }
        }
        return displays
    }

    public func applyOverride(_ edid: [UInt8], to identity: MonitorIdentity) throws {
        try Edid.validate(edid)
        guard identity.isValid, Edid.isOverride(edid), try Edid.parse(edid).identity == identity else {
            throw StretchError.invalidInput("Only a validated override for this monitor can be applied.")
        }
        guard let setMode = PrivateIOAVService.setVirtualEDIDMode else {
            throw StretchError.unsupportedHardware("EDID override is unavailable in this macOS build")
        }
        let service = try matchingService(for: identity)
        try verifyPhysicalTarget(identity)
        let data = Data(edid) as CFData
        let status = setMode(service.avService, 1, data)
        guard status == KERN_SUCCESS else {
            throw StretchError.ioKit(
                "applying the display mode failed (\(PrivateIOAVService.formatted(status)))"
            )
        }
    }

    /// A DCP service alone is not sufficient: correlate with exactly one online, external,
    /// non-mirrored CoreGraphics display before mutation. Never target an internal panel.
    private func verifyPhysicalTarget(_ identity: MonitorIdentity) throws {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 128 else {
            throw StretchError.ioKit("Unable to correlate the physical display.")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw StretchError.ioKit("Unable to enumerate online displays.")
        }
        let vendorBytes = Array(identity.vendor.utf8)
        guard vendorBytes.count == 3 else { throw StretchError.invalidInput("Invalid vendor.") }
        let vendor = UInt32(vendorBytes[0] - 64) << 10 | UInt32(vendorBytes[1] - 64) << 5 | UInt32(vendorBytes[2] - 64)
        let matches = ids.prefix(Int(count)).filter {
            CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == UInt32(identity.product)
                && CGDisplaySerialNumber($0) == identity.serial
        }
        guard matches.count == 1, let id = matches.first,
              CGDisplayIsBuiltin(id) == 0, CGDisplayIsActive(id) != 0,
              CGDisplayIsInMirrorSet(id) == 0 else {
            throw StretchError.unsupportedHardware("Only uniquely identified, active, non-mirrored external displays can be tested.")
        }
    }

    public func resetOverride(for identity: MonitorIdentity) throws {
        guard let setMode = PrivateIOAVService.setVirtualEDIDMode else {
            throw StretchError.unsupportedHardware("EDID override is unavailable in this macOS build")
        }
        let service = try matchingService(for: identity)
        // Idempotent recovery: a stale helper must not flicker an already-restored display.
        if let edid = service.edid, !Edid.isOverride(edid) { return }
        let status = setMode(service.avService, 0, nil)
        guard status == KERN_SUCCESS else {
            throw StretchError.ioKit("resetting the display failed (\(PrivateIOAVService.formatted(status)))")
        }
        // API success alone does not prove the override disappeared. Retry only EDID reads here;
        // retrying the reset itself belongs to the independent recovery helper.
        for _ in 0..<20 {
            if let restored = try? matchingService(for: identity), let edid = restored.edid,
               !Edid.isOverride(edid) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw StretchError.ioKit("Reset was requested but the factory EDID has not reappeared yet.")
    }

    public func resetAll() throws -> Int {
        guard let setMode = PrivateIOAVService.setVirtualEDIDMode else {
            throw StretchError.unsupportedHardware("EDID override is unavailable in this macOS build")
        }
        _ = setMode
        var count = 0
        var failures: [String] = []
        let targets = try displays().filter { Edid.isOverride($0.edid) }
        for display in targets {
            do {
                try resetOverride(for: display.info.identity)
                count += 1
            } catch { failures.append(error.displayMessage) }
        }
        if !failures.isEmpty {
            throw StretchError.ioKit("Restored \(count) override(s); remaining failures: \(failures.joined(separator: "; "))")
        }
        return count
    }
}
