import SwiftUI

/// A simple setting a module declares, drawn on its page in Settings below
/// its hotkeys and above its `settingsView`. Options bind to the module's own
/// `@Observable` settings class, so storing them stays there.
struct ModuleOption: Identifiable {
    enum Kind {
        case toggle(Binding<Bool>)
        case integer(Binding<Int>, range: ClosedRange<Int>, unit: String?)
        case choice(Binding<String>, [(value: String, title: String)])
        case text(Binding<String>, prompt: String?)
        /// Stored in the Keychain through the module's `ModuleSecrets`; the
        /// value is never shown back, only whether it is saved.
        case secret(ModuleSecretKey)
        /// The path, and a button that opens the folder.
        case folder(URL)
        case button(String, role: ButtonRole?, action: () -> Void)
    }

    /// Unique within the module.
    let id: String
    let title: String
    /// A caption below the option.
    let help: String?
    let kind: Kind
    /// false greys the option out ("Directions" only while reversal is on).
    var isEnabled: () -> Bool

    init(id: String, title: String, help: String? = nil, kind: Kind, isEnabled: @escaping () -> Bool = { true }) {
        self.id = id
        self.title = title
        self.help = help
        self.kind = kind
        self.isEnabled = isEnabled
    }
}
