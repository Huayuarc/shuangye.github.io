import Foundation
import LocalAuthentication

/// Face ID, Touch ID or the passcode, before the reader lets the agent run
/// a command as root: approving one such command, or turning on Full mode.
/// A device with no passcode has no owner to check, and passes.
enum DeviceOwnerCheck {
    /// The outcome of the two LocalAuthentication calls, as a value, so the
    /// decision behind the app's `ownerVerified` is a pure function tested
    /// off a device (Tests/DeviceOwnerCheck).
    enum Outcome: Equatable {
        /// `canEvaluatePolicy` returned false, with this error, if any.
        case cannotEvaluate(code: Int?, domain: String?)
        /// `canEvaluatePolicy` returned true and `evaluatePolicy` finished
        /// with this answer.
        case evaluated(Bool)
        /// `canEvaluatePolicy` returned true and `evaluatePolicy` threw.
        case threw(code: Int?, domain: String?)
    }

    /// Whether the owner confirmed. A successful evaluation passes with its
    /// own answer; a device with no passcode (`passcodeNotSet` at
    /// `canEvaluatePolicy`) passes; every other error — a cancel, a failed
    /// authentication, a biometry lockout, a policy the device cannot
    /// evaluate, a throw — fails. The app sends nothing to the host unless
    /// this is true, and then sends `ownerVerified`.
    static func passes(_ outcome: Outcome) -> Bool {
        switch outcome {
        case let .cannotEvaluate(code, domain):
            code == LAError.Code.passcodeNotSet.rawValue && domain == LAError.errorDomain
        case let .evaluated(answer):
            answer
        case .threw:
            false
        }
    }

    /// Runs the system's prompt and answers `passes` of its outcome.
    @MainActor
    static func confirm(reason: String) async -> Bool {
        await passes(evaluate(reason: reason))
    }

    @MainActor
    private static func evaluate(reason: String) async -> Outcome {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .cannotEvaluate(code: policyError?.code, domain: policyError?.domain)
        }
        do {
            return try await .evaluated(context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason))
        } catch let error as NSError {
            return .threw(code: error.code, domain: error.domain)
        }
    }
}
