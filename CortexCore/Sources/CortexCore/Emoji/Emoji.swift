import Foundation

/// The emoji picker's categories, in display order.
public enum EmojiGroup: Int, CaseIterable, Sendable {
    case smileys, people, animals, food, travel, activities, objects, symbols, flags

    public var title: String {
        switch self {
        case .smileys: "Smileys & Emotion"
        case .people: "People & Body"
        case .animals: "Animals & Nature"
        case .food: "Food & Drink"
        case .travel: "Travel & Places"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }
}

/// The Fitzpatrick skin tone modifiers, light to dark.
public enum EmojiSkinTone: Int, CaseIterable, Sendable {
    case light = 1, mediumLight, medium, mediumDark, dark

    /// The next tone when cycling: none, then each tone, then none again.
    public static func next(after tone: EmojiSkinTone?) -> EmojiSkinTone? {
        guard let tone else { return .light }
        return EmojiSkinTone(rawValue: tone.rawValue + 1)
    }

    /// A raised hand in this tone, to show which one is chosen.
    public var swatch: String {
        "\u{270B}" + String(UnicodeScalar(0x1F3FB + UInt32(rawValue - 1))!)
    }

    public static let noneSwatch = "\u{270B}"
}

public struct Emoji: Sendable, Equatable, Identifiable {
    /// The emoji itself, in its default tone.
    public let character: String
    public let group: EmojiGroup
    /// Position in the Unicode emoji ordering.
    public let order: Int
    /// Unicode emoji version it was added in (1.0, 13.1, …).
    public let version: Double
    /// Shortcodes without colons (`thumbs_up`, `thumbsup`).
    public let shortcodes: [String]
    /// The five tones, light to dark, or empty if the emoji has none.
    public let skinTones: [String]
    /// Name and search keywords by language code (`en`, `de`).
    public let names: [String: String]
    public let keywords: [String: [String]]

    public var id: String { character }

    public var hasSkinTones: Bool { !skinTones.isEmpty }

    /// The emoji to paste: the variant in `tone` if it has one.
    public func character(tone: EmojiSkinTone?) -> String {
        guard let tone, skinTones.indices.contains(tone.rawValue - 1) else { return character }
        return skinTones[tone.rawValue - 1]
    }

    /// The name in the first of `languages` that has one.
    public func name(in languages: [String]) -> String {
        for language in languages {
            if let name = names[language] { return name }
        }
        return names["en"] ?? names.values.first ?? ""
    }

    /// `U+1F44D` (`U+1F44D U+200D U+1F9B0` for a sequence); the variation
    /// selector is left out.
    public var codePoints: String {
        character.unicodeScalars
            .filter { $0.value != 0xFE0F }
            .map { "U+" + String($0.value, radix: 16, uppercase: true) }
            .joined(separator: " ")
    }
}
