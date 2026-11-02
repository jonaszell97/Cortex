import Foundation

/// Snippet preferences, stored in UserDefaults.
@MainActor
@Observable
final class SnippetsSettings {
    private enum Key {
        static let keywordExpansion = "snippetKeywordExpansion"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Off by default: while it is off, no event tap exists and Cortex
    /// never sees what is typed.
    var keywordExpansion: Bool { didSet { defaults.set(keywordExpansion, forKey: Key.keywordExpansion) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.keywordExpansion: false])
        keywordExpansion = defaults.bool(forKey: Key.keywordExpansion)
    }
}
