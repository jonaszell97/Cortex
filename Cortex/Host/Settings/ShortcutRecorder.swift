import AppKit
import Carbon.HIToolbox
@preconcurrency import KeyboardShortcuts
import SwiftUI

/// A row for recording a global shortcut: the field records on click, the
/// button next to it clears. Replaces `KeyboardShortcuts.Recorder`, whose
/// search-field clear button and pause flag (left set when focus is lost in
/// some ways, which silences every hotkey) were unreliable here.
struct ShortcutRecorder: View {
    let title: String
    let name: KeyboardShortcuts.Name
    @State private var shortcut: KeyboardShortcuts.Shortcut?

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
        _shortcut = State(initialValue: KeyboardShortcuts.getShortcut(for: name))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                RecorderField(shortcut: shortcut, label: title) { recorded in
                    KeyboardShortcuts.setShortcut(recorded, for: name)
                    shortcut = recorded
                }
                .frame(width: 140, height: 22)
                Button {
                    KeyboardShortcuts.setShortcut(nil, for: name)
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(shortcut == nil)
                .help("Clear the shortcut")
            }
        }
    }
}

private struct RecorderField: NSViewRepresentable {
    let shortcut: KeyboardShortcuts.Shortcut?
    let label: String
    let onRecord: (KeyboardShortcuts.Shortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onRecord = onRecord
    }
}

/// Records while it is the first responder: a click focuses it (also the
/// click that brings the window forward), and recording ends on a shortcut,
/// Esc, ⌫ (clears), ⇥, a click elsewhere or when the window stops being key.
/// Global shortcuts are switched off meanwhile, so one that is already set
/// can be recorded again.
@MainActor
final class ShortcutRecorderView: NSView {
    var shortcut: KeyboardShortcuts.Shortcut? {
        didSet { needsDisplay = true }
    }
    var onRecord: (KeyboardShortcuts.Shortcut?) -> Void = { _ in }
    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }
    /// Why the last key was refused, shown until recording ends.
    private var hint: String?
    private var keyMonitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    override var acceptsFirstResponder: Bool { true }
    /// Out of the key view loop, so the window never picks it as its initial
    /// first responder (which would start recording as the window opens).
    override var canBecomeKeyView: Bool { false }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        startRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopRecording()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let newWindow else { return }
        // The window loses key status when it closes or another app comes
        // forward: never stay armed with the global shortcuts off.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        hint = nil
        KeyboardShortcuts.isEnabled = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let unsafeEvent = event
            let consumed = MainActor.assumeIsolated { self?.handle(unsafeEvent) ?? false }
            return consumed ? nil : event
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard isRecording else { return }
        isRecording = false
        hint = nil
        KeyboardShortcuts.isEnabled = true
    }

    private func cancelRecording() {
        guard isRecording else { return }
        window?.makeFirstResponder(nil)
        stopRecording()
    }

    /// True when the key was used up; false lets the event through.
    func handle(_ event: NSEvent) -> Bool {
        guard isRecording, event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let keyCode = Int(event.keyCode)

        if modifiers.isEmpty {
            switch keyCode {
            case kVK_Escape:
                cancelRecording()
            case kVK_Delete, kVK_ForwardDelete:
                onRecord(nil)
                cancelRecording()
            case kVK_Tab:
                cancelRecording()
                return false
            default:
                refuse("Use ⌘, ⌃ or ⌥")
            }
            return true
        }
        guard !modifiers.isSubset(of: [.shift]) || Self.functionKeys.contains(keyCode) else {
            refuse("Use ⌘, ⌃ or ⌥")
            return true
        }
        guard let recorded = KeyboardShortcuts.Shortcut(event: event) else {
            refuse("Not a shortcut")
            return true
        }
        if let item = Self.menuItem(matching: event, modifiers: modifiers, in: NSApp.mainMenu) {
            refuse("Used by \(item.title)")
            return true
        }
        onRecord(recorded)
        cancelRecording()
        return true
    }

    private func refuse(_ message: String) {
        Beep.play()
        hint = message
        needsDisplay = true
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static func menuItem(matching event: NSEvent, modifiers: NSEvent.ModifierFlags, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu, let characters = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        for item in menu.items {
            if !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == characters {
                var mask = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
                if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
                if mask == modifiers { return item }
            }
            if let match = menuItem(matching: event, modifiers: modifiers, in: item.submenu) { return match }
        }
        return nil
    }

    // MARK: - Drawing

    private var text: (String, NSColor) {
        if isRecording {
            if let hint { return (hint, .systemOrange) }
            return ("Press shortcut", .secondaryLabelColor)
        }
        if let shortcut { return ("\(shortcut)", .labelColor) }
        return ("Click to record", .secondaryLabelColor)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = isRecording ? 2 : 1
        outline.stroke()

        let (string, color) = text
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    override func accessibilityValue() -> Any? {
        isRecording ? "Recording" : (shortcut.map { "\($0)" } ?? "None")
    }
}
