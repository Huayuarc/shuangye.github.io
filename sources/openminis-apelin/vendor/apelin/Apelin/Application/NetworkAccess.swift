import Dog
import Foundation

/// The app's own network: CoreTelephony's per-app data policy, the switch
/// Settings calls Wireless Data (WLAN & Cellular on a device sold in
/// China). An app a package manager installed is never asked about it,
/// and where the system holds it denied, every request the app makes fails
/// "The Internet connection appears to be offline" while apelind and the
/// workers, which are not apps, reach the network: Sign In with GitHub,
/// which runs in the app, failed so while a model provider's sign-in, run
/// by apelin-agent, went through. Once a launch, off the main thread, the
/// app allows itself Wi-Fi and cellular data, as Irisin does at every
/// launch (`CellularPolicy`), read first as icli's `app network repair` is
/// (`icli_app_network_policy_json`), so a policy already open is not
/// written again and a change is in the journal. The
/// `com.apple.CommCenter.fine-grained` entitlement is what CoreTelephony
/// asks for.
enum NetworkAccess {
    private static let cellular = "kCTCellularDataUsagePolicy"
    private static let wifi = "kCTWiFiDataUsagePolicy"
    private static let alwaysAllow = "kCTCellularDataUsagePolicyAlwaysAllow"

    private typealias Create = @convention(c) (CFAllocator?, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<AnyObject>?
    private typealias CopyPolicy = @convention(c) (AnyObject, CFString, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int64
    private typealias SetPolicy = @convention(c) (AnyObject, CFString, CFDictionary) -> Int64

    static func start() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        DispatchQueue.global(qos: .utility).async {
            if let note = allow(bundleID) {
                Dog.shared.join("Network", note, level: .info)
            }
        }
    }

    /// What was changed or went wrong; nil when both were already allowed.
    private static func allow(_ bundleID: String) -> String? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW),
              let create = dlsym(handle, "_CTServerConnectionCreate"),
              let copy = dlsym(handle, "_CTServerConnectionCopyCellularUsagePolicy"),
              let set = dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy")
        else { return "CoreTelephony's data policy calls are unavailable" }
        guard let connection = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault, nil, nil)?
            .takeRetainedValue()
        else { return "CoreTelephony did not answer" }

        // a policy that cannot be read is written all the same, as Irisin does
        var copied: Unmanaged<CFDictionary>?
        let read = unsafeBitCast(copy, to: CopyPolicy.self)(connection, bundleID as CFString, &copied)
        let policy = read == 0 ? (copied?.takeRetainedValue() as? [String: Any]) ?? [:] : nil
        if let policy, policy[cellular] as? String == alwaysAllow, policy[wifi] as? String == alwaysAllow {
            return nil
        }
        let before = policy.map { "\($0)" } ?? "unreadable (\(read))"
        let wanted = [cellular: alwaysAllow, wifi: alwaysAllow] as CFDictionary
        let written = unsafeBitCast(set, to: SetPolicy.self)(connection, bundleID as CFString, wanted)
        guard written == 0 else { return "the data policy, \(before), could not be changed (\(written))" }
        return "Wi-Fi and cellular data allowed; the data policy was \(before)"
    }
}
