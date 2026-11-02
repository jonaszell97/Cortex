import AppIntents
import Foundation
import CortexCore

// Siri, Shortcuts, Spotlight and the Action button (plans/IOS.md, M5). The
// ones that add something write the file or the reading list's outbox
// straight away, without the app's database or index, so they work while
// the app is not running; the app indexes and syncs it then
// (`IntentBridge.wrote`). The ones that open the app go through
// `AppNavigator` (`IntentBridge.open`).

/// A note into the inbox; without a title, its first line is the title.
/// Run from the Action button, it asks for the text: a capture field.
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note"
    static let description = IntentDescription("Adds a note to the inbox of your knowledge base.")

    @Parameter(
        title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
        requestValueDialog: "What do you want to note?")
    var text: String

    @Parameter(title: "Title", description: "The first line of the text, if empty.")
    var noteTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to the inbox") { \.$noteTitle }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let folder = SharedContainer.knowledgeFolder(in: try SharedContainer.dataDirectory())
        let path = try KnowledgeCapture.createNote(in: folder, title: noteTitle ?? "", text: text)
        await IntentBridge.wrote()
        let title = (try? folder.item(at: path))?.title ?? "the note"
        return .result(dialog: "Added “\(title)” to the inbox.")
    }
}

/// A to-do into the inbox, with a due day if given.
struct AddTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add To-Do"
    static let description = IntentDescription("Adds a to-do to the inbox of your knowledge base.")

    @Parameter(title: "To-Do", requestValueDialog: "What is there to do?")
    var todoTitle: String

    @Parameter(title: "Due", kind: .date)
    var due: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$todoTitle) to the inbox") { \.$due }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let folder = SharedContainer.knowledgeFolder(in: try SharedContainer.dataDirectory())
        try folder.createTodo(title: todoTitle, due: due.map { FrontMatter.formatDay($0) })
        await IntentBridge.wrote()
        return .result(dialog: "Added “\(todoTitle)” to your to-dos.")
    }
}

/// A link into the reading list.
struct AddToReadingListIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Reading List"
    static let description = IntentDescription("Saves a link to read later in Cortex.")

    @Parameter(title: "Link", requestValueDialog: "Which link?")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$url) to the reading list")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outbox = SharedContainer.readingListOutbox(in: try SharedContainer.dataDirectory())
        try outbox.add(url: url.absoluteString, sourceAppName: "Shortcuts")
        await IntentBridge.wrote()
        return .result(dialog: "Added to your reading list.")
    }
}

/// Opens the knowledge base's search with the text, `@project` and `#tag`
/// as in the Mac's `?`.
struct SearchKnowledgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Knowledge"
    static let description = IntentDescription("Opens Cortex and searches your notes, skills and to-dos.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search knowledge for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.open(.search(query))
        return .result()
    }
}

struct OpenTodosIntent: AppIntent {
    static let title: LocalizedStringResource = "Open To-Dos"
    static let description = IntentDescription("Opens Cortex on the open to-dos.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.open(.todos)
        return .result()
    }
}

/// The intents with phrases, so they are in Spotlight, Siri and Shortcuts
/// without setting anything up.
struct CortexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: ["Add a note to \(.applicationName)", "Note in \(.applicationName)"],
            shortTitle: "Add Note", systemImageName: "square.and.pencil")
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: ["Add a to-do to \(.applicationName)", "New \(.applicationName) to-do"],
            shortTitle: "Add To-Do", systemImageName: "checklist")
        AppShortcut(
            intent: AddToReadingListIntent(),
            phrases: ["Add to \(.applicationName) reading list", "Save a link to \(.applicationName)"],
            shortTitle: "Add to Reading List", systemImageName: "eyeglasses")
        AppShortcut(
            intent: SearchKnowledgeIntent(),
            phrases: ["Search \(.applicationName)", "Search knowledge in \(.applicationName)"],
            shortTitle: "Search Knowledge", systemImageName: "magnifyingglass")
        AppShortcut(
            intent: OpenTodosIntent(),
            phrases: ["Open \(.applicationName) to-dos", "Show my to-dos in \(.applicationName)"],
            shortTitle: "Open To-Dos", systemImageName: "checklist.checked")
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)", "Write a \(.applicationName) note"],
            shortTitle: "New Note", systemImageName: "note.text.badge.plus")
    }
}
