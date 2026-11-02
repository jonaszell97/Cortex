import Foundation

/// Reading list preferences, stored as "reading-list.<name>".
@MainActor
@Observable
final class ReadingListSettings {
    @ObservationIgnored private let defaults: ModuleDefaults

    /// Read links stay in the list below the unread ones. Searching always
    /// finds them.
    var listRead: Bool { didSet { defaults.set(listRead, for: "listRead") } }
    /// Read links are deleted this many days after they were read; 0 keeps
    /// them.
    var deleteReadAfterDays: Int { didSet { defaults.set(deleteReadAfterDays, for: "deleteReadAfterDays") } }

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        listRead = defaults.bool("listRead") ?? true
        deleteReadAfterDays = defaults.integer("deleteReadAfterDays") ?? 0
    }
}
