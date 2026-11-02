import Foundation
import Security

/// Storage for small secrets (database key, API keys).
public protocol SecretStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain \(operation) failed: \(message) (\(status))"
    }
}

/// Generic passwords in the user's Keychain, scoped by service name.
///
/// On macOS this uses the login keychain, which needs no entitlements for a
/// non-sandboxed app. Items are readable only while the device is unlocked,
/// unless `accessibility` says otherwise (the iPhone syncs in the background
/// while locked). On iOS new items go to the first group of the app's
/// `keychain-access-groups` entitlement, which its extensions share.
public struct KeychainStore: SecretStore {
    public static let defaultService = "dev.jonaszell.cortex"
    /// The service name from when the app was called "the-mind".
    public static let legacyService = "dev.jonaszell.the-mind"

    public let service: String
    /// Looked up when `service` has no item for an account. A found item is
    /// copied to `service` and removed here, so this happens once.
    public let legacyService: String?
    /// `kSecAttrAccessible` of new items.
    public let accessibility: String

    public init(
        service: String = KeychainStore.defaultService,
        legacyService: String? = nil,
        accessibility: String = kSecAttrAccessibleWhenUnlocked as String
    ) {
        self.service = service
        self.legacyService = legacyService
        self.accessibility = accessibility
    }

    /// The app's own store, which takes over items left by "the-mind". The
    /// first read of such an item asks the user once: the item's access list
    /// names the old app, not this one.
    public static var app: KeychainStore {
        KeychainStore(service: defaultService, legacyService: legacyService)
    }

    public func data(for account: String) throws -> Data? {
        if let data = try read(account, service: service) {
            return data
        }
        guard let legacyService, let data = try read(account, service: legacyService) else {
            return nil
        }
        try set(data, for: account)
        do {
            try KeychainStore(service: legacyService).delete(account)
        } catch {
            Log.keychain.error("Could not remove the old Keychain item: \(error, privacy: .public)")
        }
        Log.keychain.notice("Moved \(account, privacy: .public) from \(legacyService, privacy: .public) to \(service, privacy: .public)")
        return data
    }

    private func read(_ account: String, service: String) throws -> Data? {
        var query = baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status, operation: "read")
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = accessibility
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus, operation: "add")
            }
        default:
            throw KeychainError(status: status, operation: "update")
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    private func baseQuery(_ account: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
        ]
    }
}
