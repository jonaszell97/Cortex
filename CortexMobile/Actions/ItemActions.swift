import EventKit
import SwiftUI
import UniformTypeIdentifiers
import CortexCore

/// The actions' preferences, in the App Group defaults as
/// "actions.<name>".
@MainActor
@Observable
final class ActionsSettings {
    @ObservationIgnored let defaults: UserDefaults

    /// The Reminders list new reminders go to; nil until chosen.
    var remindersList: String? { didSet { defaults.set(remindersList, forKey: Key.remindersList) } }
    /// A Shortcut that makes a note from its text input; empty uses the
    /// share sheet.
    var notesShortcut: String { didSet { defaults.set(notesShortcut, forKey: Key.notesShortcut) } }

    private enum Key {
        static let remindersList = "actions.remindersList"
        static let notesShortcut = "actions.notesShortcut"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        remindersList = defaults.string(forKey: Key.remindersList)
        notesShortcut = defaults.string(forKey: Key.notesShortcut) ?? ""
    }
}

/// What can be done with an item outside Cortex (plans/IOS.md, M4): copy
/// it, share it, add it to Reminders, Calendar or Notes. One for the app,
/// presented from `RootView` (`itemActionsPresentation()`), so the item
/// view and every list's context menu share its sheets and questions.
@MainActor
@Observable
final class ItemActions {
    /// Waiting for the user before adding to Reminders.
    struct PendingReminder: Identifiable {
        var item: KnowledgeItem
        var perItem: Bool
        var id: String { item.path }
    }

    struct Problem: Equatable {
        var title: String
        var message: String
        /// Offer the app's page in the Settings app.
        var opensSettings = false
    }

    let settings: ActionsSettings
    /// "One Reminder" or "One per Item"?
    var askingPerItem: KnowledgeItem?
    /// The list isn't chosen yet (or is gone).
    var choosingList: PendingReminder?
    /// The calendar's editor, pre-filled.
    var event: EKEvent?
    var problem: Problem?
    /// A short confirmation at the bottom of the screen.
    private(set) var toast: String?

    @ObservationIgnored let reminders: RemindersExporter
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let log = Log.logger("actions")

    init(settings: ActionsSettings) {
        self.settings = settings
        reminders = RemindersExporter(defaults: settings.defaults)
    }

    // MARK: - Copy

    enum CopyFormat {
        case markdown, text, link
    }

    func copy(_ item: KnowledgeItem, as format: CopyFormat) {
        switch format {
        case .markdown:
            UIPasteboard.general.string = item.markdown
            show("Copied as Markdown")
        case .text:
            UIPasteboard.general.string = item.pasteText
            show("Copied the text")
        case .link:
            UIPasteboard.general.setItems([[
                UTType.url.identifier: item.link, UTType.utf8PlainText.identifier: item.link.absoluteString,
            ]])
            show("Copied the link")
        }
    }

    // MARK: - Notes

    /// The URL that runs the Notes Shortcut with the item's text, or nil
    /// when none is set (then the share sheet goes to Notes). The callback
    /// brings Cortex back.
    func notesShortcutURL(for item: KnowledgeItem) -> URL? {
        let name = settings.notesShortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: item.notesText), URLQueryItem(name: "x-success", value: "cortex://"),
        ]
        return components.url
    }

    // MARK: - Calendar

    /// Opens the calendar's own editor with an all-day event on the due
    /// day. It runs outside the app, so Cortex needs no calendar access.
    func addToCalendar(_ item: KnowledgeItem) {
        guard let due = item.due.flatMap(KnowledgeReminder.dueComponents),
              let day = Calendar.current.date(from: due)
        else { return }
        let event = EKEvent(eventStore: reminders.store)
        event.title = item.title
        event.isAllDay = true
        event.startDate = day
        event.endDate = day
        event.url = item.link
        let notes = MarkdownBlock.plainText(MarkdownBlock.parse(item.pasteText))
        event.notes = notes.isEmpty ? nil : notes
        self.event = event
    }

    // MARK: - Reminders

    /// A to-do with open checklist items asks whether each becomes a
    /// reminder of its own.
    func addToReminders(_ item: KnowledgeItem) {
        let checklist = TodoChecklist(body: item.body)
        if item.kind == .todo, checklist.items.contains(where: { !$0.isDone }) {
            askingPerItem = item
        } else {
            Task { await addToReminders(item, perItem: false) }
        }
    }

    func addToReminders(_ item: KnowledgeItem, perItem: Bool) async {
        do {
            guard try await reminders.requestAccess() else {
                problem = Problem(
                    title: "No access to Reminders",
                    message: "Allow Cortex to use Reminders in the Settings app, then try again.", opensSettings: true)
                return
            }
            guard let list = reminders.list(withID: settings.remindersList) else {
                choosingList = PendingReminder(item: item, perItem: perItem)
                return
            }
            let result = try reminders.export(item, perItem: perItem, to: list)
            switch (result.added, result.updated) {
            case (0, 0): show("Nothing open to add")
            case (let added, 0): show(added == 1 ? "Added to \(list.title)" : "\(added) reminders added to \(list.title)")
            case (0, let updated): show(updated == 1 ? "Reminder updated" : "\(updated) reminders updated")
            case (let added, let updated): show("\(added) added, \(updated) updated")
            }
        } catch {
            log.error("Adding to Reminders failed: \(error, privacy: .public)")
            problem = Problem(title: "Couldn't add it to Reminders", message: error.localizedDescription)
        }
    }

    /// The list was chosen: remembered, then the waiting item is added.
    func chooseList(_ id: String) {
        settings.remindersList = id
        guard let pending = choosingList else { return }
        choosingList = nil
        Task { await addToReminders(pending.item, perItem: pending.perItem) }
    }

    // MARK: - Feedback

    func show(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }
}
