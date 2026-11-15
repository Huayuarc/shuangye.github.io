import Foundation
import KWWKAI
import Security

public enum KeychainCredentialError: Error, Equatable, LocalizedError {
    case status(OSStatus)
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case let .status(status): "keychain error \(status)"
        case let .undecodable(providerID): "Unable to read the saved sign-in for \(providerID). Sign in again."
        }
    }
}

/// Provider credentials in the keychain: Apelin's own generic-password
/// items under service `wiki.qaq.apelin.agent`, one per kwwk store id,
/// readable after first unlock on this device only and never synchronised.
///
/// Nothing is shared with kk or `~/.kwwk`. `accessGroup` names the keychain
/// access group the app and `apelin-agent` share, once A2's spike confirms
/// one works on the supported bootstraps; nil uses the process's default.
public struct KeychainCredentialSource: CredentialSource {
    public static let service = "wiki.qaq.apelin.agent"

    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func providerIds() async -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func credentials(for providerId: String) async throws -> OAuthCredentials? {
        var query = itemQuery(providerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else { throw KeychainCredentialError.status(status) }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(OAuthCredentials.self, from: data)
        else {
            throw KeychainCredentialError.undecodable(providerId)
        }
        return credentials
    }

    public func store(_ credentials: OAuthCredentials, for providerID: String) async throws {
        let update = try writeAttributes(JSONEncoder().encode(credentials))
        let status = SecItemUpdate(itemQuery(providerID) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else { throw KeychainCredentialError.status(status) }
        var add = itemQuery(providerID)
        add.merge(update) { _, new in new }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainCredentialError.status(added) }
    }

    public func remove(_ providerID: String) async throws {
        let status = SecItemDelete(itemQuery(providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.status(status)
        }
    }

    // MARK: - Queries

    /// Every query names the service, refuses synchronised items and, on
    /// macOS, the data-protection keychain so the iOS semantics hold.
    func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Readable after the first unlock, so a background session works with
    /// the screen locked; never leaves this device.
    func writeAttributes(_ data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    func itemQuery(_ providerID: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = providerID
        return query
    }
}
