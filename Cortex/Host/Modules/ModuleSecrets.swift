import Foundation
import CortexCore

/// A secret a module keeps in the Keychain, never in UserDefaults or the
/// database.
struct ModuleSecretKey: Hashable, Sendable {
    /// "<id>.<name>", or a legacy account ("sync-key").
    let account: String
    /// "API key"
    let title: String
}

/// A module's secrets, through `KeychainStore.app` in the app.
struct ModuleSecrets {
    let id: ModuleID
    let store: any SecretStore

    /// The key for account "<id>.<name>".
    func key(_ name: String, title: String) -> ModuleSecretKey {
        ModuleSecretKey(account: "\(id.rawValue).\(name)", title: title)
    }

    /// nil while not set, and when the Keychain cannot be read.
    func string(for key: ModuleSecretKey) -> String? {
        guard let data = try? store.data(for: key.account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func isSet(_ key: ModuleSecretKey) -> Bool {
        string(for: key) != nil
    }

    func set(_ value: String, for key: ModuleSecretKey) throws {
        try store.set(Data(value.utf8), for: key.account)
    }

    func remove(_ key: ModuleSecretKey) throws {
        try store.delete(key.account)
    }
}
