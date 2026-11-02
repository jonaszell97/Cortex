import AppKit
import Carbon.HIToolbox
@preconcurrency import KeyboardShortcuts
import Testing
@testable import Cortex

/// The settings shortcut field: what it records and that it never leaves the
/// global shortcuts switched off.
@MainActor
@Suite(.serialized) struct ShortcutRecorderTests {
    let window: NSWindow
    let field = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
    var recorded: [KeyboardShortcuts.Shortcut?] { log.values }
    final class Log { var values: [KeyboardShortcuts.Shortcut?] = [] }
    let log = Log()

    init() {
        NSApp.mainMenu = MainMenu.make()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        let log = log
        field.onRecord = { log.values.append($0) }
        KeyboardShortcuts.isEnabled = true
    }

    func press(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code))!
        return field.handle(event)
    }

    @Test func recordsOptionCommandS() {
        #expect(window.makeFirstResponder(field))
        #expect(field.isRecording)
        #expect(press(kVK_ANSI_S, "s", [.option, .command]))
        #expect(recorded == [KeyboardShortcuts.Shortcut(.s, modifiers: [.option, .command])])
        #expect(!field.isRecording)
    }

    @Test func recordsWithControlToo() {
        _ = window.makeFirstResponder(field)
        _ = press(kVK_ANSI_S, "s", [.control, .option, .command])
        #expect(recorded == [KeyboardShortcuts.Shortcut(.s, modifiers: [.control, .option, .command])])
    }

    @Test func globalShortcutsAreOffOnlyWhileRecording() {
        _ = window.makeFirstResponder(field)
        #expect(!KeyboardShortcuts.isEnabled)
        _ = window.makeFirstResponder(nil)
        #expect(KeyboardShortcuts.isEnabled)
    }

    @Test func losingKeyStatusEndsRecording() async {
        window.orderFront(nil)
        _ = window.makeFirstResponder(field)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!field.isRecording)
        #expect(KeyboardShortcuts.isEnabled)
    }

    @Test func removingTheFieldEndsRecording() {
        _ = window.makeFirstResponder(field)
        field.removeFromSuperview()
        #expect(!field.isRecording)
        #expect(KeyboardShortcuts.isEnabled)
    }

    @Test func escapeCancelsAndDeleteClears() {
        _ = window.makeFirstResponder(field)
        #expect(press(kVK_Escape, "\u{1b}"))
        #expect(!field.isRecording && recorded.isEmpty)

        _ = window.makeFirstResponder(field)
        #expect(press(kVK_Delete, "\u{7f}"))
        #expect(recorded.count == 1 && recorded[0] == nil)
        #expect(!field.isRecording)
    }

    @Test func tabLeavesTheField() {
        _ = window.makeFirstResponder(field)
        #expect(!press(kVK_Tab, "\t"), "the event goes on to move the focus")
        #expect(!field.isRecording)
    }

    @Test func refusesKeysThatCannotBeGlobalShortcuts() {
        _ = window.makeFirstResponder(field)
        _ = press(kVK_ANSI_S, "s")
        _ = press(kVK_ANSI_S, "S", [.shift])
        #expect(recorded.isEmpty)
        #expect(field.isRecording, "still waiting for a usable shortcut")
    }

    @Test func refusesShortcutsOfTheMenu() {
        _ = window.makeFirstResponder(field)
        _ = press(kVK_ANSI_C, "c", [.command])
        #expect(recorded.isEmpty)
        #expect(field.isRecording)
    }

    @Test func ignoresKeysWhenNotRecording() {
        #expect(!press(kVK_ANSI_S, "s", [.option, .command]))
        #expect(recorded.isEmpty)
    }
}
