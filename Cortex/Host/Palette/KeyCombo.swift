import AppKit

/// A key with its modifiers, as a scope's `PaletteKey` names it:
/// `.command("p")`, `.command(.delete)`, `.tab`, `.modifierOnly(.option)`.
struct KeyCombo: Hashable, Sendable {
    enum Key: Hashable, Sendable {
        /// Lowercased.
        case character(Character)
        case delete
        case tab
        /// Only with ⌘ (⌘⏎); plain ⏎ and ⌥⏎ are activations.
        case `return`
        /// No key, only the modifiers held (a hint like "⌥ Reveal").
        case none
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(_ flags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            self = modifiers
        }
    }

    let key: Key
    let modifiers: Modifiers

    init(_ key: Key, modifiers: Modifiers = []) {
        if case .character(let character) = key {
            self.key = .character(Character(character.lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    static func command(_ character: Character) -> KeyCombo {
        KeyCombo(.character(character), modifiers: .command)
    }

    static func command(_ key: Key) -> KeyCombo {
        KeyCombo(key, modifiers: .command)
    }

    static let tab = KeyCombo(.tab)
    static let shiftTab = KeyCombo(.tab, modifiers: .shift)

    static func modifierOnly(_ modifiers: Modifiers) -> KeyCombo {
        KeyCombo(.none, modifiers: modifiers)
    }

    /// For the hints bar: "⌘P", "⌘⌫", "⇥", "⌥".
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += character.uppercased()
        case .delete: text += "⌫"
        case .tab: text += "⇥"
        case .return: text += "⏎"
        case .none: break
        }
        return text
    }
}

extension KeyCombo {
    /// ⌘⏎ (with ⇧ or ⌥) that no key took: the activation it is without ⌘.
    var returnActivation: PaletteActivation? {
        guard key == .return else { return nil }
        switch (modifiers.contains(.option), modifiers.contains(.shift)) {
        case (true, true): return .optionShift
        case (true, false): return .option
        case (false, true): return .shift
        case (false, false): return .primary
        }
    }
}
