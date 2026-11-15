import ApelinProtocol
import Foundation

extension Error {
    /// What an alert says about this error. `ApelinError` is not a
    /// `LocalizedError`, and its `localizedDescription` is Foundation's
    /// "The operation couldn't be completed" with a type name in it.
    /// The peer's message is kept when it sent one; otherwise the code is
    /// put in the user's words, never shown by its raw name.
    var readableMessage: String {
        if let error = self as? ApelinError {
            if error.code == .backendUnavailable || error.message.isEmpty {
                return error.code.readableMessage
            }
            return error.message
        }
        return localizedDescription
    }
}

extension ApelinError.Code {
    /// Whether a page following a task stops on this error instead of
    /// attaching again: the host does not have the task, will not show it,
    /// refused the request, or is not there at all.
    var endsTaskFollowing: Bool {
        [.notFound, .denied, .badRequest, .backendUnavailable].contains(self)
    }

    /// The sentence for an error that carries no message of its own.
    var readableMessage: String {
        switch self {
        case .unimplemented:
            String(localized: "This feature is not available in this version.")
        case .badRequest:
            String(localized: "Check the information you entered and try again.")
        case .unknownOperation, .unsupportedVersion:
            String(localized: """
            Apelin and its background service are different versions. Reinstall Apelin with your \
            preferred package manager, then try again.
            """)
        case .denied:
            String(localized: "Apelin does not have permission to complete this action.")
        case .notFound:
            String(localized: "The item could not be found. It may have been removed.")
        case .conflict:
            String(localized: "An item with the same name or identifier already exists.")
        case .cancelled:
            String(localized: "The operation was cancelled.")
        case .timeout:
            String(localized: "The request timed out. Try again.")
        case .backendUnavailable:
            String(localized: """
            This needs Apelin’s background service, which is not running on this device. Reinstall \
            Apelin with your preferred package manager to set it up again.
            """)
        case .unavailable:
            String(localized: "Apelin’s background service could not be reached. Try again in a moment.")
        case .internal:
            String(localized: "Something went wrong. Try again.")
        }
    }
}
