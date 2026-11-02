import AppIntents
import Foundation
import CortexCore

/// Opens the editor for a new note in the inbox. In the app and the widget
/// extension, so the Control Center control (and the Action button) can
/// run it; it opens the app, which performs it.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens Cortex with a new note in the inbox.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.open(.new(.note, project: nil))
        return .result()
    }
}

/// Ticks off a to-do from the To-Dos widget: writes its file and takes it
/// out of the widgets' snapshot, so the widget shows the change before the
/// app has seen it. The app indexes and syncs the file when it runs next.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete To-Do"
    static let isDiscoverable = false

    @Parameter(title: "To-Do") var path: String

    init() {}

    init(path: String) {
        self.path = path
    }

    func perform() async throws -> some IntentResult {
        let directory = try SharedContainer.dataDirectory()
        let folder = SharedContainer.knowledgeFolder(in: directory)
        // Gone already (deleted on a Mac): it only leaves the widget.
        if folder.exists(path) { try folder.setStatus(.done, of: path) }
        let snapshotURL = SharedContainer.widgetSnapshotURL(in: directory)
        try WidgetSnapshot.read(from: snapshotURL).completing(path).write(to: snapshotURL)
        await IntentBridge.wrote()
        return .result()
    }
}
