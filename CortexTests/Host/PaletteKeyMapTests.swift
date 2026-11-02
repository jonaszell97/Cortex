import AppKit
import Carbon.HIToolbox
import Testing
@testable import Cortex

@MainActor
@Suite struct PaletteKeyMapTests {
    func event(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil) -> PaletteKeyEvent? {
        PaletteKeyMap.event(keyCode: keyCode, modifiers: modifiers, characters: characters)
    }

    @Test func arrowsMove() {
        #expect(event(kVK_UpArrow) == .move(.vertical(-1)))
        #expect(event(kVK_DownArrow) == .move(.vertical(1)))
        // Arrow keys come with .function and .numericPad set.
        #expect(event(kVK_LeftArrow, [.function, .numericPad]) == .move(.sideways(-1)))
        #expect(event(kVK_RightArrow, [.function, .numericPad]) == .move(.sideways(1)))
        // With a modifier they edit the search text as usual (⇧← selects, ⌥← jumps a word).
        #expect(event(kVK_LeftArrow, [.shift, .function, .numericPad]) == nil)
        #expect(event(kVK_RightArrow, [.option, .function, .numericPad]) == nil)
    }

    @Test func tabIsAKeyForTheScope() {
        #expect(event(kVK_Tab) == .combo(.tab))
        #expect(event(kVK_Tab, .shift) == .combo(.shiftTab))
        #expect(event(kVK_Tab, .command) == nil)
    }

    @Test func returnActivatesWithItsModifiers() {
        #expect(event(kVK_Return) == .activate(.primary, .selected))
        #expect(event(kVK_ANSI_KeypadEnter) == .activate(.primary, .selected))
        #expect(event(kVK_Return, .shift) == .activate(.shift, .selected))
        #expect(event(kVK_Return, .option) == .activate(.option, .selected))
        #expect(event(kVK_Return, [.option, .shift]) == .activate(.optionShift, .selected))
    }

    @Test func commandReturnIsAKeyThatFallsBackToReturn() {
        #expect(event(kVK_Return, .command) == .combo(KeyCombo(.return, modifiers: .command)))
        #expect(event(kVK_ANSI_KeypadEnter, [.command, .option]) == .combo(KeyCombo(.return, modifiers: [.command, .option])))
        #expect(KeyCombo(.return, modifiers: .command).returnActivation == .primary)
        #expect(KeyCombo(.return, modifiers: [.command, .option]).returnActivation == .option)
        #expect(KeyCombo.command("e").returnActivation == nil)
        #expect(KeyCombo(.return, modifiers: .command).label == "⌘⏎")
    }

    @Test func commandDigitsActivateByPosition() {
        #expect(event(kVK_ANSI_1, .command, "1") == .activate(.primary, .position(0)))
        #expect(event(kVK_ANSI_9, .command, "9") == .activate(.primary, .position(8)))
        // ⇧ changes the character ("@" on US, "\"" on German layouts), not the key.
        #expect(event(kVK_ANSI_2, [.command, .shift], "\"") == .activate(.shift, .position(1)))
        #expect(event(kVK_ANSI_0, .command, "0") == nil)
        #expect(event(kVK_ANSI_1, [], "1") == nil, "a plain digit is typed into the search field")
    }

    @Test func commandLettersAndDeleteAreCombos() {
        #expect(event(kVK_ANSI_P, .command, "p") == .combo(.command("p")))
        #expect(event(kVK_ANSI_E, .command, "E") == .combo(.command("e")))
        #expect(event(kVK_ANSI_K, .command, "k") == .combo(.command("k")))
        #expect(event(kVK_ANSI_P, [], "p") == nil)
        #expect(event(kVK_Delete, .command) == .combo(.command(.delete)))
        #expect(event(kVK_Delete) == nil, "⌫ edits the search field")
    }

    @Test func otherKeysGoToTheSearchField() {
        #expect(event(kVK_ANSI_A, [], "a") == nil)
        #expect(event(kVK_ANSI_Comma, .command, ",") == nil)
    }

    @Test func activationFromModifiers() {
        #expect(PaletteActivation([]) == .primary)
        #expect(PaletteActivation([.shift, .function]) == .shift)
        #expect(PaletteActivation([.option, .shift]).isCopy)
        #expect(PaletteActivation([.option, .shift]).hasShift)
        #expect(!PaletteActivation([.shift]).isCopy)
    }

    @Test func comboLabels() {
        #expect(KeyCombo.command("p").label == "⌘P")
        #expect(KeyCombo.command(.delete).label == "⌘⌫")
        #expect(KeyCombo.tab.label == "⇥")
        #expect(KeyCombo.modifierOnly(.option).label == "⌥")
        #expect(KeyCombo.command("P") == .command("p"))
    }
}
