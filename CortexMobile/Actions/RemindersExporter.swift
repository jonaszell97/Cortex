import EventKit
import CortexCore

/// Add to Reminders (plans/IOS.md, M4): an item becomes a reminder, or a
/// to-do one per checklist item, in the list chosen once. Which reminders
/// came from which item is kept by path, so adding again updates them
/// instead of adding them twice. One-way: ticking a reminder off leaves
/// the to-do as it is.
@MainActor
final class RemindersExporter {
    struct Result {
        var added = 0
        var updated = 0
    }

    let store = EKEventStore()
    private let defaults: UserDefaults

    /// `[path: [reminder key: calendarItemIdentifier]]`.
    private static let identifiersKey = "actions.reminders"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Asks the first time; false when access was refused.
    func requestAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: true
        case .notDetermined: try await store.requestFullAccessToReminders()
        default: false
        }
    }

    /// The lists a reminder can be added to.
    var lists: [EKCalendar] {
        store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var defaultList: EKCalendar? { store.defaultCalendarForNewReminders() }

    func list(withID id: String?) -> EKCalendar? {
        guard let id, let list = store.calendar(withIdentifier: id), list.allowsContentModifications else { return nil }
        return list
    }

    /// Adds the item's reminders to `list`, or updates the ones added
    /// before (wherever they are now). Reminders of the item that it no
    /// longer has (a checklist item removed, or one reminder instead of
    /// one per item) are completed. Completed ones are not added.
    func export(_ item: KnowledgeItem, perItem: Bool, to list: EKCalendar) throws -> Result {
        let specs = KnowledgeReminder.reminders(for: item, perItem: perItem)
        var known = identifiers[item.path] ?? [:]
        var result = Result()
        var kept: [String: String] = [:]

        for spec in specs {
            let existing = known[spec.key].flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
            if existing == nil, spec.isCompleted { continue }
            let reminder = existing ?? EKReminder(eventStore: store)
            if existing == nil { reminder.calendar = list }
            reminder.title = spec.title
            reminder.notes = spec.notes
            reminder.dueDateComponents = spec.due
            // Reminders doesn't show it (the link at the end of the notes
            // is what opens Cortex), but other clients may.
            reminder.url = item.link
            reminder.isCompleted = spec.isCompleted
            try store.save(reminder, commit: false)
            kept[spec.key] = reminder.calendarItemIdentifier
            if existing == nil { result.added += 1 } else { result.updated += 1 }
        }
        for key in specs.map(\.key) { known.removeValue(forKey: key) }
        for identifier in known.values {
            guard let gone = store.calendarItem(withIdentifier: identifier) as? EKReminder, !gone.isCompleted else { continue }
            gone.isCompleted = true
            try store.save(gone, commit: false)
        }
        try store.commit()
        identifiers[item.path] = kept.isEmpty ? nil : kept
        return result
    }

    private var identifiers: [String: [String: String]] {
        get { defaults.dictionary(forKey: Self.identifiersKey) as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.identifiersKey) }
    }
}
