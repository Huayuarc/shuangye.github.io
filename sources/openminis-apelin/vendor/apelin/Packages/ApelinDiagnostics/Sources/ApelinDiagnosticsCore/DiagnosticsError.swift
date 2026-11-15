import Foundation

public enum DiagnosticsError: Error, Equatable, Sendable {
    /// A typed parameter was out of its range; nothing was attempted.
    case invalidParameter(String)
    /// The capability does not exist here: no icli on this platform, a private
    /// class missing on this OS, a process without the entitlement it needs.
    /// Not an error to show as a failure — a reason to say "unavailable".
    case unavailable(String)
    /// The device is locked or its screen is off, and the call needs neither.
    /// `screenOff` tells the two apart: a dark screen, locked or not, or a
    /// lit lock screen.
    case locked(screenOff: Bool)
    /// The capability ran and failed.
    case failed(String)
}

extension DiagnosticsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidParameter(message): message
        case let .unavailable(message): message
        case .locked(screenOff: true):
            "The screen is off. Press the wake button to turn it on, then try again; a device with a passcode then shows its lock screen until the user unlocks it."
        case .locked(screenOff: false):
            "The device is locked. Press the wake button, which takes a device without a passcode past its lock screen, then try again; a device with a passcode stays locked until the user unlocks it."
        case let .failed(message): message
        }
    }
}
