import AppKit
import Carbon.HIToolbox

/// What a key press in the palette means, before any scope looks at it. Esc
/// is handled by the panel itself.
enum PaletteKeyEvent: Equatable {
    case move(PaletteStep)
    case activate(PaletteActivation, PaletteTarget)
    /// For the active scope's (or overlay's) `keys`.
    case combo(KeyCombo)
}

/// The palette's key code work, kept free of UI state so it can be tested.
enum PaletteKeyMap {
    static func event(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> PaletteKeyEvent? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        // Arrow keys carry .function and .numericPad; only the real modifiers count.
        let isPlain = flags.intersection([.shift, .control, .option, .command]).isEmpty

        switch keyCode {
        case kVK_UpArrow:
            return .move(.vertical(-1))
        case kVK_DownArrow:
            return .move(.vertical(1))
        case kVK_LeftArrow where isPlain:
            return .move(.sideways(-1))
        case kVK_RightArrow where isPlain:
            return .move(.sideways(1))
        case kVK_Tab where isPlain:
            return .combo(.tab)
        case kVK_Tab where flags.intersection([.shift, .control, .option, .command]) == .shift:
            return .combo(.shiftTab)
        case kVK_Return where flags.contains(.command), kVK_ANSI_KeypadEnter where flags.contains(.command):
            // ⌘⏎ is a key a scope may take (open in VS Code); without one it
            // activates like ⏎ (`PaletteModel`).
            return .combo(KeyCombo(.return, modifiers: KeyCombo.Modifiers(flags)))
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .activate(PaletteActivation(flags), .selected)
        case kVK_Delete where flags.contains(.command):
            return .combo(KeyCombo(.delete, modifiers: KeyCombo.Modifiers(flags)))
        default:
            break
        }

        guard flags.contains(.command) else { return nil }
        if let position = digitKeyCodes.firstIndex(of: keyCode) {
            return .activate(flags.contains(.shift) ? .shift : .primary, .position(position))
        }
        guard let character = characters?.lowercased().first, character.isLetter else { return nil }
        return .combo(KeyCombo(.character(character), modifiers: KeyCombo.Modifiers(flags)))
    }

    /// The digit row by key code, not by character: with ⇧ held the character
    /// for "2" is "@" (US) or "\"" (German), so ⌘⇧2 would not match otherwise.
    private static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
}
