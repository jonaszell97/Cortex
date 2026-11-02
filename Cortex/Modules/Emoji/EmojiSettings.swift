import Foundation
import CortexCore

/// What the emoji picker remembers: the chosen skin tone and how often each
/// emoji was used. Stored in UserDefaults on this Mac, not synced.
@MainActor
@Observable
final class EmojiSettings {
    private enum Key {
        static let skinTone = "emojiSkinTone"
        static let usage = "emojiUsage"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// nil for the default (yellow) tone.
    var skinTone: EmojiSkinTone? {
        didSet { defaults.set(skinTone?.rawValue ?? 0, forKey: Key.skinTone) }
    }

    private(set) var usage: UsageRanking {
        didSet { usage.save(to: defaults, key: Key.usage) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skinTone = EmojiSkinTone(rawValue: defaults.integer(forKey: Key.skinTone))
        usage = UsageRanking.load(from: defaults, key: Key.usage)
    }

    func cycleSkinTone() {
        skinTone = EmojiSkinTone.next(after: skinTone)
    }

    func recordUse(of emoji: Emoji) {
        usage.recordUse(of: emoji.character)
    }
}
