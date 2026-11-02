import Foundation
import CortexCore

/// How often each SF Symbol was used, by name, counted apart from emoji.
/// Stored in UserDefaults on this Mac, not synced.
@MainActor
@Observable
final class SymbolsSettings {
    private static let usageKey = "symbolUsage"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var usage: UsageRanking {
        didSet { usage.save(to: defaults, key: Self.usageKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        usage = UsageRanking.load(from: defaults, key: Self.usageKey)
    }

    func recordUse(of name: String) {
        usage.recordUse(of: name)
    }
}
