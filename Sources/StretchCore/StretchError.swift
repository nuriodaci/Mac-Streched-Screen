import Foundation

public enum StretchError: Error, Equatable, CustomStringConvertible {
    case unsupportedHardware(String)
    case ioKit(String)
    case displayNotFound
    case ambiguousIdentity
    case backupConflict(String)
    case backupCorrupted(String)
    case backupWriteFailed(String)
    case invalidInput(String)
    case watchdogFailed(String)

    public var description: String {
        switch self {
        case .unsupportedHardware(let detail): return detail
        case .ioKit(let detail): return detail
        case .displayNotFound: return "the selected monitor is not currently connected"
        case .ambiguousIdentity:
            return "multiple connected monitors share this EDID identity; safe selection is impossible"
        case .backupConflict(let detail): return detail
        case .backupCorrupted(let detail): return detail
        case .backupWriteFailed(let detail): return detail
        case .invalidInput(let detail): return detail
        case .watchdogFailed(let detail): return detail
        }
    }

    public var localizedMessage: String { description }
}

extension Error {
    /// Message suitable for the status line: domain-specific where possible, never empty.
    public var displayMessage: String {
        if let error = self as? StretchError { return error.description }
        if let error = self as? EdidError { return error.description }
        let nsError = self as NSError
        return nsError.localizedDescription.isEmpty ? nsError.domain : nsError.localizedDescription
    }
}
