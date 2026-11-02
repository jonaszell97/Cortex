import Foundation
import CortexCore

/// Text Recognition preferences, stored as "text-recognition.<name>".
@MainActor
@Observable
final class TextRecognitionSettings {
    @ObservationIgnored private let defaults: ModuleDefaults

    /// The lines of a paragraph become one; off keeps the line breaks as on
    /// screen.
    var joinLines: Bool { didSet { defaults.set(joinLines, for: "joinLines") } }
    /// A notification says what was copied.
    var notify: Bool { didSet { defaults.set(notify, for: "notify") } }
    /// A language identifier ("de-DE"); "" detects the language.
    var language: String { didSet { defaults.set(language, for: "language") } }

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        joinLines = defaults.bool("joinLines") ?? false
        notify = defaults.bool("notify") ?? true
        language = defaults.string("language") ?? ""
    }

    /// What the recognizer is told to read; empty detects. Vision's own
    /// value where it lists the language: one built from the identifier
    /// works but does not compare equal to it.
    var languages: [Locale.Language] {
        guard !language.isEmpty else { return [] }
        let listed = TextRecognizer.supportedLanguages.first { $0.maximalIdentifier == language }
        return [listed ?? Locale.Language(identifier: language)]
    }
}
