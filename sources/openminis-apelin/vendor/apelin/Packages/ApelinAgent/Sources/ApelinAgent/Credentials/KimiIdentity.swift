import Foundation
import KWWKAI

/// Kimi's device fingerprint without kwwk's `~/.kwwk/kimi-device-id`, which
/// Apelin never reads or writes (nothing is shared with `~/.kwwk`).
///
/// Kimi binds a grant to the device id it was approved on. kwwk writes that
/// id into the credential as its `deviceId` extra at sign-in and again on
/// every refresh, and a refresh sends the recorded id whatever identity it
/// was given. So the id lives in the credential, in the keychain: a sign-in
/// again reuses the one the stored credential recorded, and a first one
/// makes a new id in kwwk's format. Every identity Apelin hands kwwk names
/// its id, so kwwk never falls back to its own file.
public enum KimiIdentity {
    public static let deviceIDExtra = "deviceId"

    /// The identity a sign-in or a refresh sends: the recorded id, else a
    /// new one.
    public static func identity(recordedIn credentials: OAuthCredentials?) -> KimiDeviceIdentity {
        if case let .string(recorded)? = credentials?.extras[deviceIDExtra], !recorded.isEmpty {
            return .host(deviceId: recorded)
        }
        return .host(deviceId: newDeviceID())
    }

    /// 32 lowercase hex digits, as kwwk makes its own.
    public static func newDeviceID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// kwwk's refreshers, with Kimi's given an identity of its own (the
    /// recorded id still wins), and Devin's, which renews nothing but has to
    /// be known by id: `OAuthManager.defaultProviders()` without the file.
    public static func refreshers() -> [any OAuthProvider] {
        OAuthSubscriptions.refreshers(kimiIdentity: .host(deviceId: newDeviceID())) + [DevinOAuthProvider()]
    }
}
