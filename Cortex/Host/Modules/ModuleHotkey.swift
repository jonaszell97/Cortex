import KeyboardShortcuts

/// A global shortcut a module offers. The host registers it while the module
/// is active; the user records the keys in Settings.
struct ModuleHotkey {
    /// Declared in the module's Module.swift file. Recorded keys are stored
    /// under its name, so it never changes.
    let name: KeyboardShortcuts.Name
    /// "Open quick actions:"
    let title: String
    let help: String?
    let action: @MainActor () -> Void

    init(_ name: KeyboardShortcuts.Name, title: String, help: String? = nil, action: @escaping @MainActor () -> Void) {
        self.name = name
        self.title = title
        self.help = help
        self.action = action
    }
}
