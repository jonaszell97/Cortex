import Foundation
import CortexCore

/// The App Group container that the app and its extensions share
/// (plans/IOS.md, §2): the data directory with the knowledge folder, the
/// reading list's outbox and the widgets' snapshot, and the defaults.
/// Compiled into the app, the share extension and the widgets.
enum SharedContainer {
    /// `CortexAppGroup` in each target's Info.plist.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "CortexAppGroup") as? String
    }

    /// The data directory in the App Group container.
    static func dataDirectory() throws -> URL {
        try AppPaths.dataDirectory(appGroup: appGroup ?? "")
    }

    static var defaults: UserDefaults {
        appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static func knowledgeFolder(in dataDirectory: URL) -> KnowledgeFolder {
        KnowledgeFolder(root: dataDirectory.appending(path: "knowledge", directoryHint: .isDirectory))
    }

    static func readingListOutbox(in dataDirectory: URL) -> ReadingListOutbox {
        ReadingListOutbox(dataDirectory: dataDirectory)
    }

    static func widgetSnapshotURL(in dataDirectory: URL) -> URL {
        WidgetSnapshot.url(inDataDirectory: dataDirectory)
    }

    /// The widget kinds, for reloading their timelines.
    enum WidgetKind {
        static let todos = "todos"
        static let readingList = "reading-list"
        static let newNote = "new-note"
        static let newNoteControl = "new-note-control"
    }
}
