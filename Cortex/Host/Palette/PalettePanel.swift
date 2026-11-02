import AppKit

/// A borderless, non-activating floating panel.
///
/// `.nonactivatingPanel` lets the panel become key (so it receives typing)
/// without activating Cortex, so the app the user was in stays the active
/// app and can be pasted into. The style mask must be set at init; changing it
/// later does not reliably take effect.
final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Sees key-down and modifier changes before the search field does.
    /// Returns true when it handled the event.
    var keyHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // NSPanel hides on deactivation by default; Cortex is never the active
        // app while the panel is up, so that would hide it at random.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc, list navigation and the paste keys are handled here, before the
    /// search field's field editor would swallow them. While an input method is
    /// composing text, keys go to the field editor (Esc cancels the composition).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            _ = keyHandler?(event)
        } else if event.type == .keyDown, !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            if keyHandler?(event) == true { return }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
