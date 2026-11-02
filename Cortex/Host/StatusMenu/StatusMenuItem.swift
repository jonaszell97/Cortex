import AppKit
import KeyboardShortcuts

/// One line a module adds to the status menu. Asked for every time the menu
/// opens and again while it is open when something it read changes, so it
/// shows the current state (a checkmark, "Synced 3 min ago", a job's
/// progress).
struct StatusMenuItem {
    let title: String
    var state: NSControl.StateValue = .off
    var isEnabled = true
    /// An SF Symbol.
    var image: String?
    var shortcut: KeyboardShortcuts.Name?
    var toolTip: String?
    /// nil: a line to read ("Synced 3 min ago"), never enabled.
    let action: (@MainActor () -> Void)?

    init(
        _ title: String, state: NSControl.StateValue = .off, isEnabled: Bool = true, image: String? = nil,
        shortcut: KeyboardShortcuts.Name? = nil, toolTip: String? = nil, action: (@MainActor () -> Void)?
    ) {
        self.title = title
        self.state = state
        self.isEnabled = isEnabled
        self.image = image
        self.shortcut = shortcut
        self.toolTip = toolTip
        self.action = action
    }

    /// A line to read, not to choose.
    static func line(_ title: String) -> StatusMenuItem {
        StatusMenuItem(title, isEnabled: false, action: nil)
    }
}

/// The menu bar icon a module asks for while something is going on (a
/// progress ring, a pause symbol). The highest priority wins; without any,
/// the icon is Cortex's own.
struct StatusIcon {
    let image: NSImage
    let accessibilityLabel: String
    /// The progress ring (Quick Actions) beats the pause icon (Clipboard).
    let priority: Int
}
