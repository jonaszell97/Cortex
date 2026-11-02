import Foundation

/// A module's values in UserDefaults. New keys are stored as "<id>.<name>";
/// keys that existed before modules keep their names through `.legacy`, so no
/// setting is lost (docs/ARCHITECTURE.md, "Stored keys and names that must not
/// change").
struct ModuleDefaults {
    struct Key: Hashable, Sendable, ExpressibleByStringLiteral {
        fileprivate enum Name: Hashable, Sendable {
            case scoped(String)
            case legacy(String)
        }

        fileprivate let name: Name

        /// "<id>.<name>"
        init(stringLiteral name: String) {
            self.name = .scoped(name)
        }

        static func named(_ name: String) -> Key {
            Key(name: .scoped(name))
        }

        /// A key stored under exactly this name: `.legacy("retentionDays")`.
        static func legacy(_ key: String) -> Key {
            Key(name: .legacy(key))
        }

        private init(name: Name) {
            self.name = name
        }
    }

    let id: ModuleID
    /// For the settings classes that read and write their own keys.
    let store: UserDefaults

    func storageKey(_ key: Key) -> String {
        switch key.name {
        case .scoped(let name): "\(id.rawValue).\(name)"
        case .legacy(let name): name
        }
    }

    func object(_ key: Key) -> Any? {
        store.object(forKey: storageKey(key))
    }

    /// nil while unset, unlike `UserDefaults.bool(forKey:)`.
    func bool(_ key: Key) -> Bool? {
        object(key) as? Bool
    }

    func integer(_ key: Key) -> Int? {
        object(key) as? Int
    }

    func string(_ key: Key) -> String? {
        store.string(forKey: storageKey(key))
    }

    func data(_ key: Key) -> Data? {
        store.data(forKey: storageKey(key))
    }

    func set(_ value: Any?, for key: Key) {
        store.set(value, forKey: storageKey(key))
    }

    func remove(_ key: Key) {
        store.removeObject(forKey: storageKey(key))
    }
}
