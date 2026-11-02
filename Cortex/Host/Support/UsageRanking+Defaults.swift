import Foundation
import CortexCore

extension UsageRanking {
    /// Usage counts kept as JSON under `key`; empty if there are none yet.
    static func load(from defaults: UserDefaults, key: String) -> UsageRanking {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageRanking.self, from: $0) } ?? UsageRanking()
    }

    func save(to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}
