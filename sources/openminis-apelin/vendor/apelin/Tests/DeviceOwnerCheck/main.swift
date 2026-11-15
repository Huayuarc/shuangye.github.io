import Foundation
import LocalAuthentication

// The app's device-owner decision (Apelin/Application/DeviceOwnerCheck.swift):
// approving a command as root, or turning on Full mode, sends nothing to the
// host unless this passes. Only a successful evaluation, or a device with no
// passcode (`passcodeNotSet` at `canEvaluatePolicy`), passes; every other
// error fails. The app has no Mac target, so the decision is a pure function
// tested here (`make harness`).

var failures = 0
func check(_ condition: Bool, _ what: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL \(what) (line \(line))")
    }
}

let laDomain = LAError.errorDomain

// A device with no passcode: canEvaluatePolicy returns false with
// passcodeNotSet, and the user is let through with no owner to check.
check(
    DeviceOwnerCheck.passes(.cannotEvaluate(code: LAError.Code.passcodeNotSet.rawValue, domain: laDomain)),
    "a device with no passcode passes",
)

/// Every other reason canEvaluatePolicy can refuse fails: it is not the
/// no-passcode case, so there is an owner to check and the check did not run.
let cannotEvaluateFailures: [LAError.Code] = [
    .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet,
]
for code in cannotEvaluateFailures where code != .passcodeNotSet {
    check(
        !DeviceOwnerCheck.passes(.cannotEvaluate(code: code.rawValue, domain: laDomain)),
        "canEvaluate false with \(code.rawValue) fails",
    )
}

// passcodeNotSet reported under another domain is not the no-passcode case.
check(
    !DeviceOwnerCheck.passes(.cannotEvaluate(code: LAError.Code.passcodeNotSet.rawValue, domain: "com.example")),
    "passcodeNotSet under a foreign domain does not pass",
)
check(!DeviceOwnerCheck.passes(.cannotEvaluate(code: nil, domain: nil)), "canEvaluate false with no error fails")

// A successful evaluation passes with its own answer; a declined one fails.
check(DeviceOwnerCheck.passes(.evaluated(true)), "a successful authentication passes")
check(!DeviceOwnerCheck.passes(.evaluated(false)), "an unsuccessful authentication fails")

/// Every error evaluatePolicy can throw fails and sends nothing — including
/// passcodeNotSet, which passes only through the canEvaluate path above.
let thrownFailures: [LAError.Code] = [
    .userCancel, .appCancel, .systemCancel, .authenticationFailed,
    .userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled,
    .notInteractive, .invalidContext, .passcodeNotSet,
]
for code in thrownFailures {
    check(!DeviceOwnerCheck.passes(.threw(code: code.rawValue, domain: laDomain)), "a thrown \(code.rawValue) fails")
}

// An "unknown" LAError (a code the SDK's enum does not name) still fails.
check(!DeviceOwnerCheck.passes(.threw(code: -1000, domain: laDomain)), "an unknown LAError fails")
check(!DeviceOwnerCheck.passes(.threw(code: nil, domain: nil)), "a throw with no NSError detail fails")

if failures == 0 {
    print("ok: DeviceOwnerCheck passes only a success or a passcode-less device")
} else {
    print("DeviceOwnerCheck: \(failures) failure(s)")
    exit(1)
}
