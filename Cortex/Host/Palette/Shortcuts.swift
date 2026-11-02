import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens and closes the palette. Registered through Carbon's
    /// `RegisterEventHotKey`, so it needs no Accessibility permission and the
    /// key press never reaches the frontmost app.
    @MainActor static let togglePalette = Self("togglePalette", default: .init(.v, modifiers: [.command, .shift]))
}
